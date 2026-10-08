# Server setup: deploying Brainsaw to IONOS (test deployment at brainsaw.org/testserver)

This is the step-by-step for putting `brainsaw/` on an IONOS Web Hosting plan, first as a
**test deployment at `https://brainsaw.org/testserver/`**, then (later) at the real address.
Background on what the server does is in `instructions.md`; this file is only about getting it
running on IONOS. It replaces `instructions.md` §9 (written for GoDaddy) for this host.

**Status of this guide (8 Oct 2026).** The diagnostic in §2 has been run on this host, so §1
and §2 are done and their results are recorded here. The app itself has **not** yet been
deployed or tested on IONOS: §3 to §8 are still to do. What the diagnostic found, and what it
changed:

- PHP 8.4.23, SAPI `cgi-fcgi`, `ZipArchive` present, `open_basedir` unset.
- `post_max_size` is 1024M and `upload_max_filesize` is 128M, so **no `php.ini` is needed**
  (§6 is skipped).
- PHP can read outside the web root. **`tokens.json` lives at
  `/home/www/www/brainsaw_private/tokens.json`** (§4). (The first guess, `/home/www/brainsaw_private/`,
  was wrong: PHP could not find the file, so the landing page showed no cards. A second
  diagnostic, `diag2.php`, revealed the real path.)
- The `Authorization` header was **not** reaching PHP. Adding a `RewriteRule` to `.htaccess`
  made it appear in `apache_request_headers()`, which is where `lib.php` reads it. That rule is
  now in `brainsaw/.htaccess`, so **uploading the staged copy (replacing the `.htaccess` you
  made for the diagnostic) is what keeps it working**. Whether a real upload then authenticates
  is checked in §7.

Steps marked **(check)** are still unconfirmed on this host.

## What you are building

```
https://brainsaw.org/testserver/
    index.php        landing page, grid of all sites
    site.php         one site's page (image, magnifier, montage, stats)
    upload.php       the endpoint the MATLAB client POSTs to
https://brainsaw.org/testserver/upload.php     <- the `url` in each site's MATLAB config
```

The code uses only relative URLs (`site.php?site=...`, `js/...`, `system_data/...`), so it works
unchanged from any sub-folder. Moving it later from `/testserver` to the web root needs no code
change, only a new upload `url` in each client config.

## Assumptions to confirm first

- The `public` folder you see over SFTP is the **web root of brainsaw.org** (what a browser
  sees at `https://brainsaw.org/`). Confirmed in step 1.1.
- You can connect with **SFTP** (FileZilla, Cyberduck, or the `sftp` command). The host, user
  and password are in the IONOS control panel under the hosting package. Plain FTP is also
  usually offered, but use SFTP if you can.
- The token file must be outside the web root (`/home/www/public`). On this host the right place
  turned out to be `/home/www/www/brainsaw_private/` (the `www` folder inside `/home/www`; the
  listing of `/home/www` shows `public`, `www`, `.ssh` and some dot-files). Use absolute paths
  on the server, as in §5, rather than paths relative to your login folder.

---

## 1. Prepare the domain

### 1.1 ~~Prove which folder is the web root~~ (DONE)

### 1.2 ~~Get HTTPS working~~ (DONE)

### 1.3 ~~Choose the PHP version~~ (DONE)

We are on PHP version 8.4 



---

## 2. Run a diagnostic before deploying anything (DONE for brainsaw.org, 8 Oct 2026)

**Result on this host** (kept so you do not have to repeat it; re-run only if the plan or PHP
version changes):

