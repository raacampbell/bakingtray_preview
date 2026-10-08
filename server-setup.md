# Server setup: deploying Brainsaw to IONOS (test deployment at brainsaw.org/testserver)

Step-by-step for putting `brainsaw/` on the IONOS Web Hosting plan behind brainsaw.org, as the
test deployment at `https://brainsaw.org/testserver/` and later at the real address. What the
server does is in `instructions.md`; this file is only about getting it running on IONOS.

## What you are building

```
https://brainsaw.org/testserver/                  neutral landing page, lists nothing
https://brainsaw.org/testserver/upload.php        the url in each microscope's MATLAB config
https://brainsaw.org/testserver/<SITE_ID>         one lab's microscopes (private: the ID is the secret)
https://brainsaw.org/testserver/<PANOPTICON_WORD> every microscope of every site (private)
```

On the server:

```
/home/www/public/                  web root of brainsaw.org (what https://brainsaw.org/ shows)
/home/www/public/testserver/       the staged app (staging/testserver/ from your computer)
/home/www/www/brainsaw_private/    the settings file, outside the web root
```

## Known facts about this host

From a diagnostic run on 8 Oct 2026 (§2): PHP 8.4 under SAPI `cgi-fcgi`; `ZipArchive` present;
`post_max_size` 1024M and `upload_max_filesize` 128M; no `open_basedir`; the web root is
`/home/www/public` and `/home/www` is readable by PHP. Under FastCGI Apache drops the
`Authorization` header; the rewrite rule at the top of `brainsaw/.htaccess` restores it (§9).

**Confirm before relying on `/home/www/www/` as private storage:** in the IONOS control panel,
check every domain and subdomain of the contract (Domains & SSL, then each domain's target
folder) and make sure none points at `/home/www/www` or a folder inside it. If one does, the
settings file there would be downloadable by anyone: pick a folder that no domain serves and
stage with that path (`--settings-path`).

---

## 1. Prepare the domain

1. The `public` folder you see over SFTP must be the web root of brainsaw.org.
2. HTTPS must work for brainsaw.org (an SSL certificate assigned to the domain in the panel).
3. PHP 8.1 or later selected for the domain (8.4 is in use).

## 2. Diagnostic (only when the plan or PHP version changes)

Answers, with facts: is `ZipArchive` there, what are the upload limits, does the
`Authorization` header reach PHP, and what is the file-system path above the web root.

Create `diag.php` on your computer. **Replace `CHANGE-ME-random-string` with a random string**
(e.g. from `openssl rand -hex 8`) so strangers cannot read the page while it is up:

```php
<?php
// TEMPORARY DIAGNOSTIC. Delete this file as soon as you have the answers.
if (($_GET['k'] ?? '') !== 'CHANGE-ME-random-string') { http_response_code(404); exit; }
header('Content-Type: text/plain');

echo "PHP version:        ", PHP_VERSION, "\n";
echo "SAPI:               ", php_sapi_name(), "\n";
echo "ZipArchive:         ", class_exists('ZipArchive') ? 'yes' : 'NO  <-- uploads will fail', "\n";
echo "post_max_size:      ", ini_get('post_max_size'), "\n";
echo "upload_max_filesize:", ini_get('upload_max_filesize'), "\n";
echo "open_basedir:       ", ini_get('open_basedir') ?: '(none)', "\n";
echo "This folder:        ", __DIR__, "\n";
echo "DOCUMENT_ROOT:      ", $_SERVER['DOCUMENT_ROOT'] ?? '?', "\n";
echo "Folder above it:    ", dirname($_SERVER['DOCUMENT_ROOT'] ?? __DIR__), "\n";
echo "  readable:         ", is_readable(dirname($_SERVER['DOCUMENT_ROOT'] ?? __DIR__)) ? 'yes' : 'no', "\n";
echo "This folder writable:", is_writable(__DIR__) ? 'yes' : 'no', "\n";

// Never print the header value: only whether it arrived.
$h = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
$r = $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '';
echo "HTTP_AUTHORIZATION:          ", $h !== '' ? "present (length ".strlen($h).")" : 'absent', "\n";
echo "REDIRECT_HTTP_AUTHORIZATION: ", $r !== '' ? "present (length ".strlen($r).")" : 'absent', "\n";
if (function_exists('apache_request_headers')) {
    $found = false;
    foreach (apache_request_headers() as $k => $v) { if (strtolower($k) === 'authorization') $found = true; }
    echo "apache_request_headers():    ", $found ? 'Authorization present' : 'Authorization absent', "\n";
}
```

