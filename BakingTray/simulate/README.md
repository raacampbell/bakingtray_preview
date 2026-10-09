# simulate

Fakes an acquisition and sends it to a Brainsaw web server, using the real
web preview code (`webupload` in `upload_core`). It is a test tool only and is
never part of the BakingTray install.

It makes the calls BakingTray makes to `webupload.updateSectionImage`: a start
call (new recipe and log, no image), then for each section a synthetic image
and an appended acquisition log, then an end call with `'Finished', true`. It
prints one line per call and waits `Interval` seconds between calls. No
montage is sent (BakingTray never sends one). Needs MATLAB R2019b or later, no
toolboxes.

`<repo>` is the folder you cloned (it contains `BakingTray/` and `brainsaw/`).
Replace it including the angle brackets, and quote paths with spaces, e.g.
`cd "<repo>/brainsaw"`.

**Never point the simulator at the config file real BakingTray uses.** The
simulator always gets its own config file via `'ConfigFile'` (below:
`.brainsaw_webpreview_sim.json`).

## 0. Put the code on the MATLAB path, then dry-run

No server, config file or site is needed; nothing is sent.

```matlab
repo = '<repo>';    % e.g. '/Users/you/code/brainsaw_web_preview' or 'C:\code\brainsaw_web_preview'
addpath(fullfile(repo,'upload_core'), fullfile(repo,'BakingTray','simulate'))
which simulate.simulateAcquisition      % should print a path
r = simulate.simulateAcquisition('DryRun', true, 'NumSections', 3, 'Interval', 0);
```

Add those two folders, not the `+` folders inside them; do not `savepath`.
From the repo root, `add_to_path` does the same.

Each call prints a line like:

```
start: ok (dry run), HTTP 200: dry run: nothing sent
section 1/3: ok (dry run), HTTP 200: dry run: nothing sent
finish: ok (dry run), HTTP 200: dry run: nothing sent
```

Files go to a new folder under `tempname`, returned in `r.workDir`.
`r.dryRunCalls(end).names` lists what would have been zipped
(`LastCompleteSection.jpg`, `acqLog.txt`, `recipe.yml`, `status.json`, `tile_thumbnail.jpg`; the
start call has no image).

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

The built-in server ignores `.htaccess`; `router.php` applies the same rules
(nothing under `system_data/` or `logs/` is served directly, and the view URLs
work). Keep `localhost` in the command; never use `0.0.0.0` or a LAN address,
since this is a test server. A simulation zip is a few
hundred KB, so PHP's default upload limits are fine; only for large real zips
add `-d upload_max_filesize=250M -d post_max_size=250M` before `-S`.

### A3. Make a site, a microscope and a token (Terminal 2, then an editor)

The server only accepts sites and microscopes listed in the private settings file,
`<repo>/brainsaw_settings.json` locally (next to `brainsaw/`, git-ignored;
format in `instructions.md` section 2). It also defines the view URLs.

1. Pick a site id (a letter, then letters, digits, `_`, `-`), e.g. `sim_local`.
   The microscope id is not chosen here: the simulator sends the recipe's
   `SYSTEM.ID`, which is `brainsaw` for the sample recipe, so list that
   microscope.
2. Run this; it prints one 64-character token. Use a new token for every
   site and never paste one into an issue or chat.

   ```bash
   openssl rand -hex 32
   ```

3. The SAME token goes into the settings file here and into the MATLAB config
   in A4. Edit the file in MATLAB (Mac and Windows):
   `edit(fullfile(repo,'brainsaw_settings.json'))`. If it is new, this is
   the whole file (to add to an existing one, add the site under `"sites"`,
   with a comma between entries and none after the last):

   ```json
   {
     "sites": {
       "sim_local": { "display_name": "Simulator (local)",
         "token": "PASTE_64_HEX_CHARS_HERE",
         "microscopes": { "brainsaw": {} } }
     }
   }
   ```

   `display_name` is optional. No restart needed.
4. Optional syntax check (keep the semicolon so tokens are not echoed):
   `jsondecode(fileread(fullfile(repo,'brainsaw_settings.json')));`
   An invalid file is treated as empty: uploads fail with 403 and views say
   `Not found`; the PHP terminal shows `brainsaw: invalid settings file: <reason>`.
5. Checkpoint, before touching the simulator: open
   `http://localhost:8000/sim_local`. You should see one card for the
   `brainsaw` microscope reading `no image yet`.

### A4. Make the MATLAB config (MATLAB)

Pick a home folder (after the addpath in section 0), copy the example file,
and edit the copy:

```matlab
home = getenv('HOME');   % on Windows use getenv('USERPROFILE')
cfg = fullfile(home, '.brainsaw_webpreview_sim.json');
copyfile(fullfile(repo,'upload_core','webpreview_config.example.json'), cfg)
edit(cfg)
```

