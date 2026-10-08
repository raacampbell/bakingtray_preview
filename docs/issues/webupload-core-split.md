---
type: infrastructure
complexity: simple
status: done
---

<!-- status: todo | in progress | in review | done | blocked |
     awaiting your confirmation -->

# Split the webpreview package into a core `webupload` package and `BakingTray.webpreview`

`BakingTray/webpreview/+webpreview` currently holds both the source-neutral transfer code and the BakingTray-specific staging code. The agreed plan (PI, 2026-10-08) splits it in two. The core will later be moved unchanged into StitchIt, and both BakingTray and StitchIt will call it. The BakingTray-specific half mirrors `code/+BakingTray/+webpreview` in the real BakingTray repo. This item is ONLY the move and rename, with NO behaviour change. Later items change the behaviour, and a pure move first keeps those diffs readable and avoids merge conflicts.

Target layout:
- `upload_core/+webupload/` (package `webupload`): webConfig, zipAndPost, postZip, zipFolder, selectUploadable, allowedExtensions, serverLimits, interpretResponse. Their tests go in `upload_core/tests/` (whichever of PostZipTest, ZipFolderTest, WebConfigTest cover them). Move the core-relevant part of the README to `upload_core/README.md`.
- `BakingTray/+BakingTray/+webpreview/` (called as `BakingTray.webpreview.*`): updateSectionImage, stageFiles, stageSpec, toUint8, stageDirFor, clearStage, clearStageDir, globToRegexp. Tests go in `BakingTray/tests/` (StageFilesTest, UpdateSectionImageTest, and any others that test these). README in `BakingTray/README.md` (or keep it next to the package; your call, but say where).
- `BakingTray/webpreview/` no longer exists. `webpreview_config.example.json` goes with the core (upload_core/).
- `BakingTray/simulate` stays where it is, with its references updated.
- `add_to_path.m` adds `upload_core`, `BakingTray` (the folder containing `+BakingTray`) and `BakingTray/simulate`.

## Acceptance criteria
- Use `git mv`, so history follows the files.
- Every reference is updated: calls inside packages (sibling calls must be package-qualified: `webupload.x` or `BakingTray.webpreview.x`), tests, the simulator, doc-string usage lines and "See also" lines, and paths named in docs (`instructions.md`, `server-setup.md`, READMEs, `claude/*.md` only where they are live docs, and any test that locates lib.php or other files by relative path). `grep -rn "webpreview\." --include=*.m` returns only `BakingTray.webpreview.` uses. A grep for `BakingTray/webpreview` returns nothing outside git history and historical `docs/issues` files (leave those alone).
- No behaviour change. Run the FULL MATLAB suite before the move and after it, and report both pass/fail counts. They must be the same, and all passing. Also run `tests/web/check_pages.sh` and the node tests in `tests/web` if any reference the moved files (e.g. a parity test reading allowedExtensions.m); they must still pass.
- Rob's doc-string style and the `end % name` markers are kept exactly. Only package names in usage lines change.
- Add one sentence to each README: never add this repo's `BakingTray` folder to the path on a rig that has the real BakingTray installed, because the two `+BakingTray` packages would merge and could shadow each other.
