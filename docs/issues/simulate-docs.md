---
type: infrastructure
complexity: simple
status: done
---
# Write BakingTray/simulate/README.md: how to run the simulator, locally and against a remote server

Depends on: simulate-split (merged). Audience: the PI, who knows MATLAB and BakingTray but NOT this web server
(PHP, tokens, config). Assume nothing about the web side; complete but not verbose: numbered steps, exact
commands to copy, what you should see after each step, a short troubleshooting table. No history, no marketing.

## Content (in this order)
1. What this is (3 lines): fakes an acquisition against the Brainsaw web server using the real BakingTray web
   preview code (`BakingTray/webpreview`); test tool only, never part of the BakingTray install.
2. Quick check without any server: dry run (`'DryRun', true`): the exact MATLAB lines, what it prints, where files go.
3. Part A, localhost (do this first), every step from nothing:
   a. Install PHP (macOS: `brew install php`; Windows: say what is needed and where to get it; keep short) and check
      the `zip` extension (`php -m | grep -i zip`).
   b. Start the server from the repo's `brainsaw/` folder with the router and raised upload limits
      (`php -d upload_max_filesize=250M -d post_max_size=250M -S localhost:8000 router.php`); say why the router
      matters (the dev server ignores .htaccess) and that the terminal must stay open.
   c. Make a site and a token ("keys"): pick a site id (letters, digits, `_`, `-`), generate a token
      (`openssl rand -hex 32`, or `php -r 'echo bin2hex(random_bytes(32));'` if no openssl, or
      `brainsaw/scripts/generate_token.sh`), add the entry to `brainsaw/tokens.json` (show the exact JSON, how to
      add to the existing file without breaking commas), no restart needed. Say tokens.json is secret and git-ignored.
   d. Create the MATLAB config file on the machine running MATLAB: path (`~/.brainsaw_webpreview.json`, i.e. the
      home folder; explain how to find it from MATLAB with `getenv('HOME')` / `getenv('USERPROFILE')`), the exact JSON
      fields from the example file (`url`, `siteID`, `token`, optional timeouts), localhost URL
      `http://localhost:8000/upload.php`. Note plain http is allowed only for localhost/127.0.0.1.
   e. Put the code on the MATLAB path (`addpath` for `BakingTray/webpreview` and `BakingTray/simulate`; the exact
      lines, using the repo location; mention `savepath` optional).
   f. Run the simulation (exact call, e.g. 5 sections, Interval 5) and open `http://localhost:8000/site.php?site=<id>`;
      what to look for (section number in the image, "section k of N", montage, metadata table, chart caveat about
      minutes vs `'LogTimeScale'`, ETA), and that the page auto-refreshes every 60 s so reload by hand.
   g. Where the files land (`brainsaw/system_data/<id>/`) and the server log (`brainsaw/logs/upload.log`).
4. Part B, a remote server (after localhost works): what is needed on the host (PHP 8.1+ with `zip`, HTTPS, writable
   `system_data/` and `logs/`); copying the `brainsaw/` folder there (cPanel File Manager or SFTP; do NOT upload a
   `tokens.json` containing tokens you do not want live; create site entries for the remote copy with NEW tokens, never
   reuse localhost ones); protecting `tokens.json` (verify `https://<host>/.../tokens.json` returns 403; point
   to `brainsaw/.htaccess` and instructions.md); PHP limits via `.user.ini`; the safe `test-upload/` canary copy
   (its own tokens/data/log) and why to use it first; the config file with the https URL
   (`https://<host>/<path>/test-upload/upload.php`), running the simulation against it, viewing
   `https://<host>/<path>/test-upload/site.php?site=<id>`; the simulator's safety rule (only localhost or a URL
   containing `test-upload` unless `'AllowProduction', true`); switching to production later (new token in the live
   tokens.json, config URL to the live `upload.php`); rotating a token; removing the test data afterwards.
   Take the real host name and paths ONLY from `instructions.md` (it mentions brainsaw.mouse.vision and
   /brainsaw/test-upload/); otherwise use placeholders like `<your-host>`.
5. Troubleshooting table (symptom -> cause -> fix): HTTP 401, 403 'unknown site_id' (also the PHP post_max_size
   symptom), 413, 415, 429 (rate limit: Interval >= 5 s), 'refused'/connection errors, config errors from
   loadConfig (https required), the simulator refusing a URL, page shows 'no image yet', stale indicator (15 min).
6. Cleaning up (stop the server, delete the test site and its `system_data/<id>/`).

## Rules
- Every command, path, field name, URL and message must be verified against the real code: `brainsaw/lib.php`,
  `config.php`, `router.php`, `upload.php`, `site.php`, `tokens.json` format, `instructions.md`,
  `BakingTray/webpreview/+webpreview/loadConfig.m`, `defaultConfigPath.m`, `checkUrl.m`,
  `BakingTray/simulate/+simulate/simulateAcquisition.m` (option names, defaults, printed lines). Quote messages
  exactly. If something cannot be verified (no PHP/MATLAB here), say so in the README only where it matters.
- Do not paste real tokens. Use obvious placeholders (`PASTE_64_HEX_CHARS_HERE`).
- Keep it under roughly 250 lines; headings per step; MATLAB and shell snippets in fenced blocks.
- README for `BakingTray/webpreview` is not touched by this item.

## Acceptance criteria
- A reader following Part A literally on a fresh Mac gets a populated site page. A reviewer will walk the steps
  against the code to confirm.
