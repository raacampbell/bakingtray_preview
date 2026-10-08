# simulate

Fakes an acquisition and sends it to a Brainsaw web server, using the real
BakingTray web preview code (`BakingTray/webpreview`). It is a test tool only
and is never part of the BakingTray install.

For each section it builds a synthetic image and montage, appends to a fresh
acquisition log, calls `webpreview.updateSectionImage`, prints one line, then
waits `Interval` seconds. Needs MATLAB R2019b or later, no toolboxes.

`<repo>` is the folder you cloned (it contains `BakingTray/` and `brainsaw/`).
Replace it including the angle brackets, and quote paths with spaces, e.g.
`cd "<repo>/brainsaw"`.

**Never use `~/.brainsaw_webpreview.json` for simulation.** That is the file
real BakingTray reads on every acquisition. The simulator always gets its own
config file via `'ConfigFile'` (below: `.brainsaw_webpreview_sim.json`).

## 0. Put the code on the MATLAB path, then dry-run

No server, config file or site is needed; nothing is sent.

```matlab
repo = '<repo>';    % e.g. '/Users/you/code/brainsaw_web_preview' or 'C:\code\brainsaw_web_preview'
addpath(fullfile(repo,'BakingTray','webpreview'), fullfile(repo,'BakingTray','simulate'))
which simulate.simulateAcquisition      % should print a path
r = simulate.simulateAcquisition('DryRun', true, 'NumSections', 3, 'Interval', 0);
```

Add those two folders, not the `+` folders inside them; do not `savepath`
(it could shadow a real BakingTray install). Each section prints a line like:

```
section 1/3: ok (dry run), HTTP 200: dry run: nothing sent
```

Files go to a new folder under `tempname`, returned in `r.workDir`.
`r.dryRunCalls(end).names` lists what would have been zipped
(`LastCompleteSection.jpg`, `acqLog.txt`, `montage.jpg`, `recipe.yml`).

## Part A. Localhost (do this first)

A **PHP server in a terminal** (A2, stays busy) and **MATLAB**; each step says which.

### A1. Install PHP (terminal)

macOS needs Homebrew (brew.sh) first, then:

```bash
brew install php
php -v                  # should print "PHP 8.x ..."
php -m | grep -i zip    # must print "zip"
```

Windows (unverified): get a PHP 8.1+ zip from windows.php.net, unzip, add its
folder to `PATH`, copy `php.ini-development` to `php.ini`, enable
`extension=zip`; check in cmd with `php -v` and `php -m | findstr /i zip`.

### A2. Start the server (Terminal 1)

```bash
cd "<repo>/brainsaw"
php -S localhost:8000 router.php
```

It should print `Development Server (http://localhost:8000) started`. This
terminal is now busy and must stay open: **open a SECOND Terminal window or
tab for any other shell command.** Stop the server with Ctrl-C. If it prints
`Address already in use`, pick another port (e.g. 8001) here and in the config
`url` (A4) and the page URLs.

The built-in server ignores `.htaccess`; `router.php` makes it refuse recipe
and log files under `/system_data/<site>/` (they can hold pasted secrets). It
does not hide `tokens.json` or `logs/upload.log`, so keep `localhost` in the
command; never use `0.0.0.0` or a LAN address. A simulation zip is a few
hundred KB, so PHP's default upload limits are fine; only for large real zips
add `-d upload_max_filesize=250M -d post_max_size=250M` before `-S`.

### A3. Make a site and a token (Terminal 2, then an editor)

The server only accepts sites listed in `brainsaw/tokens.json`. That file is
secret and git-ignored. The tree may already hold one with demo entries: do
not reuse those tokens.

1. Pick a site id (letters, digits, `_`, `-`), e.g. `sim_local`.
2. Run ONE of these; it prints one 64-character token. Use a new token for
   every site and never paste one into an issue or chat.

   ```bash
   "<repo>/brainsaw/scripts/generate_token.sh"    # runs openssl rand -hex 32
   openssl rand -hex 32
   php -r 'echo bin2hex(random_bytes(32));'       # Windows cmd: php -r "echo bin2hex(random_bytes(32));"
   ```

