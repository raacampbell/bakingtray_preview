'use strict';
// Control-flow tests for autorefresh.js with a fake DOM, fetch, clock and reload.
const test = require('node:test');
const assert = require('node:assert/strict');
const A = require('../../brainsaw/js/autorefresh.js');

// --- clock skew ---
test('clockOffset: skewed client clock is corrected', () => {
  const clientNow = Date.parse('2026-01-01T12:00:00Z');
  const serverNowSec = Date.parse('2026-01-01T12:10:00Z') / 1000; // client is 10 min slow
  assert.equal(A.clockOffset(serverNowSec, clientNow), 600000);
  assert.equal(A.clockOffset(String(serverNowSec), clientNow), 600000);
});
test('clockOffset: missing or invalid server time gives 0', () => {
  assert.equal(A.clockOffset(null, 5), 0);
  assert.equal(A.clockOffset('', 5), 0);
  assert.equal(A.clockOffset('abc', 5), 0);
});

function fakeEl({ url, uploadedAt, staleAfter = '900' }) {
  const attrs = { 'data-meta-url': url, 'data-uploaded-at': uploadedAt };
  if (staleAfter !== null) attrs['data-stale-after'] = staleAfter;
  const classes = new Set();
  const ago = { textContent: 'orig' };
  return {
    classes, ago,
    getAttribute: (k) => (k in attrs ? attrs[k] : null),
    classList: { toggle: (c, on) => (on ? classes.add(c) : classes.delete(c)) },
    querySelector: (sel) => (sel === '[data-ago]' ? ago : null),
  };
}

// responses[url] is an uploaded_at string; a missing url behaves as a 404.
function makeEnv(els, responses) {
  const store = new Map();
  const warnings = [];
  const env = {
    doc: { querySelectorAll: () => els },
    fetchFn: async (url) => {
      const r = responses[url.split('?')[0]];
      return r === undefined ? { ok: false, status: 404 } : { ok: true, json: async () => ({ uploaded_at: r }) };
    },
    reloads: 0,
    // A real reload gives a fresh page, so the reloading flag is cleared here.
    reload() { env.reloads += 1; env.reloading = false; },
    now: () => Date.parse('2026-01-01T00:10:00Z'),
    storage: { available: true, get: (k) => (store.has(k) ? store.get(k) : null), set: (k, v) => store.set(k, v) },
    storageKey: 'k',
    warnings,
    warnOnce: A.makeWarnOnce((m) => warnings.push(m)),
    timeoutMs: 50,
  };
  return env;
}
const T0 = '2026-01-01T00:00:00+00:00';
const T1 = '2026-01-01T00:09:00+00:00';

test('poll: several cards, one changed -> exactly one reload', async () => {
  const els = [fakeEl({ url: 'a', uploadedAt: T0 }), fakeEl({ url: 'b', uploadedAt: T0 }), fakeEl({ url: 'c', uploadedAt: T0 })];
  const env = makeEnv(els, { a: T0, b: T1, c: T0 });
  await A.poll(env);
  assert.equal(env.reloads, 1);
});
test('poll: none changed (same value, 404) -> no reload', async () => {
  const els = [fakeEl({ url: 'a', uploadedAt: T0 }), fakeEl({ url: 'b', uploadedAt: '' })];
  const env = makeEnv(els, { a: T0 }); // b is a 404
  await A.poll(env);
  assert.equal(env.reloads, 0);
});
test('poll: loop guard prevents a second reload for the same value, warns once', async () => {
  const els = [fakeEl({ url: 'a', uploadedAt: T0 })];
  const env = makeEnv(els, { a: T1 });
  await A.poll(env);
  await A.poll(env); // page "reloaded" but is still rendered with T0
  await A.poll(env);
  assert.equal(env.reloads, 1);
  assert.equal(env.warnings.filter((w) => w.includes('not reloading again')).length, 1);
});
test('poll: a newer value after a guarded one reloads again', async () => {
  const els = [fakeEl({ url: 'a', uploadedAt: T0 })];
  const responses = { a: T1 };
  const env = makeEnv(els, responses);
  await A.poll(env);
  responses.a = '2026-01-01T00:09:30+00:00';
  await A.poll(env);
  assert.equal(env.reloads, 2);
});
test('poll: stalled fetch is aborted, counts as no change, warns once per URL', async () => {
  const els = [fakeEl({ url: 'a', uploadedAt: T0 })];
  const env = makeEnv(els, {});
  env.fetchFn = (url, opts) => new Promise((_, rej) => opts.signal.addEventListener('abort', () => rej(new Error('aborted'))));
  await A.poll(env);
  await A.poll(env);
  assert.equal(env.reloads, 0);
  assert.equal(env.warnings.filter((w) => w.includes('timed out')).length, 1);
});
test('refreshDisplay: updates ago and stale from the clock without any fetch', () => {
  const fresh = fakeEl({ url: 'a', uploadedAt: T1 }); // 60 s old at env.now
  const old = fakeEl({ url: 'b', uploadedAt: T0, staleAfter: '300' }); // 600 s old
  const never = fakeEl({ url: 'c', uploadedAt: '' });
  const env = makeEnv([fresh, old, never], {});
  A.refreshDisplay(env);
  assert.equal(fresh.ago.textContent, '1m ago');
  assert.equal(fresh.classes.has('stale'), false);
  assert.equal(old.ago.textContent, '10m ago');
  assert.equal(old.classes.has('stale'), true);
  assert.equal(never.ago.textContent, 'orig'); // never-uploaded text untouched
  assert.equal(never.classes.has('stale'), true);
});
test('refreshDisplay: missing/invalid data-stale-after falls back to 900, warns once', () => {
  const missing = fakeEl({ url: 'a', uploadedAt: T0, staleAfter: null }); // 600 s old
  const bad = fakeEl({ url: 'b', uploadedAt: T0, staleAfter: 'abc' });
  const env = makeEnv([missing, bad], {});
  A.refreshDisplay(env);
  A.refreshDisplay(env);
  assert.equal(missing.classes.has('stale'), false);
  assert.equal(bad.classes.has('stale'), false);
  assert.equal(env.warnings.length, 1);
});
test('fetchUploadedAt: failure kind reaches onFail', async () => {
  const reasons = [];
  await A.fetchUploadedAt('u', async () => ({ ok: false, status: 404 }), 1, { onFail: (u, kind) => reasons.push(kind) });
  assert.deepEqual(reasons, ['http-404']);
});
test('safeStorage: swallows a throwing storage', () => {
  const boom = { getItem() { throw new Error('x'); }, setItem() { throw new Error('x'); } };
  const s = A.safeStorage(() => boom);
  s.set('k', 'v');
  assert.equal(s.get('k'), null);
  assert.equal(s.available, true);
});
test('safeStorage: a throwing getter is survived and reported unavailable', () => {
  const s = A.safeStorage(() => { throw new Error('SecurityError'); });
  s.set('k', 'v');
  assert.equal(s.get('k'), null);
  assert.equal(s.available, false);
});

