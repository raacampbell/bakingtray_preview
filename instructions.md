# Brainsaw Multi-Site Upload — Build & Operations Guide

This implements `claude/brainsaw-upload-spec.md`, extended with per-site
pages, a magnifier tool, a second (montage) image, and recipe/acquisition-log
parsing. Code lives in `brainsaw/`. This document covers: running it
locally, generating tokens, adding/removing sites, deploying to GoDaddy, and
the client scripts collaborators use.

## 1. What's in `brainsaw/`

```
brainsaw/
  lib.php              # shared logic (upload handling, viewer + site page rendering, parsers)
  config.php            # live deployment config (paths, limits)
  upload.php             # live upload endpoint — thin wrapper around lib.php
  index.php               # live landing page (all sites, grid of thumbnails)
  site.php                 # live per-site page (main image + magnifier + montage + stats + metadata)
  router.php                # local-testing-only: makes `php -S` enforce the same
                              # "no raw recipe/log downloads" rule .htaccess enforces on Apache
  tokens.json                # site_id -> token + display_name (SECRET)
  js/
    jquery.imageLens.js       # magnifier lens plugin (duplicated from brainsaw.mouse.vision)
  system_data/                 # one subdir per site_id, created automatically
    .htaccess                   # blocks execution + directory listing
    demo_site/                   # pre-populated demo data (see §5.1) — safe to delete
  logs/
    upload.log                # one line per request (created automatically)
    .htaccess                   # blocks direct download of the log
  .htaccess                      # blocks tokens.json/*.log, forces HTTPS
  test-upload/                    # throwaway canary deployment, own tokens/system_data/log
    config.php
    upload.php
    index.php
    site.php
    tokens.json
    js/jquery.imageLens.js
    system_data/.htaccess
    logs/.htaccess
    .htaccess
  scripts/
    generate_token.sh              # prints a fresh random token
  clients/
    upload_client.py                 # legacy single-JPEG client (Python)
    upload_client.sh                  # legacy single-JPEG client (curl/MATLAB)
    upload_data_client.py             # zip-based system_data client (Python) — recommended
    upload_data_client.sh              # zip-based system_data client (curl/MATLAB) — recommended
```

`upload.php` / `index.php` / `site.php` are thin: all real logic is in
`lib.php`, driven by the `$config` array each deployment's `config.php`
returns. The live deployment and `test-upload/` share `lib.php` but never
share tokens, data, or logs — that's what makes `test-upload/` a safe place
to test a new site's script before flipping it onto production.

---

## 2. Two ways a site can upload

**Legacy single-image mode** (`image` field): one JPEG, content-validated,
written to `system_data/{site_id}/latest.jpg`. This is the original
protocol and still works — nothing to migrate if a site is already using it.

**Zip mode** (`data` field, recommended for anything new): a `.zip`
containing any mix of the last-completed-section JPEG, the monochrome
montage JPEG, a recipe `.yml`, one or more acquisition-log `.txt` files, etc.
The server unzips it into `system_data/{site_id}/`, flattening paths (only
the base filename is kept) and silently dropping anything not on the
extension whitelist (`jpg jpeg png txt yml yaml json csv log`) — so a
mistakenly-included `.php` or `.htaccess` file in the zip is never written
to disk. This is the mechanism behind §6's "excess information" design: a
site can start sending extra files (a new log, a stats file) at any time
without a server-side deploy, and the server only acts on filenames it
recognizes.

The server finds files by glob pattern, not fixed name, so filenames can
carry timestamps (as BakingTray already does):

| What | Pattern matched | Used for |
|---|---|---|
| Main RGB section image | `LastCompleteSection*.jp*g` (newest) | main image + magnifier |
| Montage (all optical planes, one channel) | `*[Mm]ontage*.jp*g` (newest) | montage link |
| Recipe | `*ecipe*.y*ml` (newest) | sample name, laser power, resolution, objective |
| Acquisition log(s) | `*cqLog*.txt` (all, merged) | per-section timing chart, progress, ETA estimate |

If no `LastCompleteSection*` file is found, it falls back to the legacy
`latest.jpg` so a site can be migrated from one mode to the other without a
gap.

---

## 3. Running it locally for testing

Requires PHP (8.1+; this was built and tested against 8.5) with the `zip`
extension (bundled by default in Homebrew's PHP — check with
`php -m | grep zip`). On macOS:

```bash
brew install php
```

From the `brainsaw/` directory, start PHP's built-in dev server **with the
included router** (see the warning right below for why):

