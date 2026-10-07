---
type: infrastructure
complexity: simple
status: done
---
# `updateSectionImage` entry point and README for dropping into BakingTray

Depends on: webpreview-upload, webpreview-stage (merge them first).
`webpreview.updateSectionImage(img, recipePath, logPath, 'ConfigFile', f, 'Montage', m)` stages
then zips then posts; returns the postZip struct; never throws (warns on failure), cleans temp files.
README in `BakingTray/webpreview/`: how to drop in, config file, how BakingTray would call it after
a section completes (example snippet only; we are not editing BakingTray), Windows notes.

## Acceptance criteria
- Test with a stubbed poster/fake URL showing the happy path and the failure-is-nonfatal path.
- README includes the exact call and config setup.
