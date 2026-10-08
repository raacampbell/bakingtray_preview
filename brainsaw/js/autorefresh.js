// Viewer auto-refresh. Inlined into the pages by lib.php (one source for every
// deployment) and also require()-able from Node for unit tests.
//
// The server marks each watched element with:
//   data-meta-url       URL of that site's meta.json (the JS never builds URLs)
//   data-uploaded-at    uploaded_at the page was rendered with ('' if none)
//   data-stale-after    stale_after_seconds from config
// and, inside it, optionally an element with a data-ago attribute whose text is
// the "X ago" string. The element itself gets/loses the class "stale".
// <body data-server-now> carries the server clock (epoch seconds) so "ago" and
// stale are immune to a wrong client clock.
(function (root) {
  'use strict';

  const POLL_INTERVAL_MS = 5000; // fixed poll period
  const FETCH_TIMEOUT_MS = 4000; // shorter than the poll period so fetches never pile up
  const DEFAULT_STALE_AFTER = 900;

  // Same wording and thresholds as bs_human_ago() in lib.php (parity-tested).
  function humanAgo(seconds) {
    if (seconds < 60) return seconds + 's ago';
    if (seconds < 3600) return Math.floor(seconds / 60) + 'm ago';
    if (seconds < 86400) return Math.floor(seconds / 3600) + 'h ago';
    return Math.floor(seconds / 86400) + 'd ago';
  }

  // Same rule as the server: never uploaded / unparsable is stale, otherwise
  // stale when strictly older than the threshold. uploadedAtMs is epoch ms or null.
  function isStale(uploadedAtMs, nowMs, staleAfterSeconds) {
    if (uploadedAtMs === null || Number.isNaN(uploadedAtMs)) return true;
    return Math.floor((nowMs - uploadedAtMs) / 1000) > staleAfterSeconds;
  }

  // renderedAt: string ('' = none at render time). fetchedAt: string, or null
  // when the fetch failed / 404 (unknown, so never a change).
  function hasChanged(renderedAt, fetchedAt) {
    if (fetchedAt === null) return false;
    return fetchedAt !== renderedAt;
  }

  // server-minus-client clock offset in ms; 0 if the server time is absent/invalid.
  function clockOffset(serverNowSeconds, clientNowMs) {
    const s = Number(serverNowSeconds);
    if (serverNowSeconds === null || serverNowSeconds === '' || !Number.isFinite(s)) return 0;
    return s * 1000 - clientNowMs;
  }

  // Resolve to the current uploaded_at string, or null on any failure
  // (including a timeout). Failures are reported via opts.onFail(url, kind,
  // detail) but never thrown: the next tick simply tries again. kind is one of
  // 'http-404', 'http-<status>', 'timeout', 'network', 'bad-json', 'no-field'.
  async function fetchUploadedAt(url, fetchFn, nowMs, opts) {
    const o = opts || {};
    const timeoutMs = o.timeoutMs === undefined ? FETCH_TIMEOUT_MS : o.timeoutMs;
    const onFail = o.onFail || function () {};
    const sep = url.indexOf('?') === -1 ? '?' : '&';
    const ctrl = new AbortController();
    const timer = setTimeout(function () { ctrl.abort(); }, timeoutMs);
    try {
      let resp;
      try {
        resp = await fetchFn(url + sep + 't=' + nowMs, { cache: 'no-store', signal: ctrl.signal });
      } catch (e) {
        onFail(url, ctrl.signal.aborted ? 'timeout' : 'network', ctrl.signal.aborted ? 'timed out' : String(e));
        return null;
      }
      if (!resp.ok) { onFail(url, 'http-' + resp.status, 'HTTP ' + resp.status); return null; }
      let meta;
      try {
        meta = await resp.json();
      } catch (e) {
        onFail(url, ctrl.signal.aborted ? 'timeout' : 'bad-json', ctrl.signal.aborted ? 'timed out' : String(e));
        return null;
      }
      if (meta && meta.uploaded_at) return String(meta.uploaded_at);
      onFail(url, 'no-field', 'no uploaded_at in response');
      return null;
    } finally {
      clearTimeout(timer);
    }
  }

  // Returns a function that calls warnFn(message) only the first time it sees a given key.
  function makeWarnOnce(warnFn) {
    const seen = new Set();
    return function (key, message) {
      if (seen.has(key)) return;
      seen.add(key);
      warnFn(message);
    };
  }

  // getStorage is a function because merely reading window.sessionStorage can
  // throw (blocked site data). If it does, or later reads/writes throw, the
  // reload-loop guard degrades to off and available is false.
  function safeStorage(getStorage) {
    let storage = null;
    try { storage = getStorage(); } catch (e) { storage = null; }
    return {
      available: storage !== null && storage !== undefined,
      get: function (k) { try { return storage.getItem(k); } catch (e) { return null; } },
      set: function (k, v) { try { storage.setItem(k, v); } catch (e) { /* guard disabled */ } },
    };
  }

  // Loop guard state: {metaUrl: last uploaded_at we reloaded for}, as JSON.
  function readReloaded(env) {
    try {
      const m = JSON.parse(env.storage.get(env.storageKey) || '{}');
      return m && typeof m === 'object' ? m : {};
    } catch (e) {
      return {};
    }
  }

  // --- control flow; env = {doc, fetchFn, reload, now, storage, storageKey, warnOnce, timeoutMs} ---

  function watched(doc) {
    return Array.prototype.slice.call(doc.querySelectorAll('[data-meta-url]'));
  }

  function updateDisplay(el, nowMs, warnOnce) {
    const uploadedAt = el.getAttribute('data-uploaded-at');
    const ms = uploadedAt ? Date.parse(uploadedAt) : null;
    const rawStale = el.getAttribute('data-stale-after');
    let staleAfter = Number(rawStale);
    if (rawStale === null || rawStale === '' || !Number.isFinite(staleAfter)) {
      warnOnce('stale-after', 'autorefresh: missing/invalid data-stale-after, using ' + DEFAULT_STALE_AFTER);
      staleAfter = DEFAULT_STALE_AFTER;
    }
    el.classList.toggle('stale', isStale(ms, nowMs, staleAfter));
    const agoEl = el.querySelector('[data-ago]');
    if (agoEl && ms !== null && !Number.isNaN(ms)) {
      agoEl.textContent = humanAgo(Math.floor((nowMs - ms) / 1000));
    }
  }

  function refreshDisplay(env) {
    const nowMs = env.now();
    watched(env.doc).forEach(function (el) { updateDisplay(el, nowMs, env.warnOnce); });
  }

  // Fetch every watched meta.json and return [{url, value}] for each one whose
  // uploaded_at differs from what the page was rendered with.
  async function findChanges(env) {
    const els = watched(env.doc);
    const nowMs = env.now();
    const fetched = await Promise.all(els.map(function (el) {
      const url = el.getAttribute('data-meta-url');
      return fetchUploadedAt(url, env.fetchFn, nowMs, {
        timeoutMs: env.timeoutMs,
        onFail: function (u, kind, detail) {
          if (kind === 'http-404') return; // expected for a site that has never uploaded
          env.warnOnce('fetch:' + u + ':' + kind, 'autorefresh: cannot read ' + u + ' (' + detail + '); will keep trying');
        },
      });
    }));
    const changes = [];
    els.forEach(function (el, i) {
      if (hasChanged(el.getAttribute('data-uploaded-at') || '', fetched[i])) {
        changes.push({ url: el.getAttribute('data-meta-url'), value: fetched[i] });
      }
    });
    return changes;
  }

  // Reload once if any changed URL has a value we have not already reloaded
  // for (reload-loop guard: a page that still differs after reloading is left alone).
  async function poll(env) {
    const changes = await findChanges(env);
    if (changes.length === 0) return;
    if (env.storage.available === false) {
      env.warnOnce('no-guard', 'autorefresh: sessionStorage unavailable; reload-loop guard is off');
    }
    const done = readReloaded(env);
    if (!changes.some(function (c) { return done[c.url] !== c.value; })) {
      env.warnOnce('loop', 'autorefresh: page still differs from meta.json after reloading; not reloading again');
      return;
    }
    changes.forEach(function (c) { done[c.url] = c.value; });
    env.storage.set(env.storageKey, JSON.stringify(done));
    env.reload();
  }

  function init(win) {
    const doc = win.document;
    const offset = clockOffset(doc.body && doc.body.getAttribute('data-server-now'), Date.now());
    const env = {
      doc: doc,
      fetchFn: win.fetch.bind(win),
      reload: function () { win.location.reload(); },
      now: function () { return Date.now() + offset; },
      storage: safeStorage(function () { return win.sessionStorage; }),
      storageKey: 'autorefresh:' + win.location.href,
      warnOnce: makeWarnOnce(function (m) { console.warn(m); }),
      timeoutMs: FETCH_TIMEOUT_MS,
    };
    let busy = false;
    let pending = false;
    // fromVisibility: a poll requested while one is in flight runs right after it ends.
    function runPoll(fromVisibility) {
      if (doc.hidden) return;
      if (busy) { if (fromVisibility) pending = true; return; }
      busy = true;
      poll(env).then(function () {}, function () {}).then(function () {
        busy = false;
        if (pending) { pending = false; runPoll(false); }
      });
    }
    // Display updates sit outside the busy gate so they continue if a fetch stalls.
    win.setInterval(function () { refreshDisplay(env); runPoll(false); }, POLL_INTERVAL_MS);
    doc.addEventListener('visibilitychange', function () { refreshDisplay(env); runPoll(true); });
  }

  const api = {
    humanAgo, isStale, hasChanged, clockOffset, fetchUploadedAt,
    makeWarnOnce, safeStorage, updateDisplay, refreshDisplay, poll, init,
  };
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  } else if (root && root.document) {
    init(root);
  }
})(typeof window !== 'undefined' ? window : undefined);
