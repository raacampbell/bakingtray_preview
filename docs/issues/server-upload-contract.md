---
type: infrastructure
complexity: complex
status: in review
---

<!-- status: todo | in progress | in review | done | blocked |
     awaiting your confirmation -->

# Server: one token per site, per-source folders, and the new upload contract

The agreed plan (PI, 2026-10-08) has two upload sources: `acq` (BakingTray, the ground truth) and `analysis` (StitchIt, later). Each source gets its own folder, the token is per site, and the microscope ID comes from the recipe. This item is the upload side of the server. The display rule (which source is shown, finished, assets) is the next item, `server-display-rule`, which is cut from this branch, and both merge together. Until then the views read `acq/` only, as a stopgap.

## Settings file
- New shape: `{"panopticon": "...", "sites": {"<site>": {"display_name": "...", "token": "...", "microscopes": {"<mic>": {"display_name": "..."}}}}}`.
- A site's `token` is required, with the same format rule as today's tokens.
- A `token` key inside a microscope is a validation error, so an old-format file is never half-accepted.
- All other validation rules are unchanged.

## Upload contract
- POST multipart fields: `site_id`, `microscope_id`, `source`, `data` (the zip). Header: `Authorization: Bearer <site token>`.
- An unknown site, an unlisted microscope and a wrong token all get exactly today's 403 status and message, so nothing reveals which of them exists. Compare tokens in constant time, as today.
- A `source` other than `acq` or `analysis` gets 400. Check it after authentication, so an unauthenticated client learns nothing new.
- Only these exact base names are extracted, and anything else in the zip is skipped (flattened, as today): `LastCompleteSection.jpg`, `montage.jpg`, `recipe.yml`, `acqLog.txt`, `status.json`. They replace `BS_ZIP_ALLOWED_EXTENSIONS` with `BS_ZIP_ALLOWED_NAMES`.
- `recipe.yml` and `status.json` are required in every upload, otherwise 400.
- `status.json` must be a JSON object whose `finished` is a boolean, otherwise 400. Unknown keys are ignored.
- Microscope ID normalisation, which must be identical to the MATLAB client's: take `SYSTEM.ID` from the uploaded `recipe.yml`, trim it, and replace spaces with `_`. It must equal `microscope_id`, otherwise 400.
  - `SYSTEM.ID` may contain spaces, e.g. `Scope A`. Test this with a real-format recipe: `BakingTray/simulate/sample_data/*.yml` and `BakingTray/simulate/+simulate/simulatedRecipeText.m` show the format.
- The recipe must carry `sample.ID`, otherwise 400.
- Every check runs on the temporary extraction BEFORE the live folder is touched. A refused upload leaves the stored data exactly as it was.

## Storage
- Data lives in `system_data/<site>/<mic>/<source>/`. Its `meta.json` holds `uploaded_at` and `sample_id` (the sample ID from that upload's recipe; the PI asked for this so it never has to be re-parsed).
- New sample: when the upload's sample ID differs from the stored `sample_id`, or none is stored, empty that source folder before moving the new files in. This applies to `acq/` and `analysis/` alike. The same sample merges as today (files not in this upload stay).
- The rate limit is per (site, microscope, source), 5 s as now, so an `analysis` upload never makes an `acq` upload get 429.
- The `upload.log` line also records the source.

## Views (stopgap)
- The existing views read from `<mic>/acq/` instead of `<mic>/`, so the existing view checks still pass.
- Everything else about display (analysis data, finished, assets rule, removing the globs) is `server-display-rule`. Do not do it here.

## MATLAB mirror
- Rename `webupload.allowedExtensions` to `webupload.allowedNames`, returning the five names. Keep Rob's doc-string style and the `end % name` marker.
- `selectUploadable` keeps only files with exactly those names.
- The parity test reads `BS_ZIP_ALLOWED_NAMES`.
- Update every caller and reference.

## Acceptance criteria
- `tests/web/check_pages.sh` covers each rule above:
  - Accepted `acq` and `analysis` uploads made with curl.
  - The identical 403 for an unknown site, an unlisted microscope and a wrong token, and also for an old per-microscope token.
  - 400 for a bad source, a missing `recipe.yml`, a missing or invalid `status.json`, a `SYSTEM.ID` mismatch and a missing sample ID.
  - A `SYSTEM.ID` with a space that normalises to match.
  - Extra files skipped.
  - A new sample empties only that source folder.
  - The same sample merges.
  - A refused upload leaves the folder untouched.
  - Rate limits independent per source.
  - Settings validation: a token inside a microscope is refused, and a site without a token is refused.
  - The existing view checks stay green.
- The node tests in `tests/web` pass. `check_stage.sh` passes, if it is affected.
- The full MATLAB suite passes: `/Applications/MATLAB_R2023b.app/bin/matlab -batch "add_to_path; r=[runtests('upload_core/tests'), runtests('BakingTray/tests'), runtests('BakingTray/simulate/tests')]; disp(table(r))"`, run from the worktree root. The baseline is 175 passed, 0 failed, 2 incomplete. Report the new counts.
- `instructions.md` sections on the settings file and uploads, and the settings shape in `server-setup.md`, are updated. `check_deployed.sh` and the /testserver migration are a later item: leave them.
