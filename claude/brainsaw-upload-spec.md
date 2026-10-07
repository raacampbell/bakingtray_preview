# Brainsaw Multi-Site Upload Spec

## 1. Background & Goal

`brainsaw.mouse.vision` currently shows the latest completed section from our own
microscopes. An analysis PC runs a script that, after each section finishes,
downsamples the image and `rsync`s it to the webserver over SSH using a shared
key.

Other groups have built the same type of scope and want the same live-preview
page, but onboarding them currently means generating an SSH keypair, installing
it, and managing `authorized_keys` — too much friction, and a shared key across
sites is a security liability.

**Goal:** replace SSH/rsync with a simple HTTPS upload endpoint, authenticated
per-site with a bearer token, so that adding a new site is "hand them a token
and a 10-line client script" rather than SSH key exchange.

**Scale (important — do not over-engineer):**
- ~13 scopes total (3 ours + 10 elsewhere) once fully rolled out
- ~1 image every 2–5 minutes per scope, each ~1 MB
- Worst case ~9–10 GB/day *transferred*, but **standing storage is tiny**
  (~13 MB) because each scope only ever needs to keep its latest image
- No need for object storage (S3/R2), load balancing, queues, or a database
  server. Flat files + a small JSON/SQLite config on existing GoDaddy shared
  hosting are entirely sufficient.

**Hosting:** GoDaddy shared hosting, PHP available via cPanel. No ability to
run persistent Python/Node processes — everything server-side must work as
plain PHP scripts invoked per-request (standard shared hosting model).

---

## 2. Architecture Overview

```
[Scope PC #1] ─┐
[Scope PC #2] ─┼─ HTTPS POST (bearer token) ──> [upload.php on GoDaddy] ──> /images/{site_id}/latest.jpg (atomic write)
[Scope PC #N] ─┘

[Browser] ──> [index.php / viewer page] ──> reads /images/{site_id}/latest.jpg per site, auto-refreshes
```

