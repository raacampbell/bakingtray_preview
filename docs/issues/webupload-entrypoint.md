---
type: infrastructure
complexity: complex
status: in review
---

<!-- status: todo | in progress | in review | done | blocked |
     awaiting your confirmation -->

# Move staging and the section-upload entry point into the core

StitchIt needs exactly what `BakingTray.webpreview` has: copy files to a clean folder under the contract names, write `status.json`, zip, post. So nothing in `BakingTray/+BakingTray/+webpreview` is BakingTray-specific. Move all of it into `upload_core/+webupload/` and delete the `BakingTray.webpreview` package.

- Moves: `stageFiles`, `stageSpec`, `stageDirFor`, `clearStage`, `clearStageDir`, `toUint8`, `updateSectionImage` (plus their tests, to `upload_core/tests/`). `globToRegexp` is deleted (fixed names made it obsolete). Where sensible merge tiny helpers into their callers (PI prefers fewer, less bitty functions) but do not rewrite working logic needlessly. Rename error/warning IDs `webpreview:*` coming from the moved code to `webupload:*` (code, tests, READMEs).
- `webupload.updateSectionImage(img, recipePath, logPath, cfg, 'Source', src, ...)`:
  - `img` is `[]` (start: delete any staged image first so an old sample's image can never go up with a new recipe; send none), a numeric array (BakingTray; converted with `toUint8` as today), or a path to a jpg (StitchIt; copied in as `LastCompleteSection.jpg`). Anything else: `ok = false` with a warning, never throw (an acquisition must never be interrupted).
  - `'Source'` is `acq` or `analysis`, default `acq`. Stage folder: `<StageRoot>/brainsaw_webpreview/<site>/<mic>/<source>`, mic from the recipe via the core reader.
  - `'Montage'` (numeric array or jpg path) is accepted only with `Source = 'analysis'`; with `acq` it returns `ok = false` and warns, and sends nothing (BakingTray never sends a montage).
  - `'Finished', true` (default false) writes it into `status.json`; only for a Finished call, a 429 reply is retried once after waiting the rate-limit interval plus 1 s. `'ConnectTimeout'`/`'ResponseTimeout'` pass through to the core.
  - Behaviour otherwise as the current `BakingTray.webpreview.updateSectionImage` (guards, never throwing, result struct), minus the old Montage staging for acq.
- Keep `BakingTray/` (this repo's folder) only for what is genuinely BakingTray-side: the simulator (`BakingTray/simulate`), README with the example call sites Rob will write in `bake.m` (start with `'ConnectTimeout',5,'ResponseTimeout',10`; end with `'Finished',true`) and `sliceSample.m` (during the cut), each guarded with `which` and try/catch, now calling `webupload.updateSectionImage(...)`. These are examples; do not change real BakingTray.
- Update: simulator (start, sections, end with finished, no montage, new package/paths), `add_to_path.m` (`upload_core` and `BakingTray/simulate`; the `BakingTray` folder with `+BakingTray` is no longer needed on the path, drop it and the shadowing warning if no `+BakingTray` package remains), all READMEs, `tests/web/check_stage.sh` if affected, no remaining `BakingTray.webpreview` references anywhere. Comments describe the present, not history.

## Acceptance criteria
- Existing staging/updateSectionImage tests moved and passing; new tests for: image as a file path, bad `img` type, `Source` default and `analysis`, stage folder per source, acq + Montage refusal, analysis + Montage accepted (array and path), start call deletes stale staged image, Finished + the single 429 retry.
- Full MATLAB suite passes from the worktree root:
  `/Applications/MATLAB_R2023b.app/bin/matlab -batch "add_to_path; r=[runtests('upload_core/tests'), runtests('BakingTray/tests'), runtests('BakingTray/simulate/tests')]; disp(table(r))"`
- Out of scope: PHP server; `readRecipe.m` parser edge cases; the other open review items except the `stageFiles` stale-recipe fallback (the recipe must never fall back to a previously staged one; the log may), fixed here with a test.
