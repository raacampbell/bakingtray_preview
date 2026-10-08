# Brainsaw server — build and operations guide

The Brainsaw server receives a zip from each microscope after every section and shows the
latest image, montage, recipe metadata and per-section timing on private web pages. Code lives
in `brainsaw/`. This document covers: what the files are, the private settings file, view URLs,
running it locally, uploads, adding sites and microscopes, and the auto-refresh. Deploying to
IONOS is in `server-setup.md`. The upload client is the MATLAB `webpreview` package
(`BakingTray/webpreview/README.md`).

`<base>` below is wherever `brainsaw/` is deployed: `http://localhost:8000` locally,
`https://brainsaw.org/testserver` on the test deployment.

## 1. What's in `brainsaw/`

```
brainsaw/
  lib.php          shared logic: settings, upload handling, views, parsers
  config.php       paths and limits (the settings file path, limits, stale threshold)
  upload.php       the upload endpoint (POST)
  view.php         every other missing path lands here: a private view or the one 404 page
  index.php        neutral landing page; lists nothing
  router.php       local only: makes `php -S` apply the same rules as .htaccess (never deployed)
  .htaccess        denies every *.json and every .php but index/upload/view.php; no listings,
                   CGI or MultiViews; the Authorization pass-through; HTTPS redirect; every
                   missing path to view.php
  js/
    autorefresh.js        polls meta, reloads on change, live "ago"/stale (inlined by lib.php)
    jquery-3.7.1.min.js   self-hosted, so no page makes a third-party request
    jquery.imageLens.js   magnifier lens
  system_data/     <site_ID>/<mic_ID>/ per microscope, created by uploads; never served directly
  logs/            upload.log, one line per request; never served directly
```

Automated tests live in `tests/web/` at the repo root, not in `brainsaw/`.

## 2. Sites, microscopes and the private settings file

A **site** is a lab; each site has one or more **microscopes**. Each microscope has its own
token. Everything private lives in one JSON settings file, outside the web root, named by
`settings_file` in `config.php` (locally: `brainsaw_settings.json` next to `brainsaw/`, i.e. at
the repo root, git-ignored; on the server: the path `stage_server.sh` writes in):

```json
{
  "panopticon": "PANOPTICON_WORD",
  "sites": {
    "SITE_ID": {
      "display_name": "Smith lab",
      "microscopes": {
        "MIC_ID":  { "display_name": "Scope A", "token": "PASTE_64_HEX_CHARS_HERE" },
        "MIC_ID2": { "display_name": "Scope B", "token": "PASTE_64_HEX_CHARS_HERE" }
      }
    }
  }
}
```

- IDs and the panopticon word: a letter, then letters, digits, `_` and `-`. `display_name` is
  optional. `panopticon` is optional (no all-sites view without it).
- The file is re-read on every request: no restart needed after editing it.
- It is validated on every load. The panopticon word and the site IDs must all differ, and
  none may equal a file or folder name in `brainsaw/`; microscope IDs within a site must
  differ; case is ignored throughout (`js`, `logs`, `system_data`, ...). To check a file
  before uploading it, from the repo root:
  `php -r 'require "brainsaw/lib.php"; echo bs_validate_settings(json_decode(file_get_contents($argv[1]), true), bs_reserved_names()) ?? "ok", "\n";' FILE`
  (prints `ok` or the reason; never the tokens). An invalid file is logged to the PHP error log
  (`brainsaw: invalid settings file: <reason>`) and treated as empty: every view 404s and every
  upload is refused. Nothing about the problem is shown to visitors.
- Treat site IDs and the panopticon word like passwords: they are the view URLs (§3). Use
  unguessable ones and never put real ones in the repo, an issue or a chat.

## 3. View URLs

| URL | Shows |
|---|---|
| `<base>/` | a plain "Brainsaw" page; lists nothing |
| `<base>/<PANOPTICON_WORD>` | every microscope of every site, grouped by site |
| `<base>/<PANOPTICON_WORD>/<SITE_ID>/<MIC_ID>` | one microscope's page |
| `<base>/<SITE_ID>` | that site's microscopes only |
| `<base>/<SITE_ID>/<MIC_ID>` | one of that site's microscopes |
| anything else | the one 404 page |

"Anything else" includes an unknown word, a known word with an unknown microscope, another
site's microscope through a site word, and every missing page: they all give the same status
and the same body, so probing cannot tell a real word from a made-up one. No view name is in
the code, `.htaccess` or any served file.