3. The SAME token goes into `tokens.json` here and into the MATLAB config in
   A4. Edit the file in MATLAB (Mac and Windows): `edit(fullfile(repo,'brainsaw','tokens.json'))`.
   Two entries show the comma rule (between entries, none after the last):
   
   ```json
   {
     "existing_site": { "token": "AN_EXISTING_TOKEN", "display_name": "Existing" },
     "sim_local": { "token": "PASTE_64_HEX_CHARS_HERE", "display_name": "Simulator (local)" }
   }
   ```
   
   If the file is new, keep only the `sim_local` line. `display_name` is
   optional. No restart needed.
4. Optional syntax check (keep the semicolon so tokens are not echoed):
   `jsondecode(fileread(fullfile(repo,'brainsaw','tokens.json')));`
   An invalid `tokens.json` is treated as empty: uploads fail as 403 `unknown site_id`.
5. Checkpoint, before touching the simulator: open
   `http://localhost:8000/index.php`. You should see one card for the new
   site reading `no image yet`.

### A4. Make the MATLAB config (MATLAB)

Pick a home folder (after the addpath in section 0), copy the example file,
and edit the copy:

```matlab
home = getenv('HOME');   % on Windows use getenv('USERPROFILE')
cfg = fullfile(home, '.brainsaw_webpreview_sim.json');
copyfile(fullfile(repo,'BakingTray','webpreview','webpreview_config.example.json'), cfg)
edit(cfg)
```

Replace the contents with this (the example's `_note` key is harmless):

```json
{
  "url": "http://localhost:8000/upload.php",
  "siteID": "sim_local",
  "micID": "sim_mic",
  "token": "PASTE_64_HEX_CHARS_HERE"
}
```

`siteID` and `token` must match the `tokens.json` entry exactly; `micID` is
free-form for now (the server will check it later). Plain
`http://` is accepted only for `localhost` / `127.0.0.1`; else `https://`.

### A5. Run the simulation (MATLAB)

```matlab
r = simulate.simulateAcquisition('ConfigFile', cfg, 'NumSections', 5, 'Interval', 6);
```

There is no default `ConfigFile`, so a forgotten argument cannot reach a
production site. MATLAB is blocked while it runs (about 30 s; Ctrl-C aborts).
You should see one line per section, about 6 s apart:

```
section 1/5: ok, HTTP 200: uploaded
```

and the PHP terminal shows a `POST /upload.php` line for each. Interval 6, not
5: each section is timed from its start, so upload-time variation can bring
two uploads closer than the server's 5 s minimum (HTTP 429, see
Troubleshooting).

Any failure other than 429 stops the run after that section (`r.aborted`,
`r.abortReason`). Then open `http://localhost:8000/site.php?site=sim_local`
and look for:

- the status line `Last updated 3s ago — section 2 of 5`; the image with its
  section number stamped on it and a magnifier on hover (needs internet: jQuery
  comes from code.jquery.com); the link `View montage (all optical planes,
  single channel)`;
- the metadata table: sample `SIMULATED`, total sections = `NumSections`, and
  `Estimated completion` (UTC);
- the chart `Acquisition time per section` (needs 2 sections): its axis is
  minutes and the simulator logs seconds, so it sits near 0.1 min and the ETA
  is about now; `'LogTimeScale', 60` gives a readable chart, with start times
  in the past.

The page auto-refreshes every 60 s; reload by hand.

Files land in `<repo>/brainsaw/system_data/sim_local/`; the server log is
`<repo>/brainsaw/logs/upload.log` (tab separated: time, site id, status, IP,
message). MATLAB-side files are in `r.workDir`.

## Part B. A remote server

Only after Part A works. The host needs PHP 8.1+ with `zip`, HTTPS, and
writable `system_data/` and `logs/`.

### B1. Get the code onto the host

- **Server already runs `brainsaw/`** (the lab's is brainsaw.mouse.vision,
  see `instructions.md` section 9): you only need `test-upload/` plus an
  up-to-date `lib.php` next to it (`test-upload/upload.php` loads
  `../lib.php`). Do NOT overwrite the host's `config.php` or `tokens.json`.
- **First deploy:** upload the whole `brainsaw/` folder (cPanel File Manager
  or SFTP), e.g. to `public_html/brainsaw/`, excluding your local
  `tokens.json`, `logs/*.log` and `system_data/<your sim ids>/`. See
  `instructions.md` section 9 for HTTPS, permissions and protecting
  `tokens.json`; for low PHP limits add `brainsaw/.user.ini` with
  `upload_max_filesize = 250M` and `post_max_size = 250M`.

