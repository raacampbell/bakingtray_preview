#!/usr/bin/env bash
# Renders the viewer pages from a throwaway copy of brainsaw/ (own tokens.json,
# own site data) served by `php -S ... router.php`, and checks the auto-refresh
# wiring. Never touches tracked data or a real tokens.json.
# Usage: bash brainsaw/tests/check_pages.sh [port]
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${1:-8765}"
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

cp -R "$SRC" "$TMP/brainsaw"
cd "$TMP/brainsaw"
printf '{"demo_site":{"token":"t","display_name":"Demo"},"never_site":{"token":"t2","display_name":"Never"}}' > tokens.json
cp tokens.json test-upload/tokens.json
mkdir -p test-upload/system_data/demo_site
cp system_data/demo_site/meta.json test-upload/system_data/demo_site/meta.json

php -S "localhost:$PORT" router.php >/dev/null 2>&1 &
SERVER_PID=$!
sleep 1

fail=0
check() { # description, command...
  local desc="$1"; shift
  if "$@"; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}
body_has()  { grep -q -- "$2" <<<"$1"; }
body_lacks() { ! grep -q -- "$2" <<<"$1"; }
# Any <meta http-equiv="refresh"> that is not wrapped in <noscript>.
no_bare_meta_refresh() { ! (grep 'http-equiv="refresh"' <<<"$1" | grep -qv '<noscript>'); }

for base in "" "test-upload/"; do
  label="${base:-root}"
  idx="$(curl -fsS "http://localhost:$PORT/${base}index.php")"
  site="$(curl -fsS "http://localhost:$PORT/${base}site.php?site=demo_site")"
  for pair in "index:$idx" "site:$site"; do
    name="${pair%%:*}"; html="${pair#*:}"
    check "$label $name: inlined script present"      body_has  "$html" 'function humanAgo'
    check "$label $name: no src= to autorefresh.js"   body_lacks "$html" 'src="js/autorefresh.js'
    check "$label $name: meta url attribute"          body_has  "$html" 'data-meta-url="system_data/demo_site/meta.json"'
    check "$label $name: uploaded-at attribute"       body_has  "$html" 'data-uploaded-at="20'
    check "$label $name: stale-after attribute"       body_has  "$html" 'data-stale-after="900"'
    check "$label $name: noscript meta refresh"       body_has  "$html" '<noscript><meta http-equiv="refresh" content="60"></noscript>'
    check "$label $name: no unconditional meta refresh" no_bare_meta_refresh "$html"
  done
  check "$label index: never-uploaded card has empty uploaded-at" body_has "$idx" 'data-uploaded-at=""'
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/${base}system_data/demo_site/meta.json")"
  check "$label meta.json returns 200" test "$code" = 200
done

exit "$fail"