| Item | Value | Meaning |
|---|---|---|
| PHP / SAPI | 8.4.23 / `cgi-fcgi` | current PHP; FastCGI is why the header was stripped |
| `ZipArchive`, `getimagesize` | yes, yes | fine |
| `post_max_size`, `upload_max_filesize` | 1024M, 128M | fine; nothing to raise (§6) |
| `open_basedir` | none | PHP can read outside the web root |
| `DOCUMENT_ROOT`, folder above | `/home/www/public`, `/home/www` (readable) | web root is `/home/www/public`; `tokens.json` ended up in `/home/www/www/brainsaw_private/` (found with `diag2.php`) |
| `HTTP_AUTHORIZATION`, `REDIRECT_...` | absent, absent | not delivered as a `$_SERVER` variable |
| `apache_request_headers()` | absent at first, **present** after the `.htaccess` rewrite rule | the rule works; `lib.php` reads this path |

**Do not forget:** delete `diag.php` from `public/testserver/` (§5).

The rest of this section is the diagnostic itself, for reuse.

This answers, with facts, the questions that decide whether the app will work on your plan:
is `ZipArchive` there, what are the upload limits, does the `Authorization` header reach PHP,
and what is the real file-system path to the folder above the web root.

Create a file on your computer called `diag.php` with this content. **Replace
`CHANGE-ME-random-string` with a random string** (for example the output of
`openssl rand -hex 8`), so strangers cannot read the page while it is up:

```php
<?php
// TEMPORARY DIAGNOSTIC. Delete this file as soon as you have the answers.
if (($_GET['k'] ?? '') !== 'CHANGE-ME-random-string') { http_response_code(404); exit; }
header('Content-Type: text/plain');

echo "PHP version:        ", PHP_VERSION, "\n";
echo "SAPI:               ", php_sapi_name(), "\n";
echo "ZipArchive:         ", class_exists('ZipArchive') ? 'yes' : 'NO  <-- zip uploads will fail', "\n";
echo "getimagesize:       ", function_exists('getimagesize') ? 'yes' : 'NO', "\n";
echo "post_max_size:      ", ini_get('post_max_size'), "\n";
echo "upload_max_filesize:", ini_get('upload_max_filesize'), "\n";
echo "max_execution_time: ", ini_get('max_execution_time'), "\n";
echo "memory_limit:       ", ini_get('memory_limit'), "\n";
echo "open_basedir:       ", ini_get('open_basedir') ?: '(none)', "\n";
echo "\n";
echo "This folder:        ", __DIR__, "\n";
echo "DOCUMENT_ROOT:      ", $_SERVER['DOCUMENT_ROOT'] ?? '?', "\n";
echo "Folder above it:    ", dirname($_SERVER['DOCUMENT_ROOT'] ?? __DIR__), "\n";
echo "  readable:         ", is_readable(dirname($_SERVER['DOCUMENT_ROOT'] ?? __DIR__)) ? 'yes' : 'no', "\n";
echo "This folder writable:", is_writable(__DIR__) ? 'yes' : 'no', "\n";
echo "\n";

// Never print the header value: only whether it arrived.
$h = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
$r = $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '';
echo "HTTP_AUTHORIZATION:          ", $h !== '' ? "present (length ".strlen($h).")" : 'absent', "\n";
echo "REDIRECT_HTTP_AUTHORIZATION: ", $r !== '' ? "present (length ".strlen($r).")" : 'absent', "\n";
if (function_exists('apache_request_headers')) {
    $found = false;
    foreach (apache_request_headers() as $k => $v) { if (strtolower($k) === 'authorization') $found = true; }
    echo "apache_request_headers():    ", $found ? 'Authorization present' : 'Authorization absent', "\n";
} else {
    echo "apache_request_headers():    not available\n";
}
```

1. Upload it to `public/testserver/diag.php` (create `testserver/` first).
2. Open it in a browser: `https://brainsaw.org/testserver/diag.php?k=<your string>`
3. Test the header from a terminal (this is the important one):

   ```bash
   curl -s -H "Authorization: Bearer test123" \
     "https://brainsaw.org/testserver/diag.php?k=<your string>" | tail -4
   ```

**Reading the output**

