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
  // (including a timeout). Failures are reported via opts.onFail but never
  // thrown: the next tick simply tries again.
  async function fetchUploadedAt(url, fetchFn, nowMs, opts) {
    const o = opts || {};
    const timeoutMs = o.timeoutMs === undefined ? FETCH_TIMEOUT_MS : o.timeoutMs;
    const onFail = o.onFail || function () {};
    const sep = url.indexOf('?') === -1 ? '?' : '&';
    const ctrl = new AbortController();
    const timer = setTimeout(function () { ctrl.abort(); }, timeoutMs);
    try {
      const resp = await fetchFn(url + sep + 't=' + nowMs, { cache: 'no-store', signal: ctrl.signal });
      if (!resp.ok) { onFail(url, 'HTTP ' + resp.status); return null; }
      const meta = await resp.json();
      if (meta && meta.uploaded_at) return String(meta.uploaded_at);
      onFail(url, 'no uploaded_at in response');
      return null;
    } catch (e) {
      onFail(url, ctrl.signal.aborted ? 'timed out' : String(e));
      return null;
    } finally {
      clearTimeout(timer);
    }
  }

  // Run fn(key) the first time a key is seen.
  function makeWarnOnce(warnFn) {
    const seen = new Set();
    return function (key, message) {
      if (seen.has(key)) return;
      seen.add(key);
      warnFn(message);
    };
  }

  // sessionStorage may throw (privacy modes); the guard then degrades to off.
  function safeStorage(storage) {
    return {
      get: function (k) { try { return storage.getItem(k); } catch (e) { return null; } },
      set: function (k, v) { try { storage.setItem(k, v); } catch (e) { /* guard disabled */ } },
    };
  }

  // --- control flow; env = {doc, fetchFn, reload, now, storage, storageKey, warnOnce, timeoutMs} ---

  function watched(doc) {
    return Array.prototype.slice.call(doc.querySelectorAll('[data-meta-url]'));
  }

  function updateDisplay(el, nowMs, warnOnce) {
    const uploadedAt = el.getAttribute('data-uploaded-at');
    const ms = uploadedAt ? Date.parse(uploadedAt) : null;
    let staleAfter = Number(el.getAttribute('data-stale-after'));
    if (!Number.isFinite(staleAfter) || el.getAttribute('data-stale-after') === null || el.getAttribute('data-stale-after') === '') {
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

  // Fetch every watched meta.json; reload once if any differ, unless we
  // already reloaded for exactly this set of values (reload-loop guard).
  async function poll(env) {
    const els = watched(env.doc);
    const nowMs = env.now();
    const fetched = await Promise.all(els.map(function (el) {
      const url = el.getAttribute('data-meta-url');
      return fetchUploadedAt(url, env.fetchFn, nowMs, {
        timeoutMs: env.timeoutMs,
        onFail: function (u, why) { env.warnOnce('fetch:' + u, 'autorefresh: cannot read ' + u + ' (' + why + '); will keep trying'); },
      });
    }));
    const changes = [];
    els.forEach(function (el, i) {
      if (hasChanged(el.getAttribute('data-uploaded-at') || '', fetched[i])) {
        changes.push(el.getAttribute('data-meta-url') + '=' + fetched[i]);
      }
    });
    if (changes.length === 0) return;
    const signature = changes.join('|');
    if (env.storage.get(env.storageKey) === signature) {
      env.warnOnce('loop', 'autorefresh: page still differs from meta.json after reloading; not reloading again');
      return;
    }
    env.storage.set(env.storageKey, signature);
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
      storage: safeStorage(win.sessionStorage),
      storageKey: 'autorefresh:' + win.location.href,
      warnOnce: makeWarnOnce(function (m) { console.warn(m); }),
      timeoutMs: FETCH_TIMEOUT_MS,
    };
    let busy = false;
    function runPoll() {
      if (doc.hidden || busy) return;
      busy = true;
      poll(env).then(function () { busy = false; }, function () { busy = false; });
    }
    // Display updates sit outside the busy gate so they continue if a fetch stalls.
    win.setInterval(function () { refreshDisplay(env); runPoll(); }, POLL_INTERVAL_MS);
    doc.addEventListener('visibilitychange', function () { refreshDisplay(env); runPoll(); });
  }

  const api = {
    humanAgo, isStale, hasChanged, clockOffset, fetchUploadedAt,
    makeWarnOnce, safeStorage, updateDisplay, refreshDisplay, poll,
  };
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  } else if (root && root.document) {
    init(root);
  }
})(typeof window !== 'undefined' ? window : undefined);