```bash
cd brainsaw
php -S localhost:8000 router.php
```

Open the landing page: http://localhost:8000/index.php — you'll see three
demo entries from `tokens.json`:
- `demo_site` — pre-populated with real BakingTray sample data (§5.1),
  click through to see the magnifier, montage link, metadata table, and
  stats chart all working without uploading anything yourself.
- `our_scope_1` / `smith_lab_scope1` — empty, show "no image yet" until you
  upload something.

**Important local-testing gotcha:** PHP's built-in dev server does **not**
read `.htaccess` at all — the directory-listing/execution blocks and the
`tokens.json`/`*.log` deny rules only take effect on real Apache (GoDaddy).

This matters more than it sounds like it should: `system_data/.htaccess`
denies direct HTTP access to everything except images and `meta.json` —
recipe and acquisition-log files are only ever meant to be read
server-side, because a recipe file can carry an operator-pasted secret (a
real example: BakingTray recipes have a `SLACK: {hook: 'https://hooks.slack.com/...'}`
field for posting acquisition alerts — an incoming-webhook URL, i.e. a
credential, sitting in a file that would otherwise be one raw HTTP request
away from anyone who guesses/enumerates the URL). Without a router, the PHP
dev server would happily serve that file raw at
`http://localhost:8000/system_data/<site>/recipe_*.yml`, unprotected, even
though real Apache would return `403`.

`router.php` (and `test-upload/router.php`) close that gap for local
testing by enforcing the identical rule in PHP — running the dev server
with `php -S localhost:8000 router.php` (not just `php -S localhost:8000`)
is what makes local behavior match production. If you ever start the dev
server without the router for a quick check, don't leave it running on a
shared network, and don't assume a recipe/log file is safe to fetch by URL.

**Also check the upload size limits before testing large files or zips.**
Default `php.ini` on a fresh Homebrew install caps `upload_max_filesize` at
2M and `post_max_size` at 8M — both *below* this app's own limits (10 MB for
a single image, 200 MB for a zip), so a large upload will fail at the
PHP/webserver layer (looks like a confusing "missing site_id" 403, since PHP
silently drops `$_POST`/`$_FILES` when the request exceeds `post_max_size`)
rather than the app's clean `413`. Either edit `php.ini`, or pass ini
overrides on the command line for testing:

```bash
php -d upload_max_filesize=250M -d post_max_size=250M -S localhost:8000 router.php
```

This exact ini mismatch is also called out in the spec (§9 Layer 2) as
something to check for real on GoDaddy — shared hosting sometimes has lower
defaults than expected, and you don't control `php.ini` there, only
per-directory overrides via `.htaccess`/`.user.ini` if your plan allows it.

### Test matrix (curl)

The tokens below are the three demo tokens already in `brainsaw/tokens.json`
— fine for local testing, but treat them as compromised (rotate before
anything goes non-local).

```bash
TOKEN=9bfbdbd251f011ff19ca941a324e09cbeac2d8b77a6184f91551f8682245f32e   # our_scope_1
ZIP_TOKEN=e1486a689b70d9cc2ab2d0db20195c20feb10314625805e3cb944d2e7848db2d   # smith_lab_scope1
BASE=http://localhost:8000/upload.php

# --- legacy single-JPEG mode ---

# valid upload -> {"status":"ok"}, file + meta.json appear atomically
curl -X POST "$BASE" -H "Authorization: Bearer $TOKEN" \
  -F "site_id=our_scope_1" -F "image=@/path/to/some.jpg"

# missing token -> 401
curl -o /dev/null -w '%{http_code}\n' -X POST "$BASE" \
  -F "site_id=our_scope_1" -F "image=@/path/to/some.jpg"

# wrong token -> 403
curl -o /dev/null -w '%{http_code}\n' -X POST "$BASE" \
  -H "Authorization: Bearer wrong" \
  -F "site_id=our_scope_1" -F "image=@/path/to/some.jpg"

# unknown site_id -> 403
curl -o /dev/null -w '%{http_code}\n' -X POST "$BASE" \
  -H "Authorization: Bearer $TOKEN" \
  -F "site_id=nope" -F "image=@/path/to/some.jpg"

# not a real JPEG (renamed .txt) -> 415
echo "hi" > /tmp/fake.jpg
curl -o /dev/null -w '%{http_code}\n' -X POST "$BASE" \
  -H "Authorization: Bearer $TOKEN" \
  -F "site_id=our_scope_1" -F "image=@/tmp/fake.jpg"

# GET instead of POST -> 405
curl -o /dev/null -w '%{http_code}\n' "$BASE"

# rapid back-to-back to same site_id -> second one is 429 (rate limited,
# min_upload_interval_seconds in config.php, default 5s)

# --- zip mode ---

# build a system_data.zip from a directory of files, then upload it
zip -j /tmp/system_data.zip -- /path/to/dir/*
curl -X POST "$BASE" -H "Authorization: Bearer $ZIP_TOKEN" \
  -F "site_id=smith_lab_scope1" -F "data=@/tmp/system_data.zip;type=application/zip"
# -> {"status":"ok","files":["LastCompleteSection.jpg","montage.jpg","recipe_....yml","acqLog_....txt"]}

# a zip containing an evil.php or .htaccess -> those specific entries are
# silently dropped (not written to disk); anything else in the zip that IS
# on the whitelist still succeeds with 200
```