| Line | Needed | If not |
|---|---|---|
| `ZipArchive: yes` | yes | Ask IONOS support to enable the PHP `zip` extension. Zip-mode uploads cannot work without it. |
| `post_max_size`, `upload_max_filesize` | both at least ~32M (the app allows 200M, real zips are a few MB) | See §6. |
| `HTTP_AUTHORIZATION` or `apache_request_headers()` shows present | at least one | See §9, "401 even with the right token". Do this before anything else; the server cannot authenticate anything without it. On IONOS the first run showed all three as absent (SAPI `cgi-fcgi`); adding the `RewriteRule` described in §9 made `apache_request_headers()` show it, which is the path `lib.php` reads. That rule is now in `brainsaw/.htaccess`, so deploying that file includes it. |
| `Folder above it` is `readable: yes` | for the token file outside the web root | Use the fallback in §4. |
| `open_basedir` | if set, must include the folder above the web root | Use the fallback in §4. |
| `This folder writable: yes` | yes | Fix permissions (§5). |

Write down the **`Folder above it`** path: you need it in §4.

**Delete `diag.php` from the server when you have the answers.** (It is also in the §5
checklist.) Re-upload it only if you change PHP version or plan, and delete it again.

---

## 3. ~~Build the staged copy~~: `./stage_server.sh`

You do not need to decide what goes where. From the project root (`brainsaw_web_preview/`):

```bash
./stage_server.sh
```

This fills `staging/testserver/` with exactly the files that belong on the server, edits the
staged `config.php` to point at the server's token file, and runs safety checks. **`staging/`
mirrors the server's `public/` folder**, so `staging/testserver/` goes to `public/testserver/`.
`staging/` is git-ignored and contains no secrets. Run the script again whenever anything in
`brainsaw/` changes; it rebuilds the staged copy to match.

**Never reuse the tokens in your local `tokens.json` or printed in `instructions.md`.**
`instructions.md` itself says to treat the demo tokens as compromised. The server gets fresh
tokens from §4.

---

## 4. Tokens: generate fresh ones, keep the file outside the web root

On this host the token file goes at **`/home/www/www/brainsaw_private/tokens.json`** (the web
root is `/home/www/public`, so this is outside it). That path was established with a diagnostic
after the first guess, `/home/www/brainsaw_private/`, turned out to be wrong.

### 4.1 Generate everything locally

**Already done on 8 Oct 2026.** The files are in `~/brainsaw_private_local/` (mode 700, outside
the project and Dropbox): `tokens.json`, `test_site_token.txt` and
`brainsaw_webpreview_test.json`. Use that folder as `PRIV` below. If you ever need to regenerate
them, the commands below make a new set: the server's `tokens.json`, the token on its own, and
the MATLAB test config. **Keep it outside the repo and outside Dropbox**: it contains the
secret. Also copy the token into your password manager.

```bash
PRIV="$HOME/brainsaw_private_local"          # outside the repo and Dropbox
mkdir -p "$PRIV" && chmod 700 "$PRIV" && umask 077
TOKEN="$(openssl rand -hex 32)"
printf '%s\n' "$TOKEN" > "$PRIV/test_site_token.txt"
cat > "$PRIV/tokens.json" <<EOF
{
  "test_site": { "token": "$TOKEN", "display_name": "Test site" }
}
EOF
cat > "$PRIV/brainsaw_webpreview_test.json" <<EOF
{
  "url": "https://brainsaw.org/testserver/upload.php",
  "siteID": "test_site",
  "token": "$TOKEN"
}
EOF
unset TOKEN
ls -la "$PRIV"
```

Never reuse the tokens in your local `tokens.json` or in `instructions.md`. Add more sites later
by adding entries to the **server's** `tokens.json` (no restart needed; it is re-read on every
request).

### ~~4.2 `tokens.json` goes on the server, outside `public/`~~

On the server it lives at `/home/www/www/brainsaw_private/tokens.json`, outside the web root
(`/home/www/public`). Only that one file goes there; never upload `test_site_token.txt` or the MATLAB
config. §5.2 has the commands.



---

## 5. Upload