Images and meta come through the view, never from `system_data/` directly:
`<microscope page URL>?f=main` (latest section image), `?f=montage`, `?f=meta` (meta.json,
`Cache-Control: no-store`). The view re-checks that its word may see that microscope; recipe
and log files are never servable (a recipe can hold a pasted secret such as a Slack webhook).

Every view response carries `Referrer-Policy: no-referrer` and `X-Robots-Tag: noindex,
nofollow`, and the HTML has a robots `noindex` meta tag, so view URLs do not leak through
Referer headers or search engines. Asset and link URLs are built from the deployment base,
which is where `brainsaw/` sits below the web server's `DOCUMENT_ROOT`, so pages work in any
sub-folder; if the app is not under `DOCUMENT_ROOT` every view is the 404 page (logged).

How requests reach `view.php`: `.htaccess` sends every path that is not an existing file or
folder to it (and switches off `MultiViews`, which could otherwise map `/upload` to
`upload.php`). Before that, it refuses with 403 every `*.json` and every `.php` other than
`index.php`, `upload.php` and `view.php`, so `lib.php` and `config.php` cannot be fetched even
if PHP stopped running; `system_data/.htaccess` and `logs/.htaccess` deny everything in those
folders. `router.php` does all of this for `php -S`.

## 4. Running it locally

Requires PHP 8.1+ with the `zip` extension (`php -m | grep zip`). On macOS: `brew install php`.

1. Create the settings file at the repo root, `brainsaw_settings.json` (git-ignored), as in §2,
   with your own site, microscope, panopticon word and a fresh token (§6).
2. Start the server from `brainsaw/`, **with the router**:

   ```bash
   cd brainsaw
   php -S localhost:8000 router.php
   ```

   PHP's built-in server never reads `.htaccess`; without `router.php` it would serve raw
   recipe and log files from `system_data/` and no view URL would work. Keep `localhost` in
   the command (never `0.0.0.0` or a LAN address).
3. Open `http://localhost:8000/<SITE_ID>`: one card per microscope, reading "no image yet".
   To see a full page without a microscope, either run the simulator
   (`BakingTray/simulate/README.md`) or copy the four files from `test_images/` into
   `brainsaw/system_data/<SITE_ID>/<MIC_ID>/` (git-ignored).

For large real zips add `-d upload_max_filesize=250M -d post_max_size=250M` before `-S`:
Homebrew's defaults (2M/8M) are below the app's limits, and PHP silently drops all form fields
of a request over `post_max_size`, which shows up as a 403.

### Uploading by hand (curl)

Keep the token out of the command line: put the header in a file only you can read.

```bash
( umask 077; printf 'Authorization: Bearer %s\n' "$(cat /path/to/token.txt)" > /tmp/auth.txt )
U=http://localhost:8000/upload.php
curl -X POST "$U" -H @/tmp/auth.txt -F site_id=SITE_ID -F microscope_id=MIC_ID \
  -F "data=@test_images/all_data.zip;type=application/zip"
# -> {"status":"ok","files":["LastCompleteSection_01.jpg", ...]}
rm /tmp/auth.txt
```

| Request | Reply |
|---|---|
| GET instead of POST | 405 |
| no or malformed `Authorization: Bearer` header | 401 |
| unknown site, unknown microscope, missing `microscope_id`, or wrong token | 403 `unknown site_id, microscope_id or token` (the same for all, so the endpoint reveals no IDs; `logs/upload.log` says which) |
| same microscope again within `min_upload_interval_seconds` (5 s) | 429 |
| no `data` file field | 400 |
| zip too large / too many entries / too large unpacked | 413 |
| not a `.zip` / not a valid zip / no recognised files | 415 |

### Automated checks

From the repo root (`node` 18+ and `php` needed):

```bash
node --test tests/web/          # JS logic, control flow, PHP/JS ago-format parity
tests/web/check_pages.sh        # the server on a temp copy with random settings; optional port argument
tests/web/check_stage.sh        # stage_server.sh: only committed files, refusals, deploy keeps data
```

