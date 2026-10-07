---
type: infrastructure
complexity: simple
status: done
---
# Split the acquisition simulator out of BakingTray/webpreview into BakingTray/simulate

`BakingTray/webpreview/+webpreview/` must contain ONLY code BakingTray needs to send images and data to the web
(it will be dropped into BakingTray). The simulator is a test tool for the PI, never part of the main BakingTray
install (it may later live in a testing folder). Split them.

## Move to BakingTray/simulate/ (new, sibling of BakingTray/webpreview/)
- Package folder `BakingTray/simulate/+simulate/` (calls become `simulate.<name>`) containing, moved with `git mv`:
  simulateAcquisition, simulatedLogLines, simulatedLogHeader, simulatedImages, simulatedRecipeText,
  simulatedDurationSec, loggedDurationSec, renderNumberMask, FakePoster, simulationSpec.
- `BakingTray/simulate/tests/SimulateAcquisitionTest.m` (moved from webpreview/tests); its PathFixture must add BOTH
  `BakingTray/webpreview` and `BakingTray/simulate`. Fix any path arithmetic (e.g. the brainsaw/lib.php lookup).
- Inside the moved files, calls to the simulator's own pieces change from `webpreview.X` to `simulate.X`;
  calls to the real code stay `webpreview.updateSectionImage`, `webpreview.zipAndPost`, `webpreview.loadConfig`,
  `webpreview.stageSpec` (public functions of the webpreview package). The dependency is one-way: simulate ->
  webpreview, never the reverse.
- Self-contained sample data: copy `test_images/recipe_SW_FG12_3_FG_12_2_191209_120354.yml` to
  `BakingTray/simulate/sample_data/` (check it holds no secret such as a Slack hook URL before copying) and make
  `defaultRecipe()` look there, not in repo-root test_images. Update the help text / spec comments that mention
  test_images accordingly. The simulated recipe copy still gets the neutral SIMULATED sample id.

## Production guard: allow localhost
The current guard refuses a real run unless the config URL contains `test-upload` (or AllowProduction=true).
The PI will first test against a local PHP server (`http://localhost:8000/upload.php`), which can never be
production. Change the guard so a URL whose host is exactly `localhost` or `127.0.0.1` (optional :port, then `/`
or end) is accepted without `test-upload`/AllowProduction; `test-upload` URLs still pass; everything else is refused
as before. No userinfo/look-alike tricks may pass: `http://localhost@evil.example/`, `http://localhost.evil.com/`,
`http://127.0.0.1.evil.com/`, `https://x/localhost`. Update the help text and tests (accept localhost/127.0.0.1 with
and without port, refuse the look-alikes, keep existing refusals). Keep the check in one small pure local function.

## webpreview must be clean
- `grep -rni "simulat\|FakePoster" BakingTray/webpreview` must be empty (code, tests, README, comments, help text).
- Remove the 'Simulating an acquisition' section from `BakingTray/webpreview/README.md` and every sentence that
  mentions the simulator (e.g. in 'Tests and limitations'); keep that README accurate for what remains.
- `webpreview/tests/` keeps all other tests unchanged.

## Style
Moved files keep their BakingTray style; update only what the move requires (package prefix, paths, help echo lines
should read `simulate.<name>`). No behaviour change other than the localhost guard.

## Acceptance criteria
- File layout as above; `git mv` used so history follows.
- Every call site resolved: grep that no `webpreview.simulat*`, `webpreview.FakePoster`, `webpreview.renderNumberMask`,
  `webpreview.loggedDurationSec`, `webpreview.simulationSpec` remains anywhere, and that no `simulate.` call refers to a
  function that does not exist in +simulate.
- Tests updated and valid; nothing can be executed (no MATLAB), so re-read for syntax.
- Do NOT write the user-facing run instructions in this item (a separate item does that), but leave a stub
  `BakingTray/simulate/README.md` with one line.