1. Upload it to `public/testserver/diag.php`.
2. From a terminal: `curl -s -H "Authorization: Bearer test123" "https://brainsaw.org/testserver/diag.php?k=<your string>"`
3. Needed: `ZipArchive: yes`; both size limits at least ~32M (§6); at least one of the three
   Authorization lines `present` (lib.php reads all three); `Folder above it` readable.
4. **Delete `diag.php` from the server** as soon as you have the answers.

---

## 3. Build the staged copy

From the project root (`brainsaw_web_preview/`):

```bash
./stage_server.sh
```

This fills `staging/testserver/` with `brainsaw/` **as committed in HEAD** (`git archive`), so
an untracked or ignored file, such as a local settings file, log, upload or editor swap file,
can never be staged. It refuses to run while a tracked file under `brainsaw/` has uncommitted
changes: commit first. It leaves out the local-only `router.php`, points the staged
`config.php` at `/home/www/www/brainsaw_private/brainsaw_settings.json` (refusing any settings
path inside the web root, `--webroot`, default `/home/www/public`), and runs safety checks (no
settings, token or log file, no dotfile or symlink, no token-like string, the `.htaccess`
rules present, PHP syntax). `staging/` mirrors the server's `public/` folder and is
git-ignored. Re-run it after every committed change in `brainsaw/`.

## 4. The settings file: generate locally, keep outside the web root

Generate it in a private folder **outside the repo and outside Dropbox**, never in the project:

```bash
PRIV="$HOME/brainsaw_private_local"
mkdir -p "$PRIV" && chmod 700 "$PRIV"
(
umask 077                             # in a subshell, so your shell's umask is unchanged
TOKEN="$(openssl rand -hex 32)"
SITE="s$(openssl rand -hex 8)"        # unguessable: this ID is the lab's view URL
PAN="p$(openssl rand -hex 8)"         # the panopticon word (IDs and words start with a letter)
printf '%s\n' "$TOKEN" > "$PRIV/test_mic_token.txt"
cat > "$PRIV/brainsaw_settings.json" <<EOF
{"panopticon": "$PAN",
 "sites": {"$SITE": {"display_name": "Test site",
   "microscopes": {"test_mic": {"display_name": "Test microscope", "token": "$TOKEN"}}}}}
EOF
cat > "$PRIV/brainsaw_webpreview_test.json" <<EOF
{"url": "https://brainsaw.org/testserver/upload.php", "siteID": "$SITE", "micID": "test_mic", "token": "$TOKEN"}
EOF
printf 'site view:  https://brainsaw.org/testserver/%s\npanopticon: https://brainsaw.org/testserver/%s\n' "$SITE" "$PAN" > "$PRIV/view_urls.txt"
)
```

The subshell also means `TOKEN`, `SITE` and `PAN` vanish when it ends. Keep the token and the
two view URLs in your password manager too. Add sites and microscopes later by editing the
**server's** copy (format: `instructions.md` §2); it is re-read on every request. Check a
hand-edited file before uploading it with the `bs_validate_settings` one-liner in
`instructions.md` §2.

Put it on the server (only this one file goes there):

```bash
ssh USER@HOST 'mkdir -p /home/www/www/brainsaw_private && chmod 700 /home/www/www/brainsaw_private'
scp "$PRIV/brainsaw_settings.json" USER@HOST:/home/www/www/brainsaw_private/brainsaw_settings.json.new
ssh USER@HOST 'cd /home/www/www/brainsaw_private && chmod 600 brainsaw_settings.json.new && mv brainsaw_settings.json.new brainsaw_settings.json'
```

`USER@HOST` is the SFTP/SSH login from the IONOS panel. With an SFTP program instead, create
the folder and upload the file to the same absolute path.

## 5. Upload the app

`stage_server.sh` prints the exact commands for the folder it staged. For the test deployment:

```bash
rsync -azn --delete --chmod=D755,F644 --filter='P /system_data/*/' --filter='P /logs/*.log' -e ssh staging/testserver/ USER@HOST:/home/www/public/testserver/
rsync -az  --delete --chmod=D755,F644 --filter='P /system_data/*/' --filter='P /logs/*.log' -e ssh staging/testserver/ USER@HOST:/home/www/public/testserver/
```

The first is a dry run (`-n`): read its list before running the second.

- `--delete` removes server files that are no longer part of the app, so retired endpoints
  disappear. The two protect filters (`P`) keep what the server itself writes: uploaded data in
  `system_data/<site>/` and `logs/*.log`. (`tests/web/check_stage.sh` checks this on a local copy.)
- This replaces any hand-made `.htaccess` with the staged one. That is intended.

**Without SSH** (SFTP program only): upload the contents of `staging/testserver/` into
`public/testserver/`, then delete by hand every file and folder there that is not in
`staging/testserver/`, except `system_data/<site>/` folders and `logs/*.log`.

