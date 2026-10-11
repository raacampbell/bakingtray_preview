# Brainsaw server — build and operations guide

The Brainsaw server receives a zip from each microscope after every section and shows the
latest image, montage, recipe metadata and per-section timing on private web pages. Code lives
in `brainsaw/`. This document covers: what the files are, the private settings file, view URLs,
running it locally, uploads, adding sites and microscopes, and the auto-refresh. Deploying to
IONOS is in `server-setup.md`. The upload client is the MATLAB package `webupload`, which
lives in the StitchIt repo; what the two must agree on is in section 10.

`<base>` below is wherever `brainsaw/` is deployed: `http://localhost:8000` locally,
`https://mouse.vision/livefeed` on the live deployment (later `https://brainsaw.org/livefeed`).

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
  system_data/     <site_ID>/<mic_ID>/<source>/ per microscope and source, created by uploads; never served directly
  logs/            upload.log, one line per request; never served directly
```

Automated tests live in `tests/web/` at the repo root, not in `brainsaw/`.

## 2. Sites, microscopes and the private settings file

A **site** is a lab; each site has one or more **microscopes**. The token belongs to the site:
every microscope of the site uploads with it. Everything private lives in one JSON settings file, outside the web root, named by
`settings_file` in `config.php` (locally: `brainsaw_settings.json` next to `brainsaw/`, i.e. at
the repo root, git-ignored; on the server: the path `stage_server.sh` writes in):

```json
{
  "panopticon": "PANOPTICON_WORD",
  "sites": {
    "SITE_ID": {
      "display_name": "Smith lab",
      "token": "PASTE_64_HEX_CHARS_HERE",
      "microscopes": {
        "MIC_ID":  { "display_name": "Scope A" },
        "MIC_ID2": { "display_name": "Scope B" }
      }
    }
  }
}
```

- IDs and the panopticon word: a letter, then letters, digits, `_` and `-`. `display_name` is
  optional. Each site needs a `token` of at least 32 characters without white space; a `token`
  inside a microscope is an error, so a file in the old per-microscope format is refused whole. `panopticon` is optional (no all-sites view without it).
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
`<microscope page URL>?f=main` (the main image: StitchIt's, or BakingTray's when StitchIt lags),
`?f=tile` (its client-made thumbnail), `?f=bakingtray` and `?f=bakingtray_tile` (the BakingTray
image and its thumbnail), `?f=stitchit` and `?f=stitchit_tile` (the StitchIt image and its thumbnail),
`?f=montage` and `?f=montage_tile` (the StitchIt montage and its thumbnail; a thumbnail is served
only beside its image), `?f=meta` (a small JSON with the
`version` that auto-refresh polls, `Cache-Control: no-store`). The view re-checks that its word
may see that microscope; only files the display rule (§5) shows are served, and anything else,
such as a hidden `analysis/` image, gets the same 404 as any missing page. Recipe and log files
are never servable (a recipe can hold a pasted secret such as a Slack webhook).

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
   To see a full page without a microscope, upload one of the zips described in §5. The data
   lands in `brainsaw/system_data/<SITE_ID>/<MIC_ID>/<source>/` (git-ignored).

For large real zips add `-d upload_max_filesize=250M -d post_max_size=250M` before `-S`:
Homebrew's defaults (2M/8M) are below the app's limits, and PHP silently drops all form fields
of a request over `post_max_size`, which shows up as a 403.

### Uploading by hand (curl)

Keep the token out of the command line: put the header in a file only you can read.

```bash
( umask 077; printf 'Authorization: Bearer %s\n' "$(cat /path/to/token.txt)" > /tmp/auth.txt )
U=http://localhost:8000/upload.php
curl -X POST "$U" -H @/tmp/auth.txt -F site_id=SITE_ID -F microscope_id=MIC_ID \
  -F source=acq -F "data=@upload.zip;type=application/zip"