After a valid upload, confirm:

```bash
find brainsaw/system_data/our_scope_1 -type f   # latest.jpg, meta.json
tail brainsaw/logs/upload.log                    # one line per request
```

I ran this full matrix (including the zip-slip / bad-extension cases)
against the actual code while building it — all status codes above are what
the implementation returns, not aspirational.

### Testing the viewer's "stale" indicator

`config.php`'s `stale_after_seconds` (default 900 = 15 min) controls when a
site's card turns red. To see it without waiting 15 minutes, temporarily
lower it (e.g. to `10`), upload once, then watch the page: the "X ago" text
counts up and the card turns red about 10 s after the upload **without a
reload**, because the page recomputes both every 5 s from the embedded
`uploaded_at` and `stale_after_seconds`. Don't ship that config change.

### Testing auto-refresh

Both pages poll each site's `meta.json` every 5 s (`js/autorefresh.js`) and
reload themselves when `uploaded_at` differs from what the page was rendered
with. With the dev server running, open the landing page and a site page,
upload with the simulator or curl (see the test matrix), and both should
update within ~5 s with no manual reload. Polling pauses in background tabs
and runs immediately when the tab is shown again. Fetch errors/404s are
ignored. Without JavaScript the pages fall back to a 60 s `<noscript>` meta
refresh.

Automated checks: `node --test brainsaw/tests/` (pure JS logic) and
`bash brainsaw/tests/check_pages.sh` (renders the pages from a throwaway
copy and checks the embedded script and attributes).

---

## 4. Generating a token

Either:

```bash
brainsaw/scripts/generate_token.sh
```

or directly:

```bash
openssl rand -hex 32
```

or, if you're on a machine with PHP but no `openssl` CLI:

```bash
php -r 'echo bin2hex(random_bytes(32));'
```

Any of the three produce an equivalent 64-character hex token (32 random
bytes). Don't reuse a token across sites, and don't send it anywhere insecure
(paste it into a password manager / encrypted message, not a public issue
tracker).

---

## 5. Adding a new site (microscope)

1. Pick a `site_id`: short slug, `[a-zA-Z0-9_-]` only (this is enforced by
   `upload.php`), e.g. `smith_lab_scope2`.
2. Generate a token (§4 above).
3. Add an entry to `tokens.json` (the live one, or `test-upload/tokens.json`
   if onboarding — see §7):

   ```json
   "smith_lab_scope2": { "token": "<the generated hex string>", "display_name": "Smith Lab - Scope B" }
   ```

   No restart or deploy needed — `config.php` / `lib.php` re-read
   `tokens.json` from disk on every request.
4. Send the collaborator their `site_id` and `token`, plus one of the client
   scripts in `brainsaw/clients/` (§8) with those two values filled in —
   `upload_data_client.*` (zip mode) is the recommended one for any new
   site since it's the one that will pick up new file types later without
   a client-side code change.
5. Have them run a Layer 3 test (§9 of the spec / §7 below) against
   `test-upload/` before switching their production script to the real
   endpoint and `tokens.json` entry.

### 5.1 The demo site

`system_data/demo_site/` is pre-populated with a real (old, finished)
BakingTray acquisition — `LastCompleteSection_01.jpg`, `montage.jpg`, the
matching `recipe_*.yml` and `acqLog_*.txt` — copied from `test_images/` at
the repo root. Its `tokens.json` entry has its own token like any other
site, but it doesn't need to receive uploads to be useful: it exists purely
so you (or anyone else looking at this code) can see what a fully-populated
site page looks like — magnifier, montage link, metadata table, and the
per-section timing chart — without doing an upload first. Safe to delete
(`system_data/demo_site/` and its `tokens.json` entry) once real sites are
live and you don't need it as a visual reference anymore.