Permissions: directories 755 and files 644, set by `--chmod` on **every** deploy, so a mode
changed by hand on the server does not survive the next deploy. `system_data/` and `logs/` must
be writable by PHP, which runs as your account under FastCGI, so 755 is enough. If uploads fail
with 500 and the log says it cannot write, that is a host problem to raise with IONOS, not
something to fix by hand.

## 6. PHP limits

This host's limits (1024M / 128M) are plenty: preview zips are a few MB. On a host with low
limits a too-large upload fails confusingly (PHP drops all form fields, giving a 403 instead of
a clean 413): raise `post_max_size` and `upload_max_filesize` (IONOS's documented method is a
`php.ini` in the app folder; a file put there by hand is deleted by the next `--delete` deploy,
so it would have to be committed in `brainsaw/`), or lower `max_zip_size` in `config.php` to
match.

## 7. Test the deployment

### 7.1 The check script

From the repo root, once §4 and §5 are done:

```bash
PRIV="$HOME/brainsaw_private_local"
SITE="$(php -r 'echo json_decode(file_get_contents($argv[1]))->siteID;' "$PRIV/brainsaw_webpreview_test.json")"
tests/web/check_deployed.sh https://brainsaw.org/testserver "$PRIV/test_mic_token.txt" "$SITE" test_mic test_images/all_data.zip
```

Add `--big` to also upload a 30 MB zip (checks the PHP size limits). The token is read from the
file into a private temp header file that curl loads (`-H @file`), so it never appears on a
command line or in output. The script refuses a non-https base, a missing or empty token file,
and a zip without a recipe and an acquisition log. It waits 6 s between uploads (one upload
per microscope every 5 s), ends with `N passed, M failed` and exits non-zero on any failure.

It checks: http redirects to https; upload GET 405, no token 401, wrong token, missing
`microscope_id`, unknown site and unknown microscope all 403 (unknown site and microscope with
the same reply); a real zip upload succeeds; the settings file, `upload.log`, `lib.php`,
`router.php`, the `system_data/` listing and the raw `meta.json`, recipe, acquisition log and
image are all 403 or 404, and the site's `system_data/` folder answers like a made-up one; the
landing page does not name the site; the site view links the microscope and sends
`Referrer-Policy` and `X-Robots-Tag`; the microscope page shows the image, served through PHP
as `image/jpeg`; `?f=meta` works and `?f=recipe` is 404; an unknown word, a random path and the
site view with a trailing slash all give the same 404. The site ID never appears in the output.

"valid zip upload" passing means the `Authorization` header reaches PHP. If it fails with 401,
see §9.

### 7.2 The panopticon, by hand

The panopticon word is deliberately not a script argument, so it never lands in shell history.
Copy the URL from `$PRIV/view_urls.txt` into a private browser window:

- it shows a heading per site with a card for every microscope;
- with one letter of the word changed, the page is the same "Not found" page as for any
  made-up path such as `https://brainsaw.org/testserver/no/such/page`.

### 7.3 In a browser

- The site view and a microscope page: image, hover magnifier, montage link, metadata table,
  acquisition-time chart.
- Leave the microscope page open and upload again (> 5 s later): it should refresh itself
  within about 5 s.
- The browser's developer tools (Network tab) should show no request to any other host.

## 8. Test from MATLAB (the real client)

```bash
cp "$PRIV/brainsaw_webpreview_test.json" ~/.brainsaw_webpreview_test.json
chmod 600 ~/.brainsaw_webpreview_test.json
```

```matlab
addpath('<repo>/upload_core', '<repo>/BakingTray')    % the folders CONTAINING +webupload and +BakingTray
cfg = webupload.webConfig(fullfile(getenv('HOME'),'.brainsaw_webpreview_test.json'));
img = imread('<repo>/test_images/LastCompleteSection_01.jpg');
res = BakingTray.webpreview.updateSectionImage(img, ...
    '<repo>/test_images/recipe_SW_FG12_3_FG_12_2_191209_120354.yml', ...
    '<repo>/test_images/acqLog_SW_FG12_3_FG_12_2.txt', cfg);
disp(res.ok), disp(res.post)
```

Expect `res.ok` true and `res.post.httpStatus` 200. Use the exact `https` URL: the client treats
a redirect as a failure. For a simulated acquisition against the test deployment see
`BakingTray/simulate/README.md` (its safety rule accepts URLs with `testserver` as a path segment).