`check_pages.sh` copies `brainsaw/` (tracked and new files only) into a temp folder, writes a
settings file with random words, IDs and tokens (two sites, microscopes including one named
`logs`, a panopticon word), serves it with `php -S ... router.php` under a sub-folder, and
checks the views, the identical 404s (status, headers and body, GET and HEAD), the asset
route, direct-access refusals, the URL base, uploads, logging, rate limits, settings
validation, headers and the auto-refresh wiring.

## 5. What gets uploaded

A zip per section from the MATLAB client, fields `site_id`, `microscope_id` and `data`. The
server unzips it into `system_data/<site_id>/<microscope_id>/`, keeping only base file names
and dropping anything not on the extension whitelist (`jpg jpeg png txt yml yaml json csv log`),
so a stray `.php` or `.htaccess` is never written. It then writes `meta.json` with
`uploaded_at`. Files are found by glob, so names may carry timestamps:

| What | Pattern (newest wins unless noted) | Used for |
|---|---|---|
| Main section image | `LastCompleteSection*.jp*g` | main image + magnifier, card thumbnail |
| Montage | `*[Mm]ontage*.jp*g` | montage link |
| Recipe | `*ecipe*.y*ml` | sample, objective, laser power, resolution, ... |
| Acquisition log(s) | `*cqLog*.txt` (all, merged) | timing chart, progress, ETA estimate |

## 6. Adding and removing sites and microscopes

1. Pick IDs (§2): an unguessable site ID (it is that lab's view URL), e.g.
   `s$(openssl rand -hex 8)`, and a short microscope ID.
2. Generate one token per microscope with `openssl rand -hex 32`. Never reuse a token.
3. Add the entries to the settings file (§2). No restart needed.
4. Send the lab their view URL `<base>/<SITE_ID>`, and for each microscope its `siteID`, `micID`
   and token for the MATLAB config, by a private channel.

Removing: delete the entry. Its data under `system_data/<site>/<mic>/` stays on disk until you
delete it. To revoke a view without touching uploads, there is no separate switch: change the
site ID (and move its data folder) or remove the site. A new site ID also means a new
`siteID` in the MATLAB config of every microscope of that site.

## 7. Config knobs (`config.php`)

| Key | Default | Meaning |
|---|---|---|
| `settings_file` | `../brainsaw_settings.json` | the private settings file (§2); replaced by `stage_server.sh` |
| `max_zip_size` | 200 MB | reject threshold for the raw upload |
| `max_zip_uncompressed_size` | 500 MB | zip-bomb guard: sum of the entries' sizes |
| `max_zip_entries` | 500 | zip-bomb guard: number of files |
| `min_upload_interval_seconds` | 5 | per-microscope rate limit |
| `stale_after_seconds` | 900 | a card or status turns red past this age |

## 8. The microscope page

- **Main image + magnifier**: the newest `LastCompleteSection*.jpg`, with a hover lens.
- **Montage link**: opens the montage in a new tab.
- **Metadata table**: parsed from the recipe by `bs_parse_recipe()` (targeted regexes, no YAML
  extension needed; extend the list there for new fields).
- **Estimated completion**: mean section duration so far × sections remaining, labelled
  "(estimated)".
- **Acquisition-time chart**: inline SVG (no JS library) of minutes per section from every
  `acqLog*.txt`, merged by section number; the dashed line is the mean.

### Auto-refresh and "last updated"

`bs_watch_attrs()` puts `data-meta-url` (the microscope's `?f=meta` URL), `data-uploaded-at`
and `data-stale-after` on each card and on the microscope page's status line; `<body
data-server-now>` carries the server clock. `js/autorefresh.js`, inlined into every view page:

- polls those meta URLs every 5 s (each fetch aborted after 4 s) and reloads when any
  `uploaded_at` changed. A 404 (a microscope that has never uploaded) is silent; other failures
  log one console warning per URL and kind. A per-URL `sessionStorage` guard stops reload loops.
- recomputes the "X ago" text and the stale styling every 5 s against the server clock.
- pauses while the tab is hidden and polls at once when it is shown again.

If `js/autorefresh.js` is missing the page falls back to a 60 s meta refresh; with JavaScript
off a `<noscript>` 60 s refresh is used. A microscope added to the settings file appears on a
grid only after a manual reload.

## 9. Not built yet

- No dedicated estimate file (ETA, laser power / depth / averaging per section).
- No login: access is by unguessable URL only. Anyone given a view URL can pass it on.
- No history: only the latest snapshot per microscope is kept; a new zip overwrites same-named
  files.