# -> {"status":"ok","files":["recipe.yml","status.json", ...]}
rm /tmp/auth.txt
```

| Request | Reply |
|---|---|
| GET instead of POST | 405 |
| no or malformed `Authorization: Bearer` header | 401 |
| unknown site, unlisted microscope, missing `microscope_id`, or wrong token (including an old per-microscope token) | 403 `unknown site_id, microscope_id or token` (the same for all, so the endpoint reveals no IDs; `logs/upload.log` says which) |
| `source` missing or not `acq` / `analysis` (checked after the token) | 400 |
| same site, microscope and source again within `min_upload_interval_seconds` (5 s) | 429 |
| no `data` file field | 400 |
| `recipe.yml` or `status.json` missing; `status.json` not an object with a boolean `finished`; `SYSTEM.ID` in the recipe not equal to `microscope_id` once normalised; no sample ID in the recipe, or one that is not valid UTF-8; two entries with the same base name | 400 with the reason |
| zip too large / too many entries / too large unpacked / `recipe.yml` or `status.json` over 1 MB | 413 |
| not a `.zip` / not a valid zip | 415 |

### Automated checks

From the repo root (`node` 18+ and `php` needed):

```bash
node --test tests/web/          # JS logic, control flow, PHP/JS ago-format parity
tests/web/check_pages.sh        # the server on a temp copy with random settings; optional port argument
tests/web/check_stage.sh        # stage_server.sh: only committed files, refusals, deploy keeps data
```

`check_pages.sh` copies `brainsaw/` (tracked and new files only) into a temp folder, writes a
settings file with random words, IDs and tokens (two sites with one token each, microscopes
including one named `logs`, a panopticon word), serves it with `php -S ... router.php` under a sub-folder, and
checks the views, the identical 404s (status, headers and body, GET and HEAD), the asset
route, direct-access refusals, the URL base, uploads, logging, rate limits, settings
validation, headers and the auto-refresh wiring. It also covers the display rule (§5): acq
alone, acq with matching and with non-matching analysis, analysis alone, the finished flag
(including that analysis never sets or clears it), staleness, an `acq/` whose `meta.json` is
missing or corrupt, and which assets are served. It covers the StitchIt lag rule too: lag 3, lag
exactly 2, equal logs, an analysis log with no finished section, a missing acq log, the
card and strip thumbnails in both layouts, and the layout flipping back and forth.

## 5. What gets uploaded

A zip from BakingTray (source `acq`) or StitchIt (source `analysis`), fields `site_id`, `microscope_id`,
`source` (`acq` or `analysis`) and `data`, with the **site's** token. Each source has its own
folder, `system_data/<site_id>/<microscope_id>/<source>/`.

The server extracts the zip into a temporary folder, keeping only these exact base file names
(flattened; everything else, such as a stray `.php` or `.htaccess`, is dropped):
`LastCompleteSection.jpg`, `tile_thumbnail.jpg`, `montage.jpg`, `montage_thumbnail.jpg`, `recipe.yml`, `acqLog.txt`, `status.json`.
`montage_thumbnail.jpg` is the same for the montage: the page shows it in the strip, and clicking it opens
the full montage over the page (cross top-left, Esc or a click outside closes it).
`tile_thumbnail.jpg` is an optional small copy of the section image, made by the client, which
the cards show instead of the full image (an upload with a new section image but no thumbnail
removes the old thumbnail, so a card never shows an older section).
Then it checks, before the live folder is touched:

- `recipe.yml` and `status.json` are present;
- `status.json` is a JSON object whose `finished` is a boolean (other keys are ignored);
- `SYSTEM.ID` in the recipe, read by the rule in section 10 (the micID), equals `microscope_id`;
- the recipe has a non-empty `sample.ID` (read by the same rule, without the space replacement)
  in valid UTF-8.

A refused upload (400) leaves the stored data exactly as it was. An accepted one is moved into
the source folder and `meta.json` is written there with `uploaded_at` and `sample_id`. If the
sample ID differs from the stored one (or none is stored) the source folder is emptied first;
the same sample merges, so files not in the upload stay. `logs/upload.log` records
`site/microscope/source`. The two sources do not rate-limit each other, and neither empties the
other, with one exception:

**Start of a run.** An upload with no image, that is neither `LastCompleteSection.jpg` nor
`montage.jpg`, whose `status.json` says `finished: false` is the client's start-of-run call (it
has cleared its stage and sends nothing to show). An upload with a montage but no section image
is not a start call: it is a mid-run analysis result, and wiping would delete `analysis/`'s
section image, so it merges as any upload does. What a start call empties depends on the sender:

- `acq` start call: `acq/` and `analysis/` are both emptied (every file, `meta.json` included),
  and `analysis/` is removed. The upload is then installed into `acq/`.
- `analysis` start call: `analysis/` is always emptied. `acq/` is emptied and removed only when
  its stored sample ID (`acq/meta.json`) differs from the sample ID in the uploaded recipe, or
  when it has no readable sample ID (then it is an orphan of another sample). When the sample
  IDs are equal `acq/` is left completely untouched, because analysis starts some minutes after
  acq and must not blank acq's images. The upload is then installed into `analysis/`.

So the previous acquisition's images, thumbnails and montage vanish even when the sample ID is
unchanged. A folder that belongs to the other source is removed (not just emptied), so the
display rule falls back to what remains (no `acq/` means `analysis/` alone); the sender's own
folder is kept, and the other source's data returns with its next upload. Known gap: an orphan
`acq/` with the SAME sample ID as an analysis start call is not cleared by it, only by an `acq`
start call.

The `finished: false` condition is deliberate: an end-of-run call (`finished: true`) without an
image must not delete the final images. Validation and the rate limit come first, so a refused
(400) or rate-limited (429) call empties nothing. Both sources' locks are held meanwhile (`acq`,
then `analysis`). Before deleting anything the server checks that every folder to empty is
writable, and that a folder to be removed is a real directory (not a symlink) with no
sub-folders; the sender's own folder is only emptied, so sub-folders in it just stay. If the
check fails the answer is 500 (logging the folder) and nothing has changed, so the source
folders must be real directories. This is a best-effort pre-check: if a delete still fails
part-way, the microscope can be left half wiped (the sender's data possibly gone, the upload not
installed, a 500 returned); the next upload repairs it.

### Which sources a view shows

- The `acq/` folder exists: it is the ground truth for the image, recipe table, log chart,
  status and freshness, whatever it holds. A new sample deletes `acq/meta.json` before the
  files are replaced, and a failed first install can leave `acq/` empty; a missing
  `meta.json` or an empty folder therefore still counts as `acq/` (nothing is shown from it,
  and `analysis/` stays hidden until an `acq` upload succeeds). A `meta.json` that exists but
  cannot be read is logged on every request until the next upload, and also leaves `analysis/`
  hidden. `analysis/` is shown in addition only if both folders store the same non-empty
  `sample_id`; otherwise it is hidden, and so are its files.
- No `acq/` folder: `analysis/`, once it holds an upload (`meta.json` with `uploaded_at`), is
  shown alone as the ground truth (a BakingTray that is not upgraded).
- The card and the page's main image show the StitchIt (`analysis/`) image when `analysis/` is shown,
  because it looks better, and the BakingTray image otherwise (acq alone). When StitchIt lags (below)
  they switch to the BakingTray image. If the preferred source has no image, the other source's image
  is used; a card with no image from either shows a placeholder.
- **StitchIt lag.** StitchIt can crash, leaving `analysis/` behind `acq/`. Lag is the largest finished
  section number in `acq/acqLog.txt` minus the largest in `analysis/acqLog.txt` (the copy of the log
  that StitchIt uploads each time; it freezes when StitchIt crashes). More than 2 sections
  (`BS_STITCHIT_LAG_SECTIONS` in `lib.php`; exactly 2 is not lagging) counts as lagging. If either log
  has no finished section the lag is unknown and counts as not lagging. The analysis log is the
  analysis PC's synced copy and can be slightly ahead of the section StitchIt has actually stitched,
  so the measured lag can be a little smaller than the true lag. Lag changes only which image is
  main and what the strip shows; the finished flag, freshness, recipe table and chart stay acq's.

Files are found by their fixed names:

| File | Source | Used for |
|---|---|---|
| `LastCompleteSection.jpg` | `acq/` | the BakingTray image: the main image and card thumbnail when there is no StitchIt image or StitchIt lags, otherwise a strip thumbnail |
| `LastCompleteSection.jpg` | `analysis/` | the StitchIt image: the main image and card thumbnail (unless StitchIt lags, then a strip thumbnail) |
| `montage.jpg` | `analysis/` | the montage thumbnail. A `montage.jpg` in `acq/` is stored but not shown |
| `recipe.yml` | ground truth | sample, laser power, voxel size, ... |
| `acqLog.txt` | ground truth | timing chart, progress, ETA estimate |
| `acqLog.txt` | `analysis/` | read only for the lag check (its latest finished section, against `acq/`'s) |
| `status.json` | ground truth | finished flag |

**Finished.** Finished is the `finished` of the ground truth's `status.json` alone: `acq/`, or
`analysis/` when it is shown alone. A hidden or additional `analysis/` upload never sets or
clears it, so a StitchIt upload after BakingTray's end upload changes the images but leaves the
state finished; only a new `acq` upload with `finished` false (a resume) clears it. When it is
finished the card and the page say "finished", the card is not drawn stale (staleness is the
ground truth's age) and the page shows no estimated completion.

## 6. Adding and removing sites and microscopes

1. Pick IDs (§2): an unguessable site ID (it is that lab's view URL), e.g.
   `s$(openssl rand -hex 8)`, and a short microscope ID.
2. Generate one token per site with `openssl rand -hex 32`. Never reuse a token.
3. Add the entries to the settings file (§2). No restart needed. A new microscope of an existing
   site needs only a new entry under `microscopes`. Its ID must equal the recipe's `SYSTEM.ID`
   with spaces replaced by `_`.
4. Send the lab their view URL `<base>/<SITE_ID>`, and the `siteID` and site token for the MATLAB
   config, by a private channel.

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
| `min_upload_interval_seconds` | 5 | rate limit per site, microscope and source |
| `stale_after_seconds` | 900 | a card or status turns red past this age |

## 8. The microscope page

- **Main image + magnifier**: the StitchIt image when a matching `analysis/` is shown, else the
  BakingTray image (also when StitchIt lags, §5). It has a hover lens.
- **Thumbnails** (only when a matching `analysis/` is shown): below the main image, the image
  that is not the main one (BakingTray normally, StitchIt when it lags) and the StitchIt montage.
  Clicking one opens it full size over the page (cross top-left, Esc or a click outside closes it).
- **Status line**: "Finished" when the acquisition is finished, then "Last updated X ago"
  (of the ground-truth source), and the section being acquired.
- **Metadata table**: parsed from the recipe by `bs_parse_recipe()` (targeted regexes, no YAML
  extension needed; extend the list there for new fields).
- **Estimated completion**: mean section duration so far × sections remaining, labelled
  "(estimated)". The server sends it as a UTC instant (`<time datetime=...Z>`) and a small
  inline script shows it in the viewer's own time zone ("Fri 9 Oct, 15:03 BST"); without
  JavaScript the page keeps the UTC text. "Acquisition started" is shown as the recipe
  records it: the microscope's clock, with no time zone, so it cannot be converted.
- **Acquisition-time chart**: inline SVG (no JS library) of minutes per section from
  `acqLog.txt`; the dashed line is the mean.

A card shows the main image (its `tile_thumbnail.jpg` when sent), the sample,
"finished" when it is, and how long ago the ground truth was uploaded. It turns red past
`stale_after_seconds` unless the acquisition is finished.

### Auto-refresh and "last updated"

`bs_watch_attrs()` puts `data-meta-url` (the microscope's `?f=meta` URL), `data-version` (every
shown source and its `uploaded_at`, so an upload to either source or a change in which sources
are shown changes it), `data-uploaded-at` (the ground truth's, for "ago" and stale),
`data-finished` and `data-stale-after` on each card and on the microscope page's status line;
`<body data-server-now>` carries the server clock. `js/autorefresh.js`, inlined into every view
page:

- polls those meta URLs every 5 s (each fetch aborted after 4 s) and reloads when any
  `version` changed. A 404 (a microscope that has never uploaded) is silent; other failures
  log one console warning per URL and kind. A per-URL `sessionStorage` guard stops reload loops.
- recomputes the "X ago" text and the stale styling every 5 s against the server clock; a
  finished acquisition is never styled stale.
- pauses while the tab is hidden and polls at once when it is shown again.

If `js/autorefresh.js` is missing the page falls back to a 60 s meta refresh; with JavaScript
off a `<noscript>` 60 s refresh is used. A microscope added to the settings file appears on a
grid only after a manual reload.

## 9. Not built yet

- No dedicated estimate file (ETA, laser power / depth / averaging per section).
- No login: access is by unguessable URL only. Anyone given a view URL can pass it on.
- No history: only the latest snapshot per microscope is kept; a new zip overwrites same-named
  files.

## 10. The shared contract with the client

`tests/web/upload_contract.json` holds what the server and the MATLAB client must agree on: the
recipe ID rule (its `rule` text) with its test cases, the seven file names, the zip size limit
and the minimum upload interval. The server owns it. The client keeps a copy in its tests folder
(in the StitchIt repository).

`tests/web/check_pages.sh` checks that `lib.php` and `config.php` match the contract, and that
the contract is still the version recorded in `tests/web/upload_contract.sha256`. The client's
`ContractPinTest` checks its copy against the hash pinned in that test.

To change the contract:

1. Edit `tests/web/upload_contract.json`, and the server code and `config.php` to match.
2. Copy it over the client's copy.
3. Update the pinned hash in the client's `ContractPinTest.m`, and the record here:
   `(cd tests/web && shasum -a 256 upload_contract.json > upload_contract.sha256)`.
4. Run `tests/web/check_pages.sh` and the client's suite. Both must pass.