## 9. Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| **500 on every page** | A directive in `.htaccess` is not allowed by the host. Rename `.htaccess` (top level and in `system_data/`, `logs/`) to `.htaccess.off`, reload to confirm, then find the offending line. Re-run §7 afterwards: without these files `system_data/` would be served directly. |
| **401** with a correct token | PHP does not receive the `Authorization` header. The deployed `.htaccess` must start with the `RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]` block. `lib.php` reads `HTTP_AUTHORIZATION`, `REDIRECT_HTTP_AUTHORIZATION` and `apache_request_headers()`; the §2 diagnostic shows which arrives. If none does, try `SetEnvIf Authorization "(.+)" HTTP_AUTHORIZATION=$1`, then ask IONOS support. |
| **Every view is "Not found"** and every upload 403 | The app cannot use the settings file: missing at the configured path, unreadable by PHP, not valid JSON, or rejected by validation (e.g. the panopticon word equals a site ID or a file name in the app). The PHP error log says which (`brainsaw: invalid settings file: ...`); IONOS shows it in the panel's logs. Check that the uploaded `config.php` is the staged one (`settings_file` is the server path). |
| **A view URL is "Not found"** but others work | The word is not in the settings file exactly as typed (case matters), or a microscope page was opened through another site's word. |
| **403 for every upload from MATLAB, curl works** | PHP (FastCGI) loses every form field when a request has no `Content-Length` (chunked). `postZip` builds the body in memory so MATLAB sends a length; `PostZipTest` checks that the request is not chunked. `logs/upload.log` says `missing/invalid site_id or microscope_id` when the fields did not arrive. |
| **403 on large uploads only** | The body exceeded `post_max_size`; see §6. |
| **429** | Two uploads for one microscope within 5 s. |
| **Pages load but no magnifier** | `js/jquery-3.7.1.min.js` or `js/jquery.imageLens.js` missing on the server; re-deploy. |
| **Redirect error from MATLAB** | The configured `url` is not the final address (http vs https, `www` vs bare domain). |

## 10. Security checklist

- [ ] `diag.php` (and any other scratch PHP file) is gone from the server.
- [ ] No domain or subdomain serves `/home/www/www` or a folder inside it (see "Known facts").
- [ ] Only the settings file is in `/home/www/www/brainsaw_private/` (mode 600, folder 700).
- [ ] `PRIV` is outside the repo and Dropbox; tokens and view URLs are in your password manager.
- [ ] Site IDs and the panopticon word are random, and none appears in the repo, an issue or a chat.
- [ ] `tests/web/check_deployed.sh` finished with 0 failed, and §7.2 behaved as described.
- [ ] `http://` redirects to `https://`.

## 11. Going from the test to the real deployment

1. Make a new settings file with **new** tokens, site IDs and panopticon word (§4); do not
   reuse the test ones. Upload it next to the test one, e.g. as
   `/home/www/www/brainsaw_private/brainsaw_settings_live.json`.
2. Stage for the real folder, e.g. `public/brainsaw/`:
   `./stage_server.sh --dest brainsaw --settings-path /home/www/www/brainsaw_private/brainsaw_settings_live.json`
   (`--settings-path` is required for any destination other than `testserver`). Deploy with the
   commands it prints. Serving from the web root itself would need a small change to the script.
3. Give each lab its view URL and each microscope its config (`siteID`, `micID`, token, the
   real `url`). Test each microscope against the test deployment first, and keep `/testserver`
   as a standing canary.

## 12. What has and has not been verified

**Verified on this host (8 Oct 2026, previous version of the app):** the §2 diagnostic facts
above; with the `.htaccess` rewrite rule a real zip upload authenticates; the `.htaccess`
`Options` and `Require all denied` lines are accepted (no 500); `system_data/` listings are
blocked.

**Verified locally only (PHP built-in server with `router.php`):** everything in
`tests/web/check_pages.sh` and `tests/web/check_stage.sh`; a simulated acquisition uploaded
from MATLAB; and a copy of `check_deployed.sh` with only its https requirement removed, run
against a local server, which passed every check except the http-to-https redirect (the
built-in server has no https). The script itself has not yet been run against IONOS.

**Not yet verified on IONOS:**

1. That `RewriteRule ^ view.php` routes missing paths to `view.php`, and that `DOCUMENT_ROOT`
   is `/home/www/public` for the app (the pages build every URL from it). `check_deployed.sh`
   checks both indirectly (site view 200, image served through PHP, identical 404s).
2. `Options -MultiViews` and the two `FilesMatch` blocks being accepted (a 500 on every page
   would show they are not; see §9).
3. SSH/rsync access for the deploy command.
4. The 30 MB upload (`--big`), auto-refresh and the magnifier in a real browser.
5. That no domain serves `/home/www/www` (the panel check under "Known facts").