## 6. Removing a site

Delete its entry from `tokens.json`. Its uploaded files under
`system_data/{site_id}/` are left on disk (harmless, just stops being
reachable via the landing page's site list); delete the directory manually
if you want it gone entirely.

---

## 7. Testing a new site end-to-end (spec §9 Layers 2–3)

`test-upload/` is a fully separate deployment — own `tokens.json`, own
`system_data/`, own `logs/upload.log` — so you can validate a collaborator's
client script without touching production data.

1. **Layer 2 (deployed, isolated path):** once `brainsaw/` is live on
   GoDaddy, add the new site to `test-upload/tokens.json` (not the live
   `tokens.json`), and confirm:
   ```bash
   curl -X POST https://brainsaw.mouse.vision/brainsaw/test-upload/upload.php \
     -H "Authorization: Bearer <token>" \
     -F "site_id=<site_id>" -F "data=@system_data.zip;type=application/zip"
   ```
   returns `{"status":"ok","files":[...]}`, and the page renders correctly at
   `https://brainsaw.mouse.vision/brainsaw/test-upload/site.php?site=<site_id>`.
2. **Layer 3 (real client, real network):** have the collaborator run their
   actual client script (§8) from their own machine/network, pointed at the
   `test-upload` URL, and confirm the files + `meta.json` timestamp update
   within the expected interval.
3. Only after both pass: add their entry to the live `tokens.json`, give them
   the live URL, and have them switch their production script over. Leave
   their `test-upload/tokens.json` entry in place — it's a standing canary
   for re-testing their script later if it changes.

---

## 8. Client-side upload script (per site)

Four ready-to-send snippets in `brainsaw/clients/`, each needing only
`TOKEN`/`SITE_ID` (and, for local testing, `URL`) edited:

- **`upload_data_client.sh` / `.py`** (recommended) — zips every recognized
  file in a directory and uploads it in one request:
  ```bash
  ./upload_data_client.sh /path/to/dir_with_latest_files
  python upload_data_client.py /path/to/dir_with_latest_files
  ```
  Point `DATA_DIR`/the argument at whatever directory the acquisition
  software drops its latest-section JPEG, montage JPEG, recipe, and
  acquisition log(s) into — the client zips whatever's there with a
  recognized extension, so adding a new file type later (a new stats file,
  say) needs no client-side change, only a server-side parser update.
- **`upload_client.sh` / `.py`** (legacy) — single JPEG only:
  ```bash
  ./upload_client.sh /path/to/latest_downsampled.jpg
  python upload_client.py /path/to/latest_downsampled.jpg
  ```

All four work from MATLAB via `system()` (the `.sh` variants) or can be
imported directly into a Python acquisition pipeline (the `.py` variants,
which expose `upload_latest()` / `upload_system_data()` functions).

---

## 9. Deploying to GoDaddy

1. Upload the whole `brainsaw/` folder to `public_html/brainsaw/` via cPanel
   File Manager or FTP/SFTP.
2. **Move `tokens.json` outside `public_html` if your GoDaddy plan allows
   it** (commonly possible via cPanel — look for a directory selector above
   `public_html`), then update `tokens_file` in `config.php` (and
   `test-upload/config.php`) to the new absolute path. If that's not
   possible, the `.htaccess` deny rule already in `brainsaw/.htaccess` is the
   fallback — verify it actually blocks the file:
   ```bash
   curl -o /dev/null -w '%{http_code}\n' https://brainsaw.mouse.vision/brainsaw/tokens.json
   ```
   should return `403`, not `200`.
3. Confirm HTTPS is enabled (AutoSSL via cPanel) — `brainsaw/.htaccess`
   redirects HTTP to HTTPS automatically once deployed.
4. Confirm `system_data/` and `logs/` are writable by the webserver user
   (GoDaddy shared hosting usually makes this automatic; if `mkdir`/`write`
   fails with a `500`, check permissions — `0755` on the directories is
   normally sufficient).
5. Confirm the `zip` PHP extension is enabled (`php -m | grep zip` via SSH,
   or a temporary `phpinfo()` scratch file — delete it after). GoDaddy's
   stock cPanel PHP builds normally include it, but check before relying on
   zip-mode uploads.
6. Check `upload_max_filesize` / `post_max_size` in the effective `php.ini`
   comfortably exceed a zip's expected size (a compressed section image +
   montage + recipe + log is usually well under 5 MB, but leave headroom) —
   raise via a `.user.ini` in `brainsaw/` if GoDaddy's PHP runs as CGI/FPM
   (most cPanel PHP does), e.g.:
   ```ini
   upload_max_filesize = 250M
   post_max_size = 250M
   ```
   GoDaddy shared hosting doesn't meter storage volume, and this app has no
   bandwidth-heavy pattern (a few MB per section, occasional viewer page
   loads) — but if throttling ever becomes visible, that's a `.user.ini`
   knob to revisit, not a code change.
