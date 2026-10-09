---
type: infrastructure
complexity: complex
status: done
---

<!-- status: todo | in progress | in review | done | blocked |
     awaiting your confirmation -->

# Server: the display rule (analysis data, finished, assets, remove obsolete globs)

The server accepts uploads from two sources, `acq` (BakingTray, ground truth) and `analysis` (StitchIt), stored in `system_data/<site>/<mic>/<source>/` with `meta.json` holding `uploaded_at` and `sample_id`. This item replaces the stopgap views that read `acq/` only.

## Rules
- `acq/` exists: it is the ground truth (image, recipe table, log chart, status, freshness). `analysis/` is shown in addition only if its stored `sample_id` equals `acq/`'s.
- No `acq/`: `analysis/` alone (a BakingTray that is not upgraded).
- Microscope page with matching `analysis/` data: the StitchIt image (`LastCompleteSection.jpg` from analysis) is the large main image; below it, largish thumbnails of the BakingTray image and the StitchIt montage (`montage.jpg`), each enlarging on click. Without matching analysis data the page is as before (BakingTray image, magnifier, no montage).
- Card thumbnail: the BakingTray image (the `analysis/` image when there is no `acq/`).
- Finished comes from the ground-truth source only (PI decision): `acq/status.json`, or `analysis/status.json` when analysis is shown alone. `analysis/` never sets or clears it, so a later StitchIt upload leaves the state finished; only a new `acq` upload with `finished: false` (a resume) clears it. When finished, the card and the page say "finished", the card is not drawn as stale and the page shows no estimated completion.
- `acq/` is the ground truth as soon as its folder exists, so an install in progress or a damaged `meta.json` never lets a hidden `analysis/` take its place; unreadable `meta.json` or `status.json` files are logged and the view still renders.
- Freshness and auto-refresh: staleness comes from the ground-truth source (`acq/`, or `analysis/` when shown alone). The page auto-refreshes when either displayed source changes (update `js/autorefresh.js` and the endpoint it polls, and its node test).
- Assets (`?f=`): only files that the display rule shows are served. A hidden `analysis/` image or montage gives the same 404 as any missing page. The recipe and log are never served. Path-traversal protection stays.
- Remove what the fixed names made obsolete: the newest-file globs for the main image, recipe and log, and any now-unused helpers or constants (check `serverLimits.maxEntries` and its PHP counterpart; remove if unused, in both places, keeping the parity test coherent).

## Acceptance criteria
- `tests/web/check_pages.sh` (run against `php -S`) covers: acq-only; acq + matching analysis (main image, thumbnails, montage present); acq + non-matching analysis (analysis hidden, its assets 404); analysis-only fallback; finished flag shown, newest-source rule, resume clears it, stale not drawn when finished; staleness from the ground truth; asset serving rule including 404 for hidden files and never the recipe or log. Uploads are made with curl, including `analysis` uploads, using the real-format recipe fixtures.
- Node tests in `tests/web` pass (autorefresh test extended). `tests/web/check_stage.sh` passes if affected.
- The full MATLAB suite passes from the worktree root. Baseline 175 passed, 0 failed, 2 incomplete.
- `instructions.md` (what the page shows) and any server doc affected are updated. Comments describe the present, not history.
- Out of scope: `check_deployed.sh`, the /testserver migration, MATLAB upload code, and the known recipe-reader parser edge cases (`readRecipe.m` and the recipe parsing in `lib.php` are unchanged).