// --- per-URL loop guard ---
test('poll: guard is per URL; alternating fetch failures give at most one reload per value', async () => {
  const els = [fakeEl({ url: 'a', uploadedAt: T0 }), fakeEl({ url: 'b', uploadedAt: T0 })];
  const failing = new Set();
  const env = makeEnv(els, {});
  env.fetchFn = async (url) => {
    const base = url.split('?')[0];
    if (failing.has(base)) throw new Error('net');
    return { ok: true, json: async () => ({ uploaded_at: T1 }) };
  };
  await A.poll(env); // both changed -> reload
  failing.add('a');
  await A.poll(env); // only b visible, already reloaded for it
  failing.delete('a'); failing.add('b');
  await A.poll(env); // only a visible, already reloaded for it
  failing.delete('b');
  await A.poll(env);
  assert.equal(env.reloads, 1);
});
test('poll: a different card changing later still reloads', async () => {
  const els = [fakeEl({ url: 'a', uploadedAt: T0 }), fakeEl({ url: 'b', uploadedAt: T0 })];
  const responses = { a: T1 };
  const env = makeEnv(els, responses);
  await A.poll(env);
  responses.b = T1;
  await A.poll(env);
  assert.equal(env.reloads, 2);
});
test('poll: unavailable storage warns once that the guard is off', async () => {
  const els = [fakeEl({ url: 'a', uploadedAt: T0 })];
  const env = makeEnv(els, { a: T1 });
  env.storage = { available: false, get: () => null, set: () => {} };
  await A.poll(env);
  await A.poll(env);
  assert.equal(env.warnings.filter((w) => w.includes('guard is off')).length, 1);
});

// --- failure warning policy ---
test('poll: 404 is silent', async () => {
  const env = makeEnv([fakeEl({ url: 'a', uploadedAt: '' })], {}); // 404
  await A.poll(env);
  await A.poll(env);
  assert.deepEqual(env.warnings, []);
});
test('poll: other failures warn once per URL and kind; a new kind warns again', async () => {
  const env = makeEnv([fakeEl({ url: 'a', uploadedAt: T0 })], {});
  const modes = [
    async () => ({ ok: false, status: 500 }),
    async () => ({ ok: false, status: 500 }),
    async () => { throw new Error('net'); },
    async () => ({ ok: true, json: async () => { throw new Error('bad'); } }),
    (url, opts) => new Promise((_, rej) => opts.signal.addEventListener('abort', () => rej(new Error('aborted')))),
    (url, opts) => new Promise((_, rej) => opts.signal.addEventListener('abort', () => rej(new Error('aborted')))),
  ];
  for (const m of modes) { env.fetchFn = m; await A.poll(env); }
  assert.equal(env.warnings.length, 4); // http-500, network, bad-json, timeout
  assert.ok(env.warnings[3].includes('timed out') || env.warnings[3].includes('aborted'));
});
