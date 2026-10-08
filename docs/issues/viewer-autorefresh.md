---
type: infrastructure
complexity: simple
status: done
---

# Viewer pages refresh themselves when new data is uploaded

The landing page (index.php) and the per-site page (site.php) only change on a
`<meta http-equiv="refresh">` every 45 s / 60 s, so after an upload the PI sees
old content (and the full reload every minute interrupts the magnifier). Pages
must update on their own within a few seconds of an upload, and not reload when
nothing changed.

## Design
- A small client-side poller. Every 5 s (matches the server's per-site upload
  rate limit) it fetches the meta.json URL(s) the page is showing, with a cache
  buster (`?t=<ms>`) and `cache: 'no-store'`. If any `uploaded_at` differs from
  the value the page was rendered with (including: none at render time, one
  now), it calls `location.reload()`.
- The server embeds what to watch in the HTML: on each card (landing page) and on
  the site page, data attributes with the meta.json URL (built from the same
  `url_base` that `bs_load_site_data` already returns) and the rendered
  `uploaded_at` (empty if none). The JS must not hard-code URL layout: a later
  work item will change the folder layout to `<site>/<microscope>`, and only the
  PHP that emits the attributes should need to change.
- "Last updated X ago" and the stale styling are recomputed client-side on each
  tick from `uploaded_at` and a `stale_after_seconds` value embedded by the
  server, using the same wording/thresholds as `bs_human_ago()` and the same
  stale rule, so a dead microscope still turns red without a reload. Keep the
  server-side rendering of these as the initial state.
- Polling pauses while `document.hidden`, and polls immediately when the tab
  becomes visible again. Fetch/JSON errors and 404s never stop polling and
  count as "no change" (a 404 at render time and a 404 now is "no change");
  404s are silent, other failures log one console warning per URL and kind.
- Remove the JS-dependent pages' unconditional meta refresh; keep a no-JS
  fallback: `<noscript><meta http-equiv="refresh" content="60"></noscript>` in
  `<head>`.
- One source for the JS: put it in `brainsaw/js/autorefresh.js` as plain ES2017,
  no dependencies (not jQuery), and have lib.php INLINE it into both pages
  (`<script><?= file_get_contents(__DIR__ . '/js/autorefresh.js') ?></script>`
  or equivalent), so test-upload/ needs no copy. Structure it so the pure parts
  (human-ago formatting, stale decision, change detection) are functions that
  can be unit-tested in Node, with the DOM/timer wiring in a small init.

## Inputs / outputs / interfaces
- lib.php: `bs_render_viewer`, `bs_render_site_page` (HTML only; no change to
  upload handling, data layout, or any URL).
- New: `brainsaw/js/autorefresh.js`, tests under `tests/web/` at the repo root (not inside `brainsaw/`,
  which is deployed whole).

## Acceptance criteria
- Node unit tests (`node --test`, no npm packages) for: human-ago output matches
  `bs_human_ago()` at its boundaries (read its code; cover each branch),
  stale decision at the threshold, change detection (same / different / none→some
  / some→404 treated as no change).
- A PHP-level check, run against `php -S localhost:<port> router.php` started
  from `brainsaw/` on a temp copy or with a throwaway site you remove afterwards
  (do NOT modify tracked demo data or the real `tokens.json`; it is git-ignored
  and may not exist in your worktree — create a temp one for the test and do
  not commit it): index.php and site.php?site=demo_site render, contain the
  inlined script and the data attributes with the correct meta.json URL, have no
  unconditional meta refresh, and the meta.json URL they embed returns 200.
  Same for test-upload/ pages (they must find the inlined JS via lib.php).
  `php -l` clean on every PHP file touched.
- Manual browser check is left to the PI: say exactly what to do (upload with
  the simulator, watch both pages update within ~5 s without manual reload).
- `instructions.md` §3 ("Testing the viewer's stale indicator") and §11 updated
  to describe the new behaviour accurately.

## As built (differences from and additions to the design above)
- Tests live in `tests/web/`: `node --test tests/web/` (unit, control flow with a
  fake DOM, `init()` wiring with a fake window, PHP/JS `humanAgo` parity) and
  `tests/web/check_pages.sh [port]` (renders pages from a secret-free temp copy).
- Clock skew: `<body data-server-now>` gives the server clock; "ago" and stale use
  `Date.now()` plus the offset measured when the script runs (so "ago" can read a
  second or two low).
- Fetches abort after 4 s (counted as no change). The "ago"/stale display updates
  every tick outside the poll busy gate. A visibility change during an in-flight
  poll queues exactly one follow-up poll.
- Error policy: 404 is silent; other failures warn once per URL and failure kind.
- Reload-loop guard: a per-meta-URL map in `sessionStorage` (key per page URL) of
  the last value reloaded for; no second reload for the same value. A
  `sessionStorage` that is unreadable (throws on access) or not writable turns the
  guard off without stopping polling; one console warning is logged the first
  time a change would trigger a reload (not at startup). Once a reload has been
  requested, no further polls run on that page.
- Missing or unreadable `js/autorefresh.js`: error logged, page gets an
  unconditional 60 s meta refresh and no `<script>`.
- Pages send `Cache-Control: no-store`. `stale_after_seconds` is validated
  (`bs_stale_after_seconds()`): a value that is non-numeric or below 1 after int conversion is logged and
  replaced by the default 900 (`BS_DEFAULT_STALE_AFTER_SECONDS`).
- Known limitation: a newly added site appears on the landing page only after a
  manual reload.