Replace the contents with this (the example's `_note` key is harmless):

```json
{
  "url": "http://localhost:8000/upload.php",
  "siteID": "sim_local",
  "token": "PASTE_64_HEX_CHARS_HERE"
}
```

`siteID` and `token` must match the settings file exactly: the server checks
the token per site. The microscope ID is not in this file: it is `SYSTEM.ID` in
the recipe (`brainsaw` for the sample recipe). Plain
`http://` is accepted only for `localhost` / `127.0.0.1`; else `https://`.

### A5. Run the simulation (MATLAB)

```matlab
r = simulate.simulateAcquisition('ConfigFile', cfg, 'NumSections', 5, 'Interval', 6);
```

There is no default `ConfigFile`, so a forgotten argument cannot reach a
production site. MATLAB is blocked while it runs (about 40 s; Ctrl-C aborts).
You should see one line per call (start, 5 sections, finish), about 6 s apart:

```
section 1/5: ok, HTTP 200: uploaded
```

and the PHP terminal shows a `POST /upload.php` line for each. The default
`Interval` is 6 s, not the server's 5 s minimum: each call is timed from the
previous one's start, so upload-time variation could otherwise bring two uploads
closer than the minimum (HTTP 429, see Troubleshooting).

Any failure other than 429 stops the run after that call (`r.aborted`,
`r.abortReason`). Then open `http://localhost:8000/sim_local/brainsaw`
and look for:

- the status line `Last updated 3s ago — section 2 of 5`; the image with its
  section number stamped on it and a magnifier on hover; no montage link;
- the metadata table: sample `SIMULATED`, total sections = `NumSections`, and
  `Estimated completion` (UTC);
- the chart `Acquisition time per section` (needs 2 sections): its axis is
  minutes and the simulator logs seconds, so it sits near 0.1 min and the ETA
  is about now; `'LogTimeScale', 60` gives a readable chart, with start times
  in the past.

The page reloads itself within about 5 s of each upload.

Files land in `<repo>/brainsaw/system_data/sim_local/brainsaw/`; the server log
is `<repo>/brainsaw/logs/upload.log` (tab separated: time, site/microscope,
status, IP, message). MATLAB-side files are in `r.workDir`.

## Part B. A test deployment on the server (<your-host>/testserver)

Only after Part A works. The real deployment is `https://<your-host>/livefeed/`,
and the simulator refuses to send fake data there (see the safety rule below).
To simulate on the server, deploy a separate test copy with its own settings
file, which holds no real data: `./stage_server.sh --dest testserver
--settings-path <path of the test settings file on the server>`, then upload
`staging/testserver/` to `<web root>/testserver/` with the same rsync command as
`send.sh` (its protect filters included). Deploying is in `server-setup.md`;
this part only adds a simulator microscope to that test copy at
`https://<your-host>/testserver/`.

### B1. Add a simulator microscope to the server's settings file

Generate a NEW token locally (A3 step 2; never reuse a localhost token). Add a
site (an unguessable ID: it is the view URL, e.g. the output of
`echo "sim_$(openssl rand -hex 8)"`) with the microscope `brainsaw` (the recipe's `SYSTEM.ID`), and the new token to the
test deployment's settings file on the server (`server-setup.md` section 4).
Checkpoint: `https://<your-host>/testserver/<site id>` shows a card for the
new microscope.

### B2. Run against it

1. Make a separate config in MATLAB, never the one real BakingTray uses:

   ```matlab
   cfgRemote = fullfile(home, '.brainsaw_webpreview_sim_remote.json');
   copyfile(fullfile(repo,'upload_core','webpreview_config.example.json'), cfgRemote)
   edit(cfgRemote)
   ```
   with `url` = `https://<your-host>/testserver/upload.php`, the new `siteID`
   and the new token.
2. Run the A5 call with `'ConfigFile', cfgRemote`.
3. Open `https://<your-host>/testserver/<site id>/brainsaw`.

Safety rule: a real run only accepts a config URL with `testserver` as a whole path segment (no `..`) or
with host `localhost` / `127.0.0.1`; anything else errors unless you pass
`'AllowProduction', true` (only when you mean to write fake data to that site).

## Troubleshooting
| Symptom | Cause | Fix |
| --- | --- | --- |
| `Config file not found: <path> (copy webpreview_config.example.json there and fill it in)`, `Config file ... is not valid JSON`, `... is missing field(s): ...`, `... is empty.` | no config at that path, or a typo in it | do A4; `url`, `siteID`, `token` are all required; a `micID` field is refused, the microscope ID comes from the recipe |
| `url must start with https:// (http:// is allowed only for localhost/127.0.0.1): <url>` | non-https URL to a remote host | use `https://` |
| `config url "<url>" is neither a localhost url nor has a "testserver" path segment; refusing to upload fake data` | simulator safety rule | use a localhost or `testserver` URL |
| `section 1/5: FAILED, HTTP NaN: <message>` | no HTTP reply: server not running, wrong host/port, network (message is MATLAB's own, not verified) | start the server (A2); check `url` |
| HTTP 403 `unknown site_id, microscope_id or token` | site or microscope not in that deployment's settings file, settings file missing/invalid, token differs from config, or the request exceeded PHP's `post_max_size` (form fields dropped); `logs/upload.log` says which | check the entry and JSON; raise `post_max_size` (A2 flags) |
| HTTP 400 `no valid zip uploaded` | PHP rejected the file, e.g. over `upload_max_filesize` only | raise `upload_max_filesize` |
| HTTP 413 / 415 (`zip file too large`, `file is not a valid zip archive`, `zip contained no recognized files`, ...) | zip over limits, corrupt, or empty | rerun; check the host's `zip` extension |
| HTTP 429 `uploading too fast` | two uploads for one microscope under 5 s apart | `'Interval'` of 6 or more; below 5 the simulator warns `simulate:simulateAcquisition:fastInterval`. A 429 does not stop the run |
| HTTP 500 `server error` | host cannot write `system_data/` or `logs/` | fix permissions (0755 usually enough) |
| `server redirected (HTTP 3xx); redirects are not followed, check the url in the config` | wrong URL | fix `url` |
| page says `Not found` / `no image yet` | site or microscope not in the settings file, settings file invalid, or a typo in the URL (case matters) / nothing uploaded yet | add it (A3); run the simulation; read `logs/upload.log` and the PHP terminal |

## Cleaning up
Stop the PHP server (Ctrl-C in Terminal 1). Delete the simulator site from the
settings file (local or on the server), its `system_data/<site>/` folder
(remote: SFTP), and the `_sim` config files (they hold tokens).
