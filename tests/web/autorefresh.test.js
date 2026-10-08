'use strict';
// Run from the repo root: node --test tests/web/
const test = require('node:test');
const assert = require('node:assert/strict');
const A = require('../../brainsaw/js/autorefresh.js');
const { humanAgo, isStale, hasChanged, fetchUploadedAt, clockOffset } = require('../../brainsaw/js/autorefresh.js');

// Mirrors bs_human_ago() in lib.php branch by branch.
test('humanAgo: seconds branch', () => {
  assert.equal(humanAgo(0), '0s ago');
  assert.equal(humanAgo(59), '59s ago');
});
test('humanAgo: minutes branch', () => {
  assert.equal(humanAgo(60), '1m ago');
  assert.equal(humanAgo(119), '1m ago');
  assert.equal(humanAgo(3599), '59m ago');
});
test('humanAgo: hours branch', () => {
  assert.equal(humanAgo(3600), '1h ago');
  assert.equal(humanAgo(86399), '23h ago');
});
test('humanAgo: days branch', () => {
  assert.equal(humanAgo(86400), '1d ago');
  assert.equal(humanAgo(86400 * 3 + 5), '3d ago');
});
test('humanAgo: negative (clock skew) stays in seconds branch like PHP', () => {
  assert.equal(humanAgo(-5), '-5s ago');
});

test('isStale: strictly greater than threshold', () => {
  const t0 = Date.parse('2026-01-01T00:00:00Z');
  assert.equal(isStale(t0, t0 + 899 * 1000, 900), false);
  assert.equal(isStale(t0, t0 + 900 * 1000, 900), false);
  assert.equal(isStale(t0, t0 + 901 * 1000, 900), true);
});
test('isStale: never uploaded or unparsable is stale', () => {
  assert.equal(isStale(null, 1000, 900), true);
  assert.equal(isStale(NaN, 1000, 900), true);
});

test('hasChanged: same value', () => {
  assert.equal(hasChanged('2026-01-01T00:00:00+00:00', '2026-01-01T00:00:00+00:00'), false);
});
test('hasChanged: different value', () => {
  assert.equal(hasChanged('2026-01-01T00:00:00+00:00', '2026-01-01T00:00:05+00:00'), true);
});
test('hasChanged: none at render, one now', () => {
  assert.equal(hasChanged('', '2026-01-01T00:00:05+00:00'), true);
});
test('hasChanged: some at render, 404/error now is no change', () => {
  assert.equal(hasChanged('2026-01-01T00:00:00+00:00', null), false);
});
test('hasChanged: none at render, 404 now is no change', () => {
  assert.equal(hasChanged('', null), false);
});

test('fetchUploadedAt: returns uploaded_at, adds cache buster, no-store', async () => {
  let seen;
  const fakeFetch = async (url, opts) => {
    seen = { url, opts };
    return { ok: true, json: async () => ({ uploaded_at: 'X' }) };
  };
  assert.equal(await fetchUploadedAt('system_data/a/meta.json', fakeFetch, 123), 'X');
  assert.equal(seen.url, 'system_data/a/meta.json?t=123');
  assert.equal(seen.opts.cache, 'no-store');
});
test('fetchUploadedAt: 404, network error, bad JSON, missing field all give null', async () => {
  assert.equal(await fetchUploadedAt('u', async () => ({ ok: false }), 1), null);
  assert.equal(await fetchUploadedAt('u', async () => { throw new Error('net'); }, 1), null);
  assert.equal(await fetchUploadedAt('u', async () => ({ ok: true, json: async () => { throw new Error('bad'); } }), 1), null);
  assert.equal(await fetchUploadedAt('u', async () => ({ ok: true, json: async () => ({}) }), 1), null);
});
test('fetchUploadedAt: url that already has a query string uses &', async () => {
  let url;
  await fetchUploadedAt('m.json?x=1', async (u) => { url = u; return { ok: false }; }, 9);
  assert.equal(url, 'm.json?x=1&t=9');
});
