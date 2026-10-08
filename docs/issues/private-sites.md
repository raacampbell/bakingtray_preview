---
type: infrastructure
complexity: complex
status: in review
---

# Sites with microscopes, private site views and a hidden all-sites view

Brainsaw will serve several labs ("sites"), each with one or more microscopes. Requirements from the PI:
- `<base>/<PANOPTICON_WORD>` shows every microscope of every site.
- `<base>/<site_ID>` shows only that site's microscopes.
- Neither may be discoverable: no view name in the code, the repo, .htaccess or any publicly fetchable file;
  probing gives no oracle (an unknown word is indistinguishable from any other missing page).
- The landing page lists nothing (later it becomes a public info page).
`<base>` is wherever brainsaw/ is deployed (today https://brainsaw.org/testserver; locally http://localhost:8000).

## Data model and upload
- One private settings file replaces tokens.json; path from config.php key `settings_file` (rename from
  `tokens_file`); it lives OUTSIDE the web root on the server. Format:
  {"panopticon": "PANOPTICON_WORD",
   "sites": {"<site_ID>": {"display_name": "...",
             "microscopes": {"<mic_ID>": {"display_name": "...", "token": "..."}}}}}
  IDs and the panopticon word: [A-Za-z0-9_-]+. Validate on load: the panopticon word must not equal a site_ID,
  and neither may equal a top-level name in brainsaw/ (derive the list from the directory, case-insensitively,
  so new files are covered automatically). An invalid file is error_logged and treated as empty (pages 404,
  uploads 403) — never echo details to the client.
- Upload requires `site_id` AND `microscope_id`; token checked per microscope with hash_equals. Unknown site,
  unknown microscope and wrong token keep today's status codes but the same message for unknown site/mic so
  nothing reveals which exists. Rate limit per microscope. Data in system_data/<site>/<mic>/ (meta.json there).
- Delete the legacy single-image upload mode, brainsaw/clients/ (old scripts without microscope_id; MATLAB
  is the client now) and brainsaw/test-upload/ (replaced by the /testserver deployment).
- lib.php also reads REDIRECT_HTTP_AUTHORIZATION (an Authorization header copied by a rewrite can arrive under
  that name).

## Views
- .htaccess (and router.php for `php -S`, mirroring it exactly): after the HTTPS redirect, any request path of 1-3
  segments of [A-Za-z0-9_-] that is not an existing file or folder goes to one PHP entry point (e.g. view.php).
  - `/<word>`: card grid. For the panopticon: all microscopes grouped by site. For a site: its microscopes.
  - `/<word>/<mic>` (site view) or `/<word>/<site>/<mic>` (panopticon): the microscope page (today's site page
    content: image + magnifier, montage link, chart, metadata, auto-refresh).
  - Anything else, including an unknown word, a known word with an unknown or other-site microscope: the same 404
    response as for any missing page (same status, same body; check it matches what the entry point returns for a
    random word).
- system_data/ is entirely denied to direct requests (.htaccess and router.php). Images and meta.json are served
  by PHP via the view word, e.g. `<base>/<word>/...` asset route or a file.php?w=&s=&m=&f=main|montage|meta,
  which re-checks that the word grants access to that site/microscope; only those three files are servable
  (never recipe/log). Correct Content-Type, Cache-Control: no-store for meta.
- Auto-refresh (brainsaw/js/autorefresh.js) keeps working: the PHP emits the new meta URL in data-meta-url; the
  JS must need no change other than what tests prove necessary.
- Pages work at nested paths: asset URLs must be built from the deployment base (e.g. from SCRIPT_NAME), not
  relative to the request path.
- Leak plugging on every view response: `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex, nofollow`, a
  robots noindex meta; self-host jQuery (download jquery-3.7.1.min.js with its licence header into brainsaw/js/;
  no third-party request from any page).
- index.php: a plain neutral "Brainsaw" page listing nothing. Remove site.php.

## Deployment scripts (fixes from a review of stage_server.sh / check_deployed.sh)
- stage_server.sh: stage ONLY git-tracked files under brainsaw/ (git ls-files / git archive), so an untracked or
  ignored secret can never be staged; --dest accepts only [A-Za-z0-9_-]+; rename --tokens-path to
  --settings-path and require it unless --dest is testserver; replace the python3 substitution with sed or perl;
  keep the safety checks (adapt the tokens_file-line checks to settings_file); print a per-destination deploy
  command `staging/<dest>/ -> public/<dest>/` using rsync --delete with protect filters for server-side data
  (system_data/*/ and logs/*.log) so removed endpoints disappear from the server and uploaded data survives.
  Add tests/web/check_stage.sh: plants an untracked .env, a swap file with a 64-hex string, an extra log and a
  settings file in a temp copy and asserts none is staged; asserts --dest ./ and --dest ../x are refused.
- tests/web/check_deployed.sh: require an https base; send the token via `-H @file` or a curl config file (never
  on the command line); fail if the token file is missing/empty; site_ID, mic_ID and the zip as arguments;
  include microscope_id in uploads; fail if the zip lacks a recipe or acqLog; compare against "403 or 404"
  explicitly instead of the sed hack; checks updated for the new layout (system_data direct access denied
  including meta.json; the site view page and a microscope page render with the image served through PHP;
  an unknown word returns the same 404 as a random path). The panopticon word is NOT an argument (keep it out of
  shell history); document how to check it by hand.
- brainsaw/.htaccess: fix the comment (lib.php reads $_SERVER first); wrap the HTTPS block in the same IfModule
  style; keep the Authorization rule first and without [L].

## MATLAB (small, from the same review)
- postZip>buildMultipart: boundary from java.util.UUID (do not touch the global RNG); PostZipTest asserts there is
  no `Transfer-Encoding: chunked` header as well as a Content-Length.
- Simulator: its safety marker becomes `testserver` (localhost still allowed); update tests and README.

## Docs
- instructions.md and server-setup.md describe the new settings file, upload fields, view URLs (with placeholders),
  staging and deploy; server-setup.md written as instructions, not history (drop DONE/strike-through and
  "first guess was wrong" narrative; keep a short verified/unverified list). State that the PI must confirm in
  the IONOS panel that /home/www/www is not any domain's document root before relying on it as private storage.
- BakingTray READMEs: only what changes (marker, server now checks micID).

## Acceptance criteria
- tests/web/check_pages.sh rewritten for the new model, run against `php -S ... router.php` on a temp copy with a temp
  settings file (two sites, two microscopes in one, a panopticon word): panopticon shows all; site view shows only
  its own; cross-site microscope via a site word 404s; unknown word, unknown mic and a random path give identical
  404 responses (status + body); system_data direct access denied (incl. meta.json); asset route serves main,
  montage, meta and refuses recipe/log; upload without microscope_id fails, wrong-mic token fails, per-mic rate
  limit, data lands in system_data/<site>/<mic>/; collisions in the settings file are rejected; every view response
  has the no-referrer and noindex headers and no third-party URL in the HTML; landing page lists nothing; php -l clean.
- grep proves no view word, site_ID or token from the test settings appears in any tracked file.
- node --test tests/web/, tests/web/check_stage.sh, and the MATLAB suite (both folders) pass; MATLAB dry run runs.
- A real local end-to-end: start php -S with a temp settings file, run the simulator (DryRun false) against it
  for 2 sections with a site/mic in that file, and confirm with curl that the microscope page shows section 2.

## Review record
First review: 20 findings (security and style), all fixed. The real local end-to-end was then
re-run and passed (3 sections; site, panopticon and microscope pages, assets, identical 404s).
webConfig now requires IDs to start with a letter, as the server does.

Second review (fix round): fixed tokens.json is git-ignored again (stray token files in the
main checkout were exposed); no -ExecCGI in brainsaw/.htaccess (it could 403 every page under
php-cgi); simulator safety check rejects /../ and its message says "path segment"; router.php
allows the entry points only at the app root; settings replaced by copy-then-mv. Accepted, not
fixed (low): two simultaneous uploads from one microscope can race on meta.json.tmp (500 for
an upload whose files landed); stage_server.sh compares --settings-path as a string, so
"/../" can slip past its web-root guard; in Apache a file named view.php inside system_data/
would be served (nothing can put one there: the zip whitelist blocks .php).

One-off migration steps for the PI (first deploy of this version to /testserver):
- Commit first: stage_server.sh now refuses uncommitted changes under brainsaw/.
- Delete the old flat data folder public/testserver/system_data/test_site/. The rsync protect
  filter keeps it, but nothing reads it any more.
- Delete /home/www/www/brainsaw_private/tokens.json. Create brainsaw_settings.json there as in
  server-setup.md section 4. IDs and words must start with a letter.
- Delete the local brainsaw/tokens.json and brainsaw/test-upload/tokens.json in the main
  checkout; nothing reads them any more.
- Check in the IONOS panel that no domain serves /home/www/www.
