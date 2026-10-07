---
type: infrastructure
complexity: simple
status: done
---
# Upload a folder of preview files to the brainsaw server from MATLAB

Windows+Mac, MATLAB only: no curl, zip.exe, bash, Python. Use built-in `zip` and
`matlab.net.http` (RequestMessage + io.MultipartFormProvider/FileProvider).
Server contract: `brainsaw/lib.php` / `upload.php` zip mode: POST multipart,
header `Authorization: Bearer <token>`, fields `site_id` and `data` (a .zip);
returns JSON `{"status":"ok","files":[...]}` or `{"status":"error",...}` with 401/403/413/415/429.
Only files with extensions jpg jpeg png txt yml yaml json csv log are kept.

Location: `BakingTray/webpreview/`. Functions:
- `webpreview.zipFolder(dir)` -> path of temp zip containing recognised files only (flat).
- `webpreview.postZip(zipPath, cfg)` -> struct(ok, httpStatus, message). `cfg` has url, siteID, token. Never throws on network failure (returns ok=false, so an acquisition is never interrupted); token never printed/logged.
- `webpreview.loadConfig(file)` -> cfg struct from a JSON file kept OUTSIDE the repo (default `~/.brainsaw_webpreview.json`, i.e. `fullfile(userpath-or-home,...)`), errors clearly if missing/incomplete. Ship `webpreview_config.example.json` with placeholders.

## Acceptance criteria
- Unit tests (matlab.unittest) for zipFolder (filters extensions, flat, empty dir -> error) and loadConfig (valid, missing file, missing field).
- postZip tested against a fake server if feasible (e.g. unreachable URL returns ok=false without throwing); document what could not be run.
- No hard-coded paths or secrets; works with `fullfile`.