7. Run the Layer 2 and Layer 3 tests from §7 against `test-upload/` before
   pointing any real scope at the live `upload.php`.
8. Migrate the 3 existing scopes off the old SSH/rsync script one at a time;
   keep the old script running in parallel briefly as a safety net, then
   retire it once the HTTPS uploads are confirmed reliable.

---

## 10. Config knobs (`config.php`)

| Key | Default | Meaning |
|---|---|---|
| `max_file_size` | 10 MB | legacy single-JPEG reject threshold, independent of PHP ini limits |
| `max_zip_size` | 200 MB | zip-mode reject threshold (raw upload size) |
| `max_zip_uncompressed_size` | 500 MB | zip-bomb guard — sum of all entries' uncompressed sizes |
| `max_zip_entries` | 500 | zip-bomb guard — max number of files in one archive |
| `min_upload_interval_seconds` | 5 | per-site rate limit; reject if same site uploaded more recently than this |
| `stale_after_seconds` | 900 (15 min) | landing/site page marks a site as stale past this age |

Both the live `config.php` and `test-upload/config.php` have their own copy
of these — edit both if you want the same limits in both places.

---

## 11. What the site page shows, and where each field comes from

`site.php?site=<site_id>` (linked from every card on the landing page):

- **Main image + magnifier** — `LastCompleteSection*.jpg`, with the same
  hover-to-zoom lens as `brainsaw.mouse.vision` (`js/jquery.imageLens.js` is
  a straight copy of that page's plugin, wired up the same way).
- **Montage link** — opens `montage*.jpg` (the all-optical-planes,
  single-channel image) in a new tab, if one has been uploaded.
- **Metadata table** — sample ID, objective, laser power, resolution
  (X/Y/Z voxel size), optical planes per section, frames averaged, total
  planned sections, acquisition start time — all parsed from the recipe
  `.yml` by `bs_parse_recipe()` in `lib.php`. This is a targeted-regex
  parser, not a general YAML parser (deliberately, to avoid depending on a
  `yaml` PHP extension that may not exist on shared hosting) — extend the
  regex list there if a new recipe field becomes useful.
- **Estimated completion** — computed, not uploaded: average per-section
  duration seen in the acquisition log(s) so far × sections remaining. Only
  shown once there's enough log data to compute it, and is explicitly
  labeled "(estimated)". Once a dedicated ETA/estimate file exists (per the
  plan to add laser-power-per-section, objective depth-per-section, and
  frames-averaged-per-section files), replace this estimate with the real
  value in `bs_render_site_page()`.
- **Acquisition-time chart** — an inline server-rendered SVG (no JS charting
  library, no CDN dependency) plotting per-section acquisition duration
  (minutes) against section number, parsed from every `acqLog*.txt` file
  present by `bs_parse_acqlogs()`. Multiple log files for one site are
  merged and de-duplicated by section number. The dashed line is the mean.

### Auto-refresh and "last updated"

`bs_watch_attrs()` puts `data-meta-url`, `data-uploaded-at` and
`data-stale-after` on each landing-page card and on the site page's status
line. `js/autorefresh.js` (the single source, inlined into both pages by
`bs_autorefresh_script()` so `test-upload/` needs no copy) polls those meta
URLs every 5 s, reloads when any `uploaded_at` changed (including none to
some), and recomputes the "X ago" text and the red stale styling using the
same wording and threshold as `bs_human_ago()` and the server's stale rule.
The script never builds URLs itself, so changing the data folder layout only
affects the PHP that emits the attributes.

---

## 12. Explicitly not built yet

- No dedicated "estimate" file (planned: ETA, laser power per section,
  objective depth per section, frames averaged per section) — §11's ETA is
  a rough estimate computed from the acquisition log until that file exists.
- No object storage, no database server, no queueing/load balancing, no
  login system on the viewer (add HTTP Basic Auth at the Apache level if
  needed later), no historical image/data archive — only the latest
  `system_data/{site_id}/` snapshot is ever retained; a fresh zip upload
  overwrites same-named files in place.
