// Viewer auto-refresh. Inlined into the pages by lib.php (one source for every
// deployment) and also require()-able from Node for unit tests.
//
// The server marks each watched element with:
//   data-meta-url       URL of that site's meta.json (the JS never builds URLs)
//   data-uploaded-at    uploaded_at the page was rendered with ('' if none)
//   data-stale-after    stale_after_seconds from config
// and, inside it, optionally an element with a data-ago attribute whose text is
// the "X ago" string. The element itself gets/loses the class "stale".
(function (root) {
  'use strict';

  var POLL_INTERVAL_MS = 5000; // matches the server's per-site upload rate limit

  // Same wording and thresholds as bs_human_ago() in lib.php.
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

  // Resolve to the current uploaded_at string, or null on any failure.
  // Errors are deliberately swallowed: the next tick simply tries again.
  async function fetchUploadedAt(url, fetchFn, nowMs) {
    var sep = url.indexOf('?') === -1 ? '?' : '&';
    try {
      var resp = await fetchFn(url + sep + 't=' + nowMs, { cache: 'no-store' });
      if (!resp.ok) return null;
      var meta = await resp.json();
      return meta && meta.uploaded_at ? String(meta.uploaded_at) : null;
    } catch (e) {
      return null;
    }
  }

  // --- DOM / timer wiring (browser only) ---

  function updateDisplay(el, nowMs) {
    var uploadedAt = el.getAttribute('data-uploaded-at');
    var ms = uploadedAt ? Date.parse(uploadedAt) : null;
    var staleAfter = Number(el.getAttribute('data-stale-after'));
    el.classList.toggle('stale', isStale(ms, nowMs, staleAfter));
    var agoEl = el.querySelector('[data-ago]');
    if (agoEl && ms !== null && !Number.isNaN(ms)) {
      agoEl.textContent = humanAgo(Math.floor((nowMs - ms) / 1000));
    }
  }

  async function tick(doc, fetchFn, reload) {
    var els = Array.prototype.slice.call(doc.querySelectorAll('[data-meta-url]'));
    var nowMs = Date.now();
    els.forEach(function (el) { updateDisplay(el, nowMs); });
    var fetched = await Promise.all(els.map(function (el) {
      return fetchUploadedAt(el.getAttribute('data-meta-url'), fetchFn, nowMs);
    }));
    var changed = els.some(function (el, i) {
      return hasChanged(el.getAttribute('data-uploaded-at') || '', fetched[i]);
    });
    if (changed) reload();
  }

  function init(win) {
    var doc = win.document;
    var busy = false;
    function run() {
      if (doc.hidden || busy) return;
      busy = true;
      tick(doc, win.fetch.bind(win), function () { win.location.reload(); })
        .then(function () { busy = false; }, function () { busy = false; });
    }
    win.setInterval(run, POLL_INTERVAL_MS);
    doc.addEventListener('visibilitychange', run); // run() ignores the hidden case
  }

  var api = { humanAgo: humanAgo, isStale: isStale, hasChanged: hasChanged, fetchUploadedAt: fetchUploadedAt };
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  } else if (root && root.document) {
    init(root);
  }
})(typeof window !== 'undefined' ? window : undefined);