### B2. Create `test-upload/tokens.json` on the host

`test-upload/` has its own `tokens.json`, `system_data/` and log, so
simulated data never mixes with real data. Generate a NEW token locally (A3
step 2; never reuse a localhost token). In cPanel File Manager open
`test-upload/`, New File `tokens.json`, Edit, paste the A3 JSON with site id
`sim_remote` and the new token. Checkpoints:

- `https://<your-host>/<path>/test-upload/tokens.json` must return 403;
- `https://<your-host>/<path>/test-upload/index.php` shows a card for the new
  site. (For the lab: `https://brainsaw.mouse.vision/brainsaw/test-upload/`,
  from `instructions.md`.)

### B3. Run against it

1. Make a separate config in MATLAB, never the default one:

   ```matlab
   cfgRemote = fullfile(home, '.brainsaw_webpreview_sim_remote.json');
   copyfile(fullfile(repo,'BakingTray','webpreview','webpreview_config.example.json'), cfgRemote)
   edit(cfgRemote)
   ```
   with `url` = `https://<your-host>/<path>/test-upload/upload.php`,
   `siteID` = `sim_remote`, any `micID`, and the new token.
2. Run the A5 call with `'ConfigFile', cfgRemote`.
3. Open `https://<your-host>/<path>/test-upload/site.php?site=sim_remote`.

Safety rule: a real run only accepts a config URL containing `test-upload` or
with host `localhost` / `127.0.0.1`; anything else errors unless you pass
`'AllowProduction', true` (only when you mean to write fake data to that site).

Production later: add a spare site with a new token to the live `tokens.json`
and use a separate config with the live URL and `'AllowProduction', true`.

## Troubleshooting
| Symptom | Cause | Fix |
| --- | --- | --- |
| `Config file not found: <path> (copy webpreview_config.example.json there and fill it in)`, `Config file ... is not valid JSON`, `... is missing field(s): ...`, `... is empty.` | no config at that path, or a typo in it | do A4; `url`, `siteID`, `micID`, `token` are all required |
| `url must start with https:// (http:// is allowed only for localhost/127.0.0.1): <url>` | non-https URL to a remote host | use `https://` |
| `config url "<url>" is neither a localhost url nor contains "test-upload"; refusing to upload fake data` | simulator safety rule | use a localhost or `test-upload` URL |
| `section 1/5: FAILED, HTTP NaN: <message>` | no HTTP reply: server not running, wrong host/port, network (message is MATLAB's own, not verified) | start the server (A2); check `url` |
| HTTP 403 `unknown site_id` / `invalid token` | id not in that deployment's `tokens.json`, `tokens.json` missing/invalid, token differs from config, or the request exceeded PHP's `post_max_size` (form fields dropped) | check entry and JSON; raise `post_max_size` (A2 flags / `.user.ini`) |
| HTTP 400 `no valid zip uploaded` | PHP rejected the file, e.g. over `upload_max_filesize` only | raise `upload_max_filesize` |
| HTTP 413 / 415 (`zip file too large`, `file is not a valid zip archive`, `zip contained no recognized files`, ...) | zip over limits, corrupt, or empty | rerun; check the host's `zip` extension |
| HTTP 429 `uploading too fast` | two uploads for one site under 5 s apart | `'Interval'` of 6 or more; below 5 the simulator warns `simulate:simulateAcquisition:fastInterval`. A 429 does not stop the run |
| HTTP 500 `server error` | host cannot write `system_data/` or `logs/` | fix permissions (0755 usually enough) |
| `server redirected (HTTP 3xx); redirects are not followed, check the url in the config` | wrong URL | fix `url` |
| page says `Unknown site.` / `no image yet` | id not in that deployment's `tokens.json` / nothing uploaded yet | add it (A3); run the simulation; read `logs/upload.log` |

## Cleaning up
Stop the PHP server (Ctrl-C in Terminal 1). Delete the test site's entry from
`tokens.json` (remote: `test-upload/tokens.json`), its `system_data/<id>/`
folder (remote: File Manager or SFTP), and the `_sim` config files (they hold tokens).
