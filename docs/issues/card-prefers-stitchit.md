---
type: infrastructure
complexity: complex
status: done
---

<!-- status: todo | in progress | in review | done | blocked |
     awaiting your confirmation -->

# Card and page prefer the StitchIt image; fall back to acq when StitchIt lags

"analysis" = StitchIt, "acq" = BakingTray. "Both" means the existing rule: `acq/` exists and `analysis/` has the same non-empty `sample_id`.

## Rules
1. Only acq data: card thumbnail = acq (unchanged).
2. Only analysis data: card thumbnail = analysis (unchanged; verify it holds).
3. Both exist (normal, not lagging): card thumbnail = the StitchIt image (analysis `tile_thumbnail.jpg` if sent, else its `LastCompleteSection.jpg`). Microscope page: main image = StitchIt image; below it, the acq (BakingTray) image and the montage. The acq image must open and close in the same overlay way the montage does now (thumbnail click -> enlarged overlay of the full image). Reason: the StitchIt image looks better.
4. Lag fallback: StitchIt sometimes crashes, so `analysis/` lags `acq/`. If StitchIt lags acq by MORE than 2 sections (lag > 2; exactly 2 is NOT lagging), the card thumbnail AND the page's main image switch to acq. On the page swap roles: main = acq image; below it the StitchIt image (now old) and the montage, the StitchIt image opening in the overlay like the montage. Lag changes nothing else (finished flag, freshness/staleness, recipe table, log chart stay from acq as now; the finished rule is not touched).
5. Lag definition: lag = (largest finished section n in `bs_parse_acqlog()` of `acq/acqLog.txt`) minus (largest finished section n in `bs_parse_acqlog()` of `analysis/acqLog.txt`). StitchIt uploads its own copy of the acq log every time; if StitchIt crashes its copy freezes while acq's grows. If either log has no finished section, lag is unknown and counts as NOT lagging. The threshold lives in one named constant (2). The analysis log is the analysis PC's synced copy and can be slightly ahead of the section StitchIt has stitched, so the measured lag can be a little smaller than the true lag (noted in `instructions.md`).
   (Before implementation the PI changed the lag definition from a `section` key in `analysis/status.json` to the two acq logs, as written above.)
6. Assets (`?f=`): only files the display rule shows are served; the acq image/thumbnail and analysis files must be served in each layout above, hidden ones still 404. Recipe/log never served. Path-traversal protection unchanged.
7. Auto-refresh: the page must still reload when the layout flips between normal and lagging. The lag changes only when one of the two logs changes, which is an upload, which already changes `bs_version`, so no lag token is added to it.
8. Do not edit `tests/web/upload_contract.json` or its sha256. Do not weaken existing tests.

## Acceptance criteria
- `tests/web/check_pages.sh` (against `php -S`, uploads with curl, real-format recipe fixtures) covers: acq only (card=acq); analysis only (card=analysis); both normal (card=analysis, main=analysis, acq image + montage below, acq overlay markup present); both with lag 3 (card=acq, main=acq, StitchIt image + montage below); lag exactly 2 (not lagging); analysis log with no finished section (not lagging); acq log missing (not lagging); non-matching sample (analysis hidden, its assets 404); asset serving rule in both layouts; thumbnails on both sources in both layouts.
- Node tests in `tests/web` pass; extended only if `js/autorefresh.js` changes.
- `instructions.md` (what the page shows; the lag rule) and `work.md`'s display-rule lines about the card thumbnail updated to match; comments describe the present, not history. The finished-rule text is not edited (a separate item).
- Out of scope: the MATLAB/StitchIt client, `check_deployed.sh`, the finished rule, the orphan-acq problem.
- Helpers/constants that become unused are removed.
