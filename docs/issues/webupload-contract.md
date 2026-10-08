---
type: infrastructure
complexity: complex
status: in review
---

<!-- status: todo | in progress | in review | done | blocked |
     awaiting your confirmation -->

# Core upload: send the microscope ID and source, per-call timeouts, a recipe reader and the status file

The agreed plan (PI, 2026-10-08) has two upload sources: `acq` (BakingTray) and `analysis` (StitchIt, later). The token is per site, and the microscope ID is no longer in the config: it comes from the recipe (`SYSTEM.ID`). The core `webupload` package will later move unchanged into StitchIt, so it must know nothing about BakingTray. Both sources must produce identical uploads, which is why the recipe reader and the status file belong in the core.

## Server contract the core must meet
- POST multipart fields: `site_id`, `microscope_id`, `source` (`acq` or `analysis`), `data` (the zip). Header: `Authorization: Bearer <site token>`.
- The zip must contain `recipe.yml` and `status.json`. The server refuses with 400 otherwise.
- `status.json` is `{"finished": true|false}`.
- Microscope ID normalisation, which must be identical to the PHP server's: take `SYSTEM.ID` from the recipe, trim it, and replace spaces with `_`. The result must match `^[A-Za-z][A-Za-z0-9_-]*$`.

## Changes
- **`webConfig`:**
  - Drop `micID` everywhere (property, validation, example JSON, README).
  - A config file that still has `micID` is an error, with a clear message saying the microscope ID now comes from the recipe. An old config is never half-accepted.
  - The constructor requires the path to the file. Remove the default location and its TODO: where the file lives is BakingTray's decision.
- **`postZip(zipPath, cfg, micID, source, ...)` and `zipAndPost(folder, cfg, micID, source, ...)`:**
  - Send `microscope_id` and `source` with `site_id`.
  - Optional param/value pairs `'ConnectTimeout'` and `'ResponseTimeout'` override the cfg values for that call only. They are used for the start-of-acquisition upload, which needs 5 s / 10 s.
  - If `source` is not `acq`/`analysis`, or `micID` fails the ID rule, return `ok = false` with a message saying why, and send NO request. Never throw: an acquisition must never be interrupted.
- **New recipe reader:**
  - It returns the normalised microscope ID and the sample ID (`sample.ID`) from a recipe file.
  - It returns empty, not an error, for a field it cannot find; postZip's ID check then refuses the upload.
  - `SYSTEM.ID` may contain spaces (e.g. `Scope A` -> `Scope_A`). Use `BakingTray/simulate/sample_data/*.yml` and `simulate.simulatedRecipeText` as test fixtures.
- **New status writer:** writes `status.json` (`{"finished": true|false}`) into a folder.
- **Error IDs:** rename every `webpreview:*` identifier raised in `upload_core` to `webupload:*`, in the code, the tests and `upload_core/README.md`. Identifiers in `BakingTray.webpreview` stay `webpreview:*`, which matches that package's name.
- **Keep the suite green with the MINIMUM change outside the core:** `BakingTray.webpreview.updateSectionImage`, its stage folder and the simulator take the microscope ID from the recipe (via the reader) instead of `cfg.micID`, send `source = 'acq'`, and write `status.json` with `finished = false`. The full BakingTray behaviour (start/end calls, Finished, 429 retry, no montage) is the later item `bakingtray-entrypoint`. Do not do it here.

## Acceptance criteria
- TDD (principle 6). There are tests for:
  - the new postZip/zipAndPost arguments and their validation (no request sent on bad input)
  - the per-call timeouts
  - `webConfig` refusing `micID` and requiring a path
  - the recipe reader: spaces, missing fields, and both fixture recipes
  - the status writer
  - the renamed error IDs
- Check with a local capture of the multipart request, or a fake server as the existing PostZipTest does, that the request body carries `microscope_id` and `source`.
- The full MATLAB suite passes, from the worktree root: `/Applications/MATLAB_R2023b.app/bin/matlab -batch "add_to_path; r=[runtests('upload_core/tests'), runtests('BakingTray/tests'), runtests('BakingTray/simulate/tests')]; disp(table(r))"`. The baseline is 175 passed, 0 failed, 2 incomplete. Report the new counts.
- R2019b compatible: no `arguments` blocks or other post-2019b features.
- Doc-string usage lines and README updated.

## Open after review (merged for testing, 2026-10-08)
Merged at the PI's request before these were fixed. Status stays `in review` until they are.
- Medium: `stageFiles` still uploads the previous staged `recipe.yml` if copying the new one fails (warns `stale`).
  The recipe must never fall back; the log may.
- Medium: undefined by the shared rule, so MATLAB and PHP may disagree: nested or multi-line flow maps, duplicate
  `SYSTEM:`, ` #` inside quotes, commas/braces in quoted flow values, comment lines inside a block, `ID:x` without a
  space, non-ASCII (read as Latin-1, PHP reads UTF-8). Extend the rule and vectors, then both parsers.
- Low: `WebConfigTest.m:146,153` assert MATLAB built-in IDs; `upload_core/README.md` and the vector names still mention
  BakingTray; `updateSectionImage.m:222` comment says "staged recipe"; bad-`source` message omits the value;
  `stageDirFor`/`clearStage` refuse string micIDs; dead folder support in `stageFiles`/`resolveRecipe`.
- Not yet checked: every commit green (fix 9) and docs-vs-code consistency (fix 10).