Everything here assumes `./stage_server.sh` has been run (§3) and `PRIV` is set (§4.1).
`USER@HOST` is your IONOS SFTP/SSH login from the control panel. The commands use **absolute
server paths** (the web root is `/home/www/public`) so they do not depend on which folder your
login starts in. If SSH is "chrooted" on your plan and these paths do not exist, adjust them to
match what your SFTP program shows. The diagnostic listing of `/home/www` contained `.ssh`, which
suggests SSH is enabled **(check)**.

### 5.1 Send the app: `staging/` to `public/`

**With rsync over SSH** (needs SSH access on your IONOS plan: **(check)**). Do a dry run first;
`-n` only lists what would change:

```bash
rsync -avzn --chmod=D755,F644 -e ssh staging/ USER@HOST:/home/www/public/
rsync -avz  --chmod=D755,F644 -e ssh staging/ USER@HOST:/home/www/public/
```

- This **replaces the `.htaccess`** you created for the diagnostic with the staged one (rewrite
  rule, HTTPS redirect, blocking rules). That is intended.
- **No `--delete`, on purpose.** On the server, `public/testserver/` also holds uploaded site
  data (`system_data/test_site/...`) and `logs/upload.log`, which are not in `staging/`.
  `--delete` would remove them.
- If your SSH login lands in a folder other than the one containing `public/`, adjust the
  `public/` part of the destination.



### 5.2 ~~Send the token file (once)~~ (DONE)

`tokens.json` is not in `staging/`. Create `/home/www/www/brainsaw_private/` (outside the web
root) and put only `tokens.json` there:

```bash
ssh USER@HOST 'mkdir -p /home/www/www/brainsaw_private && chmod 700 /home/www/www/brainsaw_private'
scp "$PRIV/tokens.json" USER@HOST:/home/www/www/brainsaw_private/tokens.json
ssh USER@HOST 'chmod 600 /home/www/www/brainsaw_private/tokens.json'
```



### 5.3 Delete the diagnostics

`diag.php` and `diag2.php` print server details, so remove them as soon as you have the answers:

```bash
ssh USER@HOST 'rm -f /home/www/public/testserver/diag.php /home/www/public/testserver/diag2.php /home/www/public/hello.txt'
```

(or delete them in your SFTP program). Check: `curl -s -o /dev/null -w '%{http_code}\n' https://brainsaw.org/testserver/diag2.php`
should print `404`.

### 5.4 Permissions and a first look

- Directories `755` and files `644` are set by the rsync command above; with an SFTP program
  that is normally the default. `system_data/` and `logs/` must be writable by the PHP user.
  The diagnostic showed `public/testserver/` writable and PHP runs as your account under
  FastCGI, so `755` should be enough. If uploads later fail with a 500 and the log says it
  cannot write, try `775` on those two folders.

---

## 6. PHP limits (NOT needed on this host)

On this host `post_max_size` is 1024M and `upload_max_filesize` is 128M, which are plenty: real
preview zips are a few MB. **Skip this section** unless you move to a host with lower limits.

One cosmetic point: the app's own `max_zip_size` is 200 MB (in `config.php`), above PHP's 128M
upload limit. A zip between 128 MB and 200 MB would be cut off by PHP before the app can give
its clean `413` reply. Real uploads never get near that, so it is optional, but you can set
`max_zip_size` to `100 * 1024 * 1024` in the staged `config.php` to make the app reject first.

