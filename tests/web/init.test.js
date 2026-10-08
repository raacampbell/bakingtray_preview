'use strict';
// init() wiring with a fake window: timers are captured and fired by hand.
const test = require('node:test');
const assert = require('node:assert/strict');
const A = require('../../brainsaw/js/autorefresh.js');

function fakeEl(url, uploadedAt, staleAfter = '900') {
  const attrs = { 'data-meta-url': url, 'data-uploaded-at': uploadedAt, 'data-stale-after': staleAfter };
  const classes = new Set();
  const ago = { textContent: 'orig' };
  return {
    classes, ago,
    getAttribute: (k) => (k in attrs ? attrs[k] : null),
    classList: { toggle: (c, on) => (on ? classes.add(c) : classes.delete(c)) },
    querySelector: (sel) => (sel === '[data-ago]' ? ago : null),
  };
}

// opts: serverNowSec, els, fetchFn, href, storageGetter
function makeWin(opts) {
  const listeners = {};
  const storeMap = new Map();
  const win = {
    intervals: [],
    reloads: 0,
    document: {
      hidden: false,
      body: { getAttribute: (k) => (k === 'data-server-now' && opts.serverNowSec !== undefined ? String(opts.serverNowSec) : null) },
      querySelectorAll: () => opts.els,
      addEventListener: (ev, cb) => { (listeners[ev] = listeners[ev] || []).push(cb); },
    },
    fetch: opts.fetchFn,
    setInterval: (cb, ms) => { win.intervals.push({ cb, ms }); return win.intervals.length; },
    location: { href: opts.href || 'http://x/index.php', reload: () => { win.reloads += 1; } },
    storeMap,
  };
  const storage = { getItem: (k) => (storeMap.has(k) ? storeMap.get(k) : null), setItem: (k, v) => storeMap.set(k, v) };
  if (opts.storageGetter) Object.defineProperty(win, 'sessionStorage', { get: opts.storageGetter });
  else win.sessionStorage = storage;
  win.fire = (ev) => (listeners[ev] || []).forEach((cb) => cb());
  win.tick = () => win.intervals[0].cb();
  return win;
}

const settle = () => new Promise((r) => setImmediate(r));
const T0 = '2026-01-01T00:00:00+00:00';
const T1 = '2026-01-01T00:09:00+00:00';
const okFetch = (value) => async () => ({ ok: true, json: async () => ({ uploaded_at: value }) });

test('init: schedules a 5 s interval', () => {
  const win = makeWin({ els: [], fetchFn: okFetch(T0) });
  A.init(win);
  assert.equal(win.intervals.length, 1);
  assert.equal(win.intervals[0].ms, 5000);
});

test('init: server clock offset is applied to "ago" and stale', () => {
  // Client clock is an hour slow relative to the server; the upload was 150 s ago server-time.
  const serverNowSec = Math.floor(Date.now() / 1000) + 3600;
  const uploaded = new Date(serverNowSec * 1000 - 150 * 1000).toISOString();
  const el = fakeEl('m', uploaded, '900');
  const win = makeWin({ serverNowSec, els: [el], fetchFn: okFetch(uploaded) });
  A.init(win);
  win.tick();
  assert.equal(el.ago.textContent, '2m ago'); // negative seconds if the offset were dropped
  assert.equal(el.classes.has('stale'), false);
});

test('init: busy gate stops overlapping polls but display keeps refreshing', async () => {
  const el = fakeEl('m', T0);
  let fetches = 0;
  let release;
  const fetchFn = () => { fetches += 1; return new Promise((r) => { release = () => r({ ok: true, json: async () => ({ uploaded_at: T0 }) }); }); };
  const win = makeWin({ els: [el], fetchFn });
  A.init(win);
  win.tick();
  win.tick();
  win.tick();
  assert.equal(fetches, 1);
  assert.notEqual(el.ago.textContent, 'orig'); // display refreshed on every tick
  el.ago.textContent = 'cleared';
  win.tick();
  assert.notEqual(el.ago.textContent, 'cleared'); // still refreshing while the fetch stalls
  release();
  await settle();
  win.tick();
  assert.equal(fetches, 2);
});

test('init: hidden pauses polling; becoming visible polls at once', async () => {
  const el = fakeEl('m', T0);
  let fetches = 0;
  const win = makeWin({ els: [el], fetchFn: async () => { fetches += 1; return { ok: true, json: async () => ({ uploaded_at: T0 }) }; } });
  A.init(win);
  win.document.hidden = true;
  win.tick();
  win.fire('visibilitychange');
  await settle();
  assert.equal(fetches, 0);
  win.document.hidden = false;
  win.fire('visibilitychange');
  await settle();
  assert.equal(fetches, 1);
});

test('init: becoming visible during an in-flight poll queues exactly one poll after it', async () => {
  const el = fakeEl('m', T0);
  let fetches = 0;
  const releases = [];
  const fetchFn = () => { fetches += 1; return new Promise((r) => releases.push(() => r({ ok: true, json: async () => ({ uploaded_at: T0 }) }))); };
  const win = makeWin({ els: [el], fetchFn });
  A.init(win);
  win.tick();
  assert.equal(fetches, 1);
  win.fire('visibilitychange');
  win.fire('visibilitychange');
  assert.equal(fetches, 1); // not overlapping
  releases[0]();
  await settle();
  assert.equal(fetches, 2); // one follow-up poll
  releases[1]();
  await settle();
  assert.equal(fetches, 2); // and no more
});

test('init: change detected through the wiring reloads once', async () => {
  const win = makeWin({ els: [fakeEl('m', T0)], fetchFn: okFetch(T1) });
  A.init(win);
  win.tick();
  await settle();
  assert.equal(win.reloads, 1);
});

test('init: loop-guard storage key is per href', async () => {
  const w1 = makeWin({ els: [fakeEl('m', T0)], fetchFn: okFetch(T1), href: 'http://x/site.php?site=a' });
  const w2 = makeWin({ els: [fakeEl('m', T0)], fetchFn: okFetch(T1), href: 'http://x/site.php?site=b' });
  A.init(w1); A.init(w2);
  w1.tick(); w2.tick();
  await settle();
  assert.deepEqual([...w1.storeMap.keys()], ['autorefresh:http://x/site.php?site=a']);
  assert.deepEqual([...w2.storeMap.keys()], ['autorefresh:http://x/site.php?site=b']);
});

test('init: sessionStorage getter that throws does not stop polling', async () => {
  const el = fakeEl('m', T0);
  const win = makeWin({ els: [el], fetchFn: okFetch(T1), storageGetter: () => { throw new Error('SecurityError'); } });
  A.init(win); // must not throw
  assert.equal(win.intervals.length, 1);
  win.tick();
  await settle();
  assert.equal(win.reloads, 1);
});
