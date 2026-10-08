#!/usr/bin/env bash
# Renders the viewer pages from a throwaway copy of brainsaw/ (own tokens.json,
# only the demo_site data) served by `php -S ... router.php`, and checks the
# auto-refresh wiring. Never touches tracked data or a real tokens.json.
# Usage (from anywhere): bash tests/web/check_pages.sh [port]
# Port: first argument, else $CHECK_PAGES_PORT, else 18765.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/brainsaw"
PORT="${1:-${CHECK_PAGES_PORT:-18765}}"
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

fail=0
check() { # description, command...
  local desc="$1"; shift
  if "$@"; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}
body_has()   { grep -qF -- "$2" <<<"$1"; }
body_lacks() { ! grep -qF -- "$2" <<<"$1"; }
# True if some <meta http-equiv="refresh"> line is not wrapped in <noscript>.
has_bare_meta_refresh() { grep 'http-equiv="refresh"' <<<"$1" | grep -qv '<noscript>'; }
no_bare_meta_refresh()  { ! has_bare_meta_refresh "$1"; }

check "php -l lib.php" php -l "$SRC/lib.php" >/dev/null

if curl -s -o /dev/null "http://localhost:$PORT/"; then
  echo "FAIL  port $PORT is already in use; pass another port"; exit 1
fi

# Copy without secrets or other sites' data: keep only demo_site.
cp -R "$SRC" "$TMP/brainsaw"
cd "$TMP/brainsaw"
rm -f tokens.json test-upload/tokens.json
find system_data -mindepth 1 -maxdepth 1 ! -name demo_site ! -name .htaccess -exec rm -rf {} +
printf '{"demo_site":{"token":"t","display_name":"Demo"},"never_site":{"token":"t2","display_name":"Never"}}' > tokens.json
cp tokens.json test-upload/tokens.json
mkdir -p test-upload/system_data/demo_site
cp system_data/demo_site/meta.json test-upload/system_data/demo_site/meta.json

UPLOADED_AT="$(php -r 'echo json_decode(file_get_contents("system_data/demo_site/meta.json"), true)["uploaded_at"];')"
STALE_AFTER="$(php -r '$c = require "config.php"; echo (int) $c["stale_after_seconds"];')"

php -S "localhost:$PORT" router.php >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://localhost:$PORT/index.php" && break
  sleep 0.2
done
curl -s -o /dev/null "http://localhost:$PORT/index.php" || { echo "FAIL  server did not start within 10 s"; exit 1; }

meta_url_of() { sed -n 's/.*data-meta-url="\([^"]*\)".*/\1/p' <<<"$1" | head -n1; }

for base in "" "test-upload/"; do
  label="${base:-root}"
  idx="$(curl -fsS "http://localhost:$PORT/${base}index.php")"
  site="$(curl -fsS "http://localhost:$PORT/${base}site.php?site=demo_site")"
  for pair in "index:$idx" "site:$site"; do
    name="${pair%%:*}"; html="${pair#*:}"
    check "$label $name: inlined script present"        body_has  "$html" 'function humanAgo'
    check "$label $name: no src= to autorefresh.js"     body_lacks "$html" 'src="js/autorefresh.js'
    check "$label $name: meta url attribute"            body_has  "$html" 'data-meta-url="system_data/demo_site/meta.json"'
    check "$label $name: uploaded-at equals meta.json"  body_has  "$html" "data-uploaded-at=\"$UPLOADED_AT\""
    check "$label $name: stale-after equals config"     body_has  "$html" "data-stale-after=\"$STALE_AFTER\""
    check "$label $name: server-now on body"            body_has  "$html" '<body data-server-now="'
    check "$label $name: noscript meta refresh"         body_has  "$html" '<noscript><meta http-equiv="refresh" content="60"></noscript>'
    check "$label $name: no unconditional meta refresh" no_bare_meta_refresh "$html"
    url="$(meta_url_of "$html")"
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/${base}${url}")"
    check "$label $name: embedded meta URL returns 200" test "$code" = 200
  done
  check "$label index: never-uploaded card has empty uploaded-at" body_has "$idx" 'data-uploaded-at=""'
  hdrs="$(curl -fsS -D - -o /dev/null "http://localhost:$PORT/${base}index.php" | tr -d '\r')"
  check "$label index: Cache-Control: no-store" body_has "$hdrs" 'Cache-Control: no-store'
  hdrs="$(curl -fsS -D - -o /dev/null "http://localhost:$PORT/${base}site.php?site=demo_site" | tr -d '\r')"
  check "$label site: Cache-Control: no-store" body_has "$hdrs" 'Cache-Control: no-store'
done

# Missing script: pages must fall back to an unconditional refresh, no empty <script>.
mv js/autorefresh.js js/autorefresh.js.off
for base in "" "test-upload/"; do
  label="${base:-root}"
  for path in "index.php" "site.php?site=demo_site"; do
    html="$(curl -fsS "http://localhost:$PORT/${base}${path}" 2>/dev/null)"
    check "$label $path (JS missing): unconditional meta refresh" has_bare_meta_refresh "$html"
    check "$label $path (JS missing): no inlined script"          body_lacks "$html" 'function humanAgo'
  done
done
mv js/autorefresh.js.off js/autorefresh.js

exit "$fail"
