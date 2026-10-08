'use strict';
// Reload-loop guard edge cases: unwritable/corrupt storage, reloading flag, init warnings.
const test = require('node:test');
const assert = require('node:assert/strict');
const A = require('../../brainsaw/js/autorefresh.js');

const T0 = '2026-01-01T00:00:00+00:00';
const T1 = '2026-01-01T00:09:00+00:00';

function fakeEl(url, uploadedAt) {
  const attrs = { 'data-meta-url': url, 'data-uploaded-at': uploadedAt, 'data-stale-after': '900' };
  return {
    getAttribute: (k) => (k in attrs ? attrs[k] : null),
    classList: { toggle() {} },
    querySelector: () => null,
  };
}
const okFetch = (value) => async () => ({ ok: true, json: async () => ({ uploaded_at: value }) });

function makeEnv(storage, value = T1) {
  const warnings = [];
  const env = {
    doc: { querySelectorAll: () => [fakeEl('a', T0)] },
    fetchFn: okFetch(value),
    reloads: 0,
    reload() { env.reloads += 1; },
    now: () => Date.parse('2026-01-01T00:10:00Z'),
    storage,
    storageKey: 'k',
    warnings,
    warnOnce: A.makeWarnOnce((m) => warnings.push(m)),
    timeoutMs: 50,
  };
  return env;
}

test('poll: storage present but setItem throws -> guard off warning, still reloads', async () => {
  const storage = A.safeStorage(() => ({ getItem: () => null, setItem() { throw new Error('quota'); } }));
  const env = makeEnv(storage);
  await A.poll(env);
  assert.equal(env.reloads, 1);
  assert.equal(env.warnings.filter((w) => w.includes('storage not writable')).length, 1);
});

for (const [name, raw] of [['bad JSON', '{oops'], ['null', 'null'], ['string', '"hi"'], ['array', '[]'], ['number', '5']]) {
  test(`poll: ${name} in storage starts fresh and still reloads`, async () => {
    const store = new Map([['k', raw]]);
    const storage = A.safeStorage(() => ({ getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) }));
    const env = makeEnv(storage);
    await A.poll(env);
    assert.equal(env.reloads, 1);
    assert.deepEqual(JSON.parse(store.get('k')), { a: T1 });
  });
}

test('poll: once a reload has been requested, further polls do nothing (no false loop warning)', async () => {
  const store = new Map();
  const storage = A.safeStorage(() => ({ getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) }));
  const env = makeEnv(storage);
  await A.poll(env);
  await A.poll(env);
  await A.poll(env);
  assert.equal(env.reloads, 1);
  assert.deepEqual(env.warnings, []);
});

// --- init with a fake window ---
function makeWin(fetchFn, storageGetter) {
  const listeners = {};
  const win = {
    intervals: [],
    reloads: 0,
    document: {
      hidden: false,
      body: { getAttribute: () => null },
      querySelectorAll: () => [fakeEl('a', T0)],
      addEventListener: (ev, cb) => { (listeners[ev] = listeners[ev] || []).push(cb); },
    },
    fetch: fetchFn,
    setInterval: (cb) => { win.intervals.push(cb); },
    location: { href: 'http://x/', reload: () => { win.reloads += 1; } },
    fire: (ev) => (listeners[ev] || []).forEach((cb) => cb()),
  };
  Object.defineProperty(win, 'sessionStorage', { get: storageGetter });
  return win;
}
const settle = () => new Promise((r) => setImmediate(r));

test('init: throwing sessionStorage getter produces the "guard is off" warning', async () => {
  const warned = [];
  const orig = console.warn;
  console.warn = (m) => warned.push(String(m));
  try {
    const win = makeWin(okFetch(T1), () => { throw new Error('SecurityError'); });
    A.init(win);
    win.intervals[0]();
    await settle();
    assert.equal(win.reloads, 1);
  } finally {
    console.warn = orig;
  }
  assert.equal(warned.filter((m) => m.includes('guard is off')).length, 1);
});

test('init: a visibility event queued behind a poll that reloads does not poll again', async () => {
  let fetches = 0;
  let release;
  const fetchFn = () => { fetches += 1; return new Promise((r) => { release = () => r({ ok: true, json: async () => ({ uploaded_at: T1 }) }); }); };
  const store = new Map();
  const win = makeWin(fetchFn, () => ({ getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) }));
  A.init(win);
  win.intervals[0]();
  win.fire('visibilitychange'); // queued follow-up
  release();
  await settle();
  assert.equal(win.reloads, 1);
  assert.equal(fetches, 1);
});

test('init: a rejecting poll is logged with console.error and polling continues', async () => {
  const errors = [];
  const orig = console.error;
  console.error = (...a) => errors.push(a.join(' '));
  try {
    // doc.querySelectorAll throwing makes poll() reject on its first line.
    const win = makeWin(okFetch(T1), () => null);
    let calls = 0;
    win.document.querySelectorAll = () => { calls += 1; if (calls % 2 === 0) throw new Error('boom'); return []; };
    A.init(win);
    win.intervals[0]();
    await settle();
    win.intervals[0]();
    await settle();
  } finally {
    console.error = orig;
  }
  assert.ok(errors.some((e) => e.includes('poll failed')));
});
