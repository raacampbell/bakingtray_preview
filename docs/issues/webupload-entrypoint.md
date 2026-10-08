---
type: infrastructure
complexity: complex
status: in progress
---

<!-- status: todo | in progress | in review | done | blocked |
     awaiting your confirmation -->

# Move staging and the section-upload entry point into the core; give BakingTray its start/end behaviour

Replaces the earlier plan item `bakingtray-entrypoint`. Prompted by the PI's questions at the end of `work.md`.

## Proposal (PI's idea, with the consequences)
StitchIt needs exactly what `BakingTray.webpreview` has: copy files to a clean folder under the contract names, write
`status.json`, zip, post. So nothing in `BakingTray/+BakingTray/+webpreview` is BakingTray-specific. Move all of it into
`upload_core/+webupload/` and delete the `BakingTray.webpreview` package.

- Moves: `stageFiles`, `stageSpec`, `stageDirFor`, `clearStage`, `clearStageDir`, `toUint8`, `updateSectionImage`.
  `globToRegexp` is deleted (the fixed names made it obsolete).
- `webupload.updateSectionImage(img, recipePath, logPath, cfg, 'Source', src, ...)`:
  - `img` is `[]` (start: delete any staged image, send none), a numeric array (converted with `toUint8`), or a path to
    a jpg (copied as `LastCompleteSection.jpg`).
  - `'Source'` is `acq` or `analysis`, default `acq`; the stage folder is `<StageRoot>/brainsaw_webpreview/<site>/<mic>/<source>`.
  - `'Montage'` (array or file) is accepted only when `Source` is `analysis`; with `acq` it is an error-free refusal
    (`ok = false`, warning), keeping decision 4 (BakingTray never sends a montage).
  - `'Finished', true` with the one-off 429 retry; `'ConnectTimeout'`/`'ResponseTimeout'` pass through. These apply to
    both sources.
- What this buys: one place for the staging rules, StitchIt gets them for free, and the `+BakingTray` package-merge
  hazard (this repo's `BakingTray` folder shadowing the real BakingTray) disappears because there is no longer a
  `+BakingTray` package here at all. Rob's BakingTray call sites become `webupload.updateSectionImage(...)`.
- Cost: BakingTray then depends on StitchIt's core for even the minimum upload (already the plan: "install both").
  The BakingTray-specific folder shrinks to the simulator, READMEs and example call sites.

## Decisions (PI confirmed)
All three accepted: move everything into the core; keep the name `updateSectionImage`; `acq` + `'Montage'` is refused (`ok = false`, warning). `img` may be `[]`, a numeric array (BakingTray) or a path to an image (StitchIt).

## Questions that were asked
1. Do you accept moving all of `+BakingTray/+webpreview` into the core, as above?
2. Keep the name `updateSectionImage`, or rename now that it is generic (e.g. `webupload.uploadSection`)?
3. The `acq` refusal of `'Montage'`: refuse (as proposed) or silently ignore?

## Acceptance criteria (once confirmed)
- All existing staging/updateSectionImage tests move to `upload_core/tests/` and pass; new tests for the file-path image,
  `Source`, and the `acq` montage refusal.
- Start/section/end behaviour as in the agreed plan (no montage for acq, stale image deleted at start, finished + one
  429 retry).
- Simulator, `add_to_path.m`, READMEs, `check_stage.sh` updated; no remaining `BakingTray.webpreview` references.
- Full MATLAB suite green (baseline 175 passed, 0 failed, 2 incomplete before this change; report new counts).
- R2019b compatible.
