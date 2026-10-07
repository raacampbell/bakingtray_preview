---
type: infrastructure
complexity: simple
status: done
---
# Stage the files for one upload: preview JPEG, recipe, acq log

Given a matrix and the paths to the current recipe and acq log, produce a staging
folder the uploader can zip. Server matches by glob: main image `LastCompleteSection*.jpg`,
montage `*montage*.jpg` (optional), recipe `*ecipe*.yml`, log `*cqLog*.txt`.
Examples of real files: `test_images/` (recipe_*.yml, acqLog_*.txt).

Location: `BakingTray/webpreview/`.
- `webpreview.stageFiles(img, recipePath, logPath, stageDir, 'Montage', montageImg)` -> writes
  `LastCompleteSection.jpg` (imwrite, quality ~85; accept uint8 or uint16 gray/RGB; scale non-uint8
  sensibly, documented), copies recipe and log (newest recipe if a folder is given), optional montage.
- Atomic enough: write into stageDir, replacing previous files, so stale recipes don't accumulate.
- Missing recipe/log -> warning, still stages the image (preview must not fail an acquisition).

## Acceptance criteria
- matlab.unittest tests: uint8 RGB, uint16 gray, double 0-1 input; missing log; montage optional; files named as the server globs expect.
- Does not modify the source recipe/log.