On a host where the PHP limits are too low, a too-large upload fails confusingly (a "missing
site_id" 403 instead of a clean 413; see `instructions.md` §3). IONOS's guide says you change PHP
settings by uploading a `php.ini` file into the folder the settings should apply to, and that
the exact procedure depends on when the contract was bought. **(check)** For example:

```ini
post_max_size = 250M
upload_max_filesize = 250M
```

Re-run `diag.php` to confirm, then delete it again. If a host will not let you raise the
values, make sure both are at least ~32M and lower `max_zip_size` in `config.php` to match.

---

## 7. Test the endpoint

### 7.1 Run the check script (recommended)

`tests/web/check_deployed.sh` runs the checks below against a live server and prints PASS or
FAIL for each. From the repo root, once §5 is done:

```bash
tests/web/check_deployed.sh https://brainsaw.org/testserver \
    "$PRIV/test_site_token.txt" test_images/all_data.zip --big
```

- `$PRIV` is the folder from §4.1 (`~/brainsaw_private_local`); set it with
  `PRIV="$HOME/brainsaw_private_local"`. The script reads the token from the file and never
  prints it.
- `--big` also uploads a 30 MB zip, which checks the PHP size limits. Leave it out for a quick run.
- It waits 6 s between uploads because the server allows one upload per site every 5 s.
- It ends with `N passed, M failed` and exits non-zero on any failure.
- It uploads the test zip, so the test site will show the demo images afterwards.

What it checks: HTTP redirects to HTTPS; GET returns 405; no token 401; wrong token 403;
unknown site 403; a valid zip upload returns `{"status":"ok",...}`; `tokens.json`, `upload.log`,
the raw recipe, the raw acquisition log and the `system_data/` listing are all blocked;
`meta.json`, the landing page and the site page are served, and the site page contains the main
image.

**Most important result:** "valid zip upload" passing means the `Authorization` header is
reaching PHP through the rewrite rule. If it fails with 401, see §9.

Then look at the pages in a browser (below). The rest of this section is the same checks done by
hand, for reference and for diagnosing a failure.

### 7.2 The same checks by hand

Set these once in your terminal:

```bash
BASE=https://brainsaw.org/testserver
TOKEN=<the token you generated for test_site>
ZIP=<repo>/test_images/all_data.zip       # a real 4-file test zip (about 1 MB)
```

Run these in order. Wait more than 5 seconds between uploads to the same site: the server
rate-limits a site to one upload per `min_upload_interval_seconds` (5 s).

| # | Command | Expected |
|---|---|---|
| 1 | `curl -sI http://brainsaw.org/testserver/ \| head -3` | a `301` redirect to `https://...` |
| 2 | `curl -s -o /dev/null -w '%{http_code}\n' $BASE/upload.php` | `405` (GET not allowed) |
| 3 | `curl -s -o /dev/null -w '%{http_code}\n' -X POST $BASE/upload.php -F site_id=test_site` | `401` (no token) |
| 4 | `curl -s -o /dev/null -w '%{http_code}\n' -X POST $BASE/upload.php -H "Authorization: Bearer wrong" -F site_id=test_site` | `403` |
| 5 | `curl -s -o /dev/null -w '%{http_code}\n' -X POST $BASE/upload.php -H "Authorization: Bearer $TOKEN" -F site_id=nope` | `403` |
| 6 | `curl -s -X POST $BASE/upload.php -H "Authorization: Bearer $TOKEN" -F site_id=test_site -F "data=@$ZIP;type=application/zip"` | `{"status":"ok","files":[...]}` listing the 4 files |

**Protected files** (all must be blocked; a `200` here is a security problem):

```bash
curl -s -o /dev/null -w 'tokens.json:   %{http_code}\n' $BASE/tokens.json             # 403 or 404
curl -s -o /dev/null -w 'upload.log:    %{http_code}\n' $BASE/logs/upload.log          # 403
curl -s -o /dev/null -w 'recipe (raw):  %{http_code}\n' "$BASE/system_data/test_site/recipe_SW_FG12_3_FG_12_2_191209_120354.yml"   # 403
curl -s -o /dev/null -w 'acq log (raw): %{http_code}\n' "$BASE/system_data/test_site/acqLog_SW_FG12_3_FG_12_2.txt"                  # 403
curl -s -o /dev/null -w 'dir listing:   %{http_code}\n' $BASE/system_data/            # 403
curl -s -o /dev/null -w 'meta.json:     %{http_code}\n' $BASE/system_data/test_site/meta.json                                      # 200
```

If the recipe or log returns `200`, the `.htaccess` in `system_data/` is not being applied. Do
not put real data on the server until that is fixed: recipes can contain pasted secrets such as
Slack webhook URLs.

**Large-upload test** (checks the PHP limits from §6):

```bash
head -c 30000000 /dev/urandom > /tmp/big.txt
(cd /tmp && zip -q big.zip big.txt)
sleep 6
curl -s -X POST $BASE/upload.php -H "Authorization: Bearer $TOKEN" \
  -F site_id=test_site -F "data=@/tmp/big.zip;type=application/zip"
rm -f /tmp/big.txt /tmp/big.zip
```

Expect `{"status":"ok",...}`. A `403 unknown site_id` or a `413` here points at `post_max_size`
or `upload_max_filesize` being too low. Re-upload `all_data.zip` afterwards so the site shows
the proper test images again.

**Look at the pages** in a browser:

- `https://brainsaw.org/testserver/` : landing page with a card for `test_site`.
- `https://brainsaw.org/testserver/site.php?site=test_site` : main image, hover magnifier,
  montage link, metadata table, acquisition-time chart.
- Leave the site page open, wait >5 s, repeat the step 6 upload: the page should refresh
  itself within about 5 s without you reloading.

(The images in `all_data.zip` are real data from an old finished acquisition and will be
publicly visible on the test site.)

---

## 8. Test from MATLAB (the real client)

This is the first time the `webpreview` MATLAB code talks to a real server, and none of that
MATLAB code has been run yet, so expect to find things.

1. Use the MATLAB config that §4.1 created (`brainsaw_webpreview_test.json`). Copy it somewhere
   safe, not into a repository, and restrict its permissions:

   ```bash
   cp "$PRIV/brainsaw_webpreview_test.json" ~/.brainsaw_webpreview_test.json
   chmod 600 ~/.brainsaw_webpreview_test.json
   ```

   Its contents are the upload `url` (`https://brainsaw.org/testserver/upload.php`), the
   `siteID` (`test_site`) and the token. Use that exact `https` address: the client treats a
   redirect as a failure.

2. In MATLAB:

   ```matlab
   addpath('<repo>/BakingTray/webpreview')                   % the folder CONTAINING +webpreview
   cfgFile = fullfile(getenv('HOME'),'.brainsaw_webpreview_test.json');
   img = imread('<repo>/test_images/LastCompleteSection_01.jpg');
   res = webpreview.updateSectionImage(img, ...
       '<repo>/test_images/recipe_SW_FG12_3_FG_12_2_191209_120354.yml', ...
       '<repo>/test_images/acqLog_SW_FG12_3_FG_12_2.txt', ...
       'ConfigFile', cfgFile);
   disp(res.ok), disp(res.post)
   ```

   Expect `res.ok` true and `res.post.httpStatus` 200. The call never throws; on failure read
   `res.post.message` and the warning it issues.

3. Run it twice more, more than 5 s apart, and watch the site page update.
4. Also run the package's tests: `runtests(fullfile('<repo>','BakingTray','webpreview','tests'))`.

The old client scripts in `brainsaw/clients/` still have `https://brainsaw.mouse.vision/brainsaw/upload.php`
as their default `URL`; edit that line if you use them.

---

## 9. Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| **500 on every page** after uploading | The `.htaccess` uses `Options -Indexes` and `Options -ExecCGI`, which some hosts disallow in `.htaccess`. Rename `.htaccess` (top level and in `system_data/`) to `.htaccess.off`, reload to confirm that is the cause, then remove only the `Options` lines. Then re-run the protected-files checks in §7, because without those rules a folder listing is possible. |
| **401 "missing or malformed Authorization header"** with a correct token | PHP is not receiving the `Authorization` header (common when PHP runs as FastCGI). Confirm with the §2 diagnostic, sending the header with `curl -H`. The fix is in `brainsaw/.htaccess` (the `RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]` block at the top); make sure the deployed `.htaccess` still has it. **Note:** `lib.php` reads `HTTP_AUTHORIZATION` and `apache_request_headers()` but **not** `REDIRECT_HTTP_AUTHORIZATION`; on IONOS the header appeared via `apache_request_headers()`, so no change was needed, but a host that delivers it only under the `REDIRECT_` name would need a one-line change to `lib.php`. If the rule does not help, try `SetEnvIf Authorization "(.+)" HTTP_AUTHORIZATION=$1` instead, then ask IONOS support. |
| **403 "unknown site_id"** on a valid site, or a "missing site_id" style error on large files | Body larger than `post_max_size`, so PHP discarded the POST fields. See §6. |
| **`Class "ZipArchive" not found`** (500, or in `logs/upload.log`) | The zip extension is not enabled. Ask IONOS support. |
| **Cannot write / 500 while saving an upload** | `system_data/` or `logs/` is not writable. See §5 permissions. |
| **Pages load but no styling/magnifier** | `site.php` loads jQuery from `code.jquery.com`; a network that blocks it breaks the magnifier. Check the browser console. |
| **Works in a browser, fails from MATLAB with a redirect message** | The configured `url` is not the final address (HTTP instead of HTTPS, or `www` vs bare domain). Use the exact `https://brainsaw.org/...` address that does not redirect. |
| **Landing page shows only the title, no cards** (the pages themselves load) | The app cannot read `tokens.json`, and `bs_load_tokens()` silently returns an empty list. Confirm from a terminal: `curl -s -X POST https://brainsaw.org/testserver/upload.php -H "Authorization: Bearer wrong" -F site_id=test_site` answers `invalid token` if the file is read, but `unknown site_id` if it is not. To see why, upload a temporary `diag2.php` that prints the configured `tokens_file` path, whether it exists and is readable, whether it parses as JSON, and the site ids in it (never the tokens), plus the contents of `/home/www`. Usual causes: the uploaded `config.php` is not the staged one (re-run `./stage_server.sh` and upload again); the SFTP login folder is not `/home/www`, so the file is in the wrong place (re-stage with `--tokens-path`); the file is damaged (re-upload from your private folder); the file is not readable by the PHP user. Delete `diag2.php` afterwards. |
| **`unknown site_id` from MATLAB, but `curl` uploads work** (same token and site id) | The request reached PHP but its body was not parsed: on this host PHP (FastCGI) loses every form field, including `site_id`, when the request has **no `Content-Length`** (chunked transfer encoding). Demonstrated with `curl -H "Transfer-Encoding: chunked"` (`unknown site_id`) versus the same request with a length (`invalid token` for a wrong token). `postZip` therefore builds the multipart body in memory (`buildMultipart`) so MATLAB sends a length, and assigns the bytes to `MessageBody.Payload` (assigning them to `Data` fails with `Data of type "uint8" ... is inconsistent with Content-Type "multipart/form-data"`, because `Data` is converted according to the Content-Type). If it still happens, look at the last lines of `logs/upload.log` on the server (`missing/invalid site_id` means the field did not arrive; `unknown site_id` means the id is not in `tokens.json`), and check in MATLAB that the request really has a `Content-Length` (see `hist(1).Request.show` after `[~,~,hist] = req.send(url)`); if MATLAB does not add one, add `matlab.net.http.field.ContentLengthField(numel(payload))` to the request headers. |
| **SSL warning in the browser** | The certificate is not assigned to this domain yet (§1.2). |

---

## 10. Clean up and security checklist

- [ ] `diag.php` deleted from the server (and `hello.txt`).
- [ ] The diagnostic `.htaccess` was replaced by the staged one (it has the rewrite rule, HTTPS
      redirect and blocking rules). `./stage_server.sh` checks the staged copy has them.
- [ ] The folder with the secret files (`PRIV` in §4.1) is outside the repo and outside Dropbox,
      and the token is in your password manager.
- [ ] Only `tokens.json` was uploaded to `/home/www/www/brainsaw_private/`.
- [ ] `diag2.php` (and `diag.php`) are gone from the server.
- [ ] No other `phpinfo()` or scratch PHP files on the server.
- [ ] `tokens.json` is outside `public/` (or returns 403/404 by URL).
- [ ] Tokens on the server are fresh, stored in your password manager, and not the ones in
      `instructions.md` or your local `tokens.json`.
- [ ] `tests/web/check_deployed.sh` finished with 0 failed (or, by hand, every protected-file
      check in §7 returned 403/404 and `meta.json` and images returned 200).
- [ ] `https://brainsaw.org/testserver/` loads over HTTPS and `http://` redirects to it.
- [ ] You know which PHP version the site runs, and it is a supported one.

---

## 11. Going from the test to the real deployment

When the test passes:

1. Deploy the same files to the real location, built from a fresh staged copy (§3), with
   **new** tokens in a new `tokens.json` (§4). Do not copy the test tokens over. For a folder
   such as `public/brainsaw/` run `./stage_server.sh --dest brainsaw` (add `--no-demo` and a
   different `--tokens-path` such as `/home/www/www/brainsaw_private/tokens_live.json` if you want
   the live tokens in a separate file). For the web root itself, the script would need a small
   extension (it only stages into a sub-folder); ask for that when you get there.
2. Remove `system_data/demo_site/` if you do not want the demo card on the real landing page.
3. Nothing to copy for PHP limits on this host (§6). Keep the rewrite rule in `.htaccess`.
4. Give each site its `site_id`, its token, and the real URL, for example
   `https://brainsaw.org/upload.php`. Test each site's client against the test deployment first
   (`instructions.md` §7), and keep `/testserver` as a standing canary.
5. Add sites in `tokens.json` as in `instructions.md` §5. The file is re-read on every request,
   so no restart is needed.

## 12. What has and has not been verified

**Verified on 8 Oct 2026 (by the §2 diagnostic on brainsaw.org):**
PHP 8.4.23 under `cgi-fcgi`; `ZipArchive` and `getimagesize` present; `post_max_size` 1024M and
`upload_max_filesize` 128M; no `open_basedir`; `/home/www` readable; `public/testserver/`
writable; the token file readable and valid JSON at `/home/www/www/brainsaw_private/tokens.json`
(`diag2.php`, which listed the site id `test_site`); the `Authorization` header is visible through `apache_request_headers()` once the
rewrite rule is in `.htaccess`. Also done by you: the web root, HTTPS and PHP version (§1).

**Verified locally by Claude (PHP built-in server, staged copy):** all five rejection status
codes, a valid zip upload, and the landing and site pages. This does **not** exercise
`.htaccess`.

**Verified against the live server by `tests/web/check_deployed.sh` (8 Oct 2026, 15 of 15
passed, run without `--big`):** `http://` redirects to `https://`; GET upload is 405, no token 401,
wrong token 403, unknown site 403; **a real zip upload with the token authenticates and is
accepted** (so the `Authorization` rewrite rule works in practice); `tokens.json`, `upload.log`,
raw recipe and raw acquisition log are blocked (403) and `system_data/` has no directory listing,
which also shows the `.htaccess` `Options` and `Require all denied` lines are accepted by IONOS
(no 500); `meta.json`, the landing page and the site page are served, and the site page contains
the main image. The token file is read from `/home/www/www/brainsaw_private/tokens.json`.

**Still unverified:**

1. The 30 MB upload (`--big`), the page auto-refresh in a browser, the magnifier, and how the
   pages look (only status codes and one string were checked).
2. That the SSL certificate is valid for `brainsaw.org` in a browser (the `https` requests above
   succeeded, which suggests yes, but `curl` was not told to report certificate details).
3. SSH/rsync access for `stage_server.sh`'s suggested commands (the upload so far was done by hand).
4. That the MATLAB `webpreview` package runs correctly end to end: it has not been run in MATLAB
   (§8 is the first real test).
5. Write permissions for `system_data/test_site/` were exercised by the successful upload; the log
   file `logs/upload.log` was not inspected.