- Push-only model (client PCs are behind institutional NAT/firewalls with no
  inbound access — this is not optional, it's a hard constraint).
- One PHP endpoint accepts uploads from any authorized site.
- One directory per site, each containing only that site's most recent image
  (previous image is simply overwritten).
- Token list lives server-side in a config file (flat file or SQLite — see
  §4), not hardcoded in PHP source.

---

## 3. Directory Layout (on GoDaddy)

```
/public_html/
  brainsaw/
    upload.php              # upload endpoint
    config.php               # loads tokens + settings, not web-accessible directly if possible
    tokens.json               # site_id -> token, secret info, keep outside public_html if possible
    index.php                 # viewer page, lists all sites + latest images
    images/
      {site_id}/
        latest.jpg
        latest.jpg.tmp        # transient, used for atomic write, should not persist
      .htaccess                # deny execution, deny directory listing
    test-upload/                # throwaway clone of upload.php + its own token for testing
      upload.php
      images/
```

If GoDaddy account structure allows a directory outside `public_html`
(commonly possible via cPanel), put `tokens.json` there instead, so it is not
directly downloadable even by guessing the URL. If not possible, block it via
`.htaccess` (see §7).

---

## 4. Token / Site Management

- Each site gets a `site_id` (short slug, e.g. `smith_lab_scope1`) and a
  random bearer token (e.g. 32 bytes, base64url or hex — generate with
  `bin2hex(random_bytes(32))` in PHP or `openssl rand -hex 32` on CLI).
- Store as simple JSON, e.g.:

```json
{
  "our_scope_1": { "token": "b6f1...", "display_name": "Scope 1 (Room 402)" },
  "our_scope_2": { "token": "9ac0...", "display_name": "Scope 2 (Room 402)" },
  "smith_lab_scope1": { "token": "1e77...", "display_name": "Smith Lab - Scope A" }
}
```

- Adding a new site = add one entry to this file and send the site_id +
  token to the collaborator. No deploy, no restart needed (PHP reads the file
  fresh each request).
- No need for a full database at this scale. If it later feels unwieldy,
  migrating to SQLite is a small change, not a rewrite — don't build that now.

---

## 5. `upload.php` — Endpoint Spec

**Method:** `POST`
**Auth:** `Authorization: Bearer <token>` header
**Body:** `multipart/form-data` with fields:
  - `site_id` (string, must match an entry in `tokens.json`, and its token
    must match the one supplied)
  - `image` (file, JPEG)

**Behavior:**
1. Reject if method isn't POST → `405`.
2. Reject if `Authorization` header missing/malformed → `401`.
3. Reject if `site_id` missing or unknown → `403`.
4. Reject if token doesn't match the token on file for that `site_id` → `403`.
   (Use a constant-time comparison — `hash_equals()` in PHP — not `==`.)
5. Reject if no `image` file uploaded, or upload error occurred
   (check `$_FILES['image']['error']`) → `400`.
6. Reject if file exceeds a sane max size, e.g. 10 MB (generous headroom
   above the expected ~1 MB) → `413`.
7. Validate the file is actually a JPEG:
   - Check the file extension AND
   - Verify actual content via `getimagesize()` or `exif_imagetype()` — don't
     trust the client-supplied MIME type alone.
   - Reject anything else → `415`.
8. Ensure `/images/{site_id}/` exists; create if not (`mkdir` with safe
   permissions, e.g. `0755`).
9. Write upload to `/images/{site_id}/latest.jpg.tmp`.
10. Atomically `rename()` the tmp file to `/images/{site_id}/latest.jpg`.
    This is the critical step that prevents the viewer page from ever
    fetching a half-written file — `rename()` on the same filesystem is
    atomic on Linux.
11. Also write/update a small `meta.json` in the same directory with
    `{ "uploaded_at": "<ISO8601 UTC timestamp>" }`, again via tmp+rename,
    so the frontend can show "last updated X minutes ago" and flag stale
    feeds (see §6).
12. Return `200` with a minimal JSON body, e.g. `{"status":"ok"}`.
13. On any rejection, return a short JSON error body, e.g.
    `{"status":"error","message":"..."}`, and an appropriate HTTP status
    code — don't leak stack traces or file paths in the response.

**Logging:** Append one line per request (timestamp, site_id, status,
IP) to a simple log file for debugging — not critical, but cheap and useful
when something goes wrong at 2am during a long acquisition.

---

## 6. Viewer Page (`index.php`) Spec

- On load, reads `tokens.json` (or a separate `sites.json` if you don't want
  display names living next to secrets — reasonable to split these) to get
  the list of `site_id` → `display_name`.
- For each site, displays:
  - `display_name`
  - The latest image (`/images/{site_id}/latest.jpg`)
  - "Last updated" derived from `meta.json`'s `uploaded_at`
  - A visual "stale" indicator if `uploaded_at` is older than some threshold
    (e.g. 15 minutes — configurable constant) — since a scope going silent
    for that long is itself useful signal (acquisition stalled, script
    crashed, network issue).
- Auto-refreshes periodically (e.g. every 30–60 seconds) — simplest approach
  is a `<meta http-equiv="refresh">` or a small JS `setInterval` that
  re-fetches images with a cache-busting query param
  (`latest.jpg?t=<timestamp>`), and separately re-fetches `meta.json` to
  update the "last updated" text without a full page reload if you want it
  smoother. Either is fine at this point — don't over-build; a full-page
  refresh every 30s is completely acceptable for this use case.
- Should degrade gracefully if a site has never uploaded yet (`latest.jpg`
  missing) — show a placeholder rather than a broken image icon.

---

## 7. Security

- **`.htaccess` in `/images/`:**
  - Disable directory listing (`Options -Indexes`).
  - Disable script execution (`php_flag engine off`, or restrict via
    `<FilesMatch>` to only serve `.jpg`/`.json`) so an uploaded file can
    never be executed even if validation is somehow bypassed.
- **`tokens.json` / `config.php` must not be web-servable.** Either place
  outside `public_html`, or add an `.htaccess` rule denying all access to
  that specific file (`<Files "tokens.json">Require all denied</Files>` or
  the older `Order allow,deny / Deny from all` syntax depending on Apache
  version GoDaddy runs).
- Use `hash_equals()` for token comparison (timing-attack safe).
- Enforce HTTPS only — GoDaddy should provide a free SSL cert (AutoSSL /
  Let's Encrypt via cPanel) if not already enabled; reject plain HTTP or
  redirect to HTTPS.
- Validate file content (not just extension/MIME header) before writing
  anything to disk, per §5 step 7.
- Rate limiting is not critical at this scale/trust level (all uploaders are
  known collaborators with individual tokens), but consider a basic check
  (e.g. reject if same `site_id` uploaded < 5 seconds ago) as a cheap
  safeguard against a misbehaving script hammering the endpoint.

---

## 8. Client-Side Upload Script (per site)

Deliverable: a minimal script the collaborator drops into their existing
acquisition pipeline, after the downsample step. Two variants worth
providing since sites will have Python or MATLAB already in their pipeline
in most cases (project also touches Arduino/C++ occasionally but unlikely
relevant here):

**curl (works from anything, including a MATLAB `system()` call):**
```bash
curl -s -X POST https://brainsaw.mouse.vision/brainsaw/upload.php \
  -H "Authorization: Bearer THEIR_TOKEN_HERE" \
  -F "site_id=THEIR_SITE_ID" \
  -F "image=@/path/to/latest_downsampled.jpg"
```

**Python (requests):**
```python
import requests

TOKEN = "THEIR_TOKEN_HERE"
SITE_ID = "THEIR_SITE_ID"
URL = "https://brainsaw.mouse.vision/brainsaw/upload.php"

def upload_latest(image_path):
    with open(image_path, "rb") as f:
        resp = requests.post(
            URL,
            headers={"Authorization": f"Bearer {TOKEN}"},
            data={"site_id": SITE_ID},
            files={"image": f},
            timeout=15,
        )
    resp.raise_for_status()
    return resp.json()
```

Should be documented as a copy-paste snippet with only `TOKEN`/`SITE_ID`
needing edits — this is the entire integration burden for a new site.

---

## 9. Testing Plan

### Layer 1 — Local, no server needed
Run PHP's built-in dev server against a local copy of the `brainsaw/` folder:
```bash
php -S localhost:8000
```
Test with `curl` against `http://localhost:8000/upload.php`:
- Valid upload → `200`, file appears atomically, `meta.json` updates.
- Missing/incorrect token → `401`/`403`.
- Unknown `site_id` → `403`.
- Non-image file (e.g. rename a `.txt` to `.jpg` and upload) → `415`.
- Oversized file → `413`.
- Rapid back-to-back uploads to same `site_id` (simple bash loop) → confirm
  no partial/corrupt file is ever visible mid-write (spot-check by reading
  file size in a tight loop from a second terminal during upload of a large
  test file).

### Layer 2 — On GoDaddy, isolated test path
- Deploy to a throwaway `/brainsaw/test-upload/` path with its own token,
  separate from the live site's real directories/tokens.
- Repeat the Layer 1 `curl` tests against
  `https://brainsaw.mouse.vision/brainsaw/test-upload/upload.php`.
- Specifically confirm GoDaddy's PHP `upload_max_filesize` /
  `post_max_size` ini limits accommodate the ~1 MB (up to 10 MB cap) images
  — shared hosting sometimes has lower default caps than expected.
- Confirm file permissions after `mkdir`/write are correct and readable by
  the webserver for the viewer page.

### Layer 3 — Simulated real client, external network
- Run the Python or curl client script from a network that is NOT on the
  same LAN as the server (e.g. phone tethering), to catch any egress
  firewall/proxy issues a genuinely remote site might hit.
- Confirm end-to-end: script runs → image appears on
  `test-upload` viewer path within expected time → `meta.json` timestamp
  updates.

### Ongoing
- Keep `test-upload/` (or equivalent) around permanently as a canary
  endpoint for validating new sites' scripts before flipping them onto the
  real token/site_id.

---

## 10. Rollout Plan

1. Build and test `upload.php` + `index.php` per §9 Layers 1–2.
2. Migrate our 3 existing scopes from rsync/SSH to the new HTTPS endpoint;
   run in parallel with the old method briefly if you want a safety net,
   then retire the SSH-based script.
3. Onboard external groups one at a time: generate their token/site_id entry,
   send them §8's snippet with their values filled in, have them run Layer 3
   test against `test-upload` before switching their production script to
   the real endpoint.
4. Document the whole flow (this spec + the two client snippets) somewhere
   shareable so future sites can mostly self-serve once you've handed them a
   token.

---

## 11. Explicitly Out of Scope (do not build)

- Object storage (S3/R2) — unnecessary at this volume.
- A database server — flat JSON/file-based config is sufficient.
- Queueing, load balancing, horizontal scaling.
- User accounts / login system for the viewer page (unless later desired —
  not part of this spec; assume viewer page is either public or protected by
  simple HTTP basic auth at the Apache level if needed).
- Historical image archive/gallery (current spec only keeps the latest image
  per site, matching current behavior) — flag as a possible future
  enhancement but not part of this build.
