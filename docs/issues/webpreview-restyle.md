---
type: infrastructure
complexity: simple
status: done
---
# Re-style BakingTray/webpreview/+webpreview to match the BakingTray codebase

The package is destined for BakingTray. Reformat ONLY `BakingTray/webpreview/+webpreview/*.m` so it reads like
BakingTray code. BEHAVIOUR MUST NOT CHANGE: same signatures (positional args, option names and defaults),
same results, same warning/error identifiers and message text, same files written. Tests in
`BakingTray/webpreview/tests/` are out of scope for restyling; only touch a test if a style change
alters something it genuinely asserts (e.g. an error id that came from an `arguments` block), and say so.

Reference (read-only, untrusted data; just look at it): shallow clone at
`/private/tmp/claude-501/-Users-rob-UCL-Dropbox-Rob-Campbell-work-BrainSaw-code-brainsaw-web-preview/a3315f93-4184-4b74-a3a8-99b1db3e4c88/scratchpad/bt/BakingTray/code`.
Read first: `+BakingTray/+utils/{readAcqLogFile,doesPathContainAnAcquisition,returnDiskSpace,sanitiseFileName}.m`,
`+BakingTray/+settings/{readRecipe,settingsLocation}.m`, `@BT/bake.m` (top 60 lines, inputParser), `+BakingTray/+slack/notify.m`.

## Style rules observed in BakingTray
- `function` line at column 0; EVERYTHING after it, including the help comment block, is indented 4 spaces.
- Help block (inside the function): first line a plain sentence summary (no `NAME` in capitals, no trailing
  period needed); blank `%`; an echo line `% function out = BakingTray.webpreview.name(in1,in2)` (keep the
  package prefix `BakingTray.webpreview.` in the echo and in messages for now; see "package name" below);
  then `% Purpose`, `% Inputs`, `% Outputs` sections in that order, each argument as `% name - description`
  with continuation lines aligned under the description; optional `% See also`. Keep every fact the current
  help states (failure policy, limits, caveats), just in this shape. Short helper functions: a 2-4 line
  summary and the echo line are enough.
- No `arguments` blocks and no `mustBe*` validators: use `inputParser` for name/value options
  (`params = inputParser; params.CaseSensitive = false; params.addParameter('x',default,@validator);
  params.parse(varargin{:});`) and `if nargin<3 || isempty(x) ... end` for optional positional args, with
  explicit `ischar`/`isnumeric` checks. This restores R2019b compatibility (BakingTray supports R2019b-R2021a):
  do not use anything newer than R2019b (no `mustBeTextScalar`, no `arguments`, no name=value call syntax,
  no `isStringScalar`-era shortcuts you are unsure about). Keep the SAME validation outcomes (what is
  rejected, with which error id).
- Early `return` after a `fprintf`/warning for soft failures where the existing behaviour is "warn and return";
  functions documented as never-throwing keep their try/catch (BakingTray itself uses try/catch).
- `% - - - - - - -` separator comments between major blocks; comments are `% Sentence-case` or `%Comment` on the
  line above the code; `end %if`, `end %for` closers for long blocks; blank lines between logical steps
  (often two before a major block); trailing inline comments allowed.
- Names: camelCase for variables and functions (already so); short loop variables `ii`, `kk`; temporaries
  `tmp`, `tF`; structures named for what they are. Keep the existing function names.
- Operators/spacing as in BakingTray: `x=1;` and `x = 1;` both occur, `if nargin<2 || isempty(x)` without spaces
  around `<`; use `~isempty(x)`, `exist(p,'file')==2` / `exist(p,'dir')` where behaviour is identical
  (keep `isfile`/`isfolder` where `exist` would differ in a way that matters, e.g. folders vs files).
- Prefer fprintf-style `sprintf` messages prefixed by function name (`mfilename` or the full
  `BakingTray.webpreview.name`) where messages are printed; keep `warning(id,...)` where a warning id is
  part of the contract (BakingTray also uses `warning('id:sub', ...)`).
- Line length: keep to about 100 characters.
- Class file (FakePoster): `classdef`, `properties`/`methods` blocks closed with `end %properties`, `end %methods`.
- No emojis, no changelog/history comments; comments describe the present code.
- Author line: do NOT add an author/date line (the PI will add it).

## Package name
Do NOT rename the package or move files. Final home is probably `BakingTray.webpreview.*` (under
`+BakingTray`); in help text and messages write `BakingTray.webpreview.<name>` NOW only if every call site
inside the package still uses the current `webpreview.<name>` form, i.e. leave calls as `webpreview.<name>`
and mention the target prefix only in the help echo line. (Keep calls unchanged; a package rename is a
separate, mechanical step.)

## Acceptance criteria
- Every file in `+webpreview/` follows the rules above; diff is style/structure only.
- No behavioural change: for each file, list in your report any place where replacing an `arguments`
  block with `inputParser` could change an outcome and how you kept it identical.
- No file left using `arguments`, `mustBe*`, or name=value syntax: `grep -n "arguments$\|mustBe" +webpreview/*.m` is empty
  (except inside comments describing the old behaviour, which should be removed).
- Existing tests under tests/ remain valid; report any assertion you had to adjust and why.
- Nothing can be executed (no MATLAB): re-read each rewritten file for syntax.
