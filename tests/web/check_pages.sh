#!/usr/bin/env bash
# Renders the viewer pages from a throwaway copy of brainsaw/ (own tokens.json,
# only the demo_site data) served by `php -S ... router.php`, and checks the
# auto-refresh wiring. Never touches tracked data or a real tokens.json.
# Usage (from anywhere): tests/web/check_pages.sh [port]
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
lint_ok() { php -l "$1" >/dev/null; }

# GET a URL; on any curl failure print a FAIL line naming the URL and abort.
get() {
  local out
  if ! out="$(curl -fsS "$1" 2>&1)"; then echo "FAIL  GET $1 -> $out"; exit 1; fi
  printf '%s' "$out"
}
head_of() {
  local out
  if ! out="$(curl -fsS -D - -o /dev/null "$1" 2>&1)"; then echo "FAIL  GET $1 -> $out"; exit 1; fi
  tr -d '\r' <<<"$out"
}
meta_url_of() { sed -n 's/.*data-meta-url="\([^"]*\)".*/\1/p' <<<"$1" | head -n1; }

check "php -l lib.php" lint_ok "$SRC/lib.php"

if curl -s -o /dev/null "http://localhost:$PORT/"; then
  echo "FAIL  port $PORT is already in use; pass another port"; exit 1
fi

# Copy without secrets, logs or other sites' data (excluded during the copy,
# so they never exist in the temp dir): only demo_site's data is kept.
excludes=(--exclude=tokens.json --exclude=logs)
for d in "$SRC"/system_data/* "$SRC"/test-upload/system_data/*; do
  [ -e "$d" ] || continue
  [ "$d" = "$SRC/system_data/demo_site" ] && continue
  excludes+=("--exclude=${d#"$SRC"/}")
done
mkdir "$TMP/brainsaw"
tar -C "$SRC" "${excludes[@]}" -cf - . | tar -C "$TMP/brainsaw" -xf -
cd "$TMP/brainsaw"
mkdir -p logs
check "temp copy has no tokens.json" test ! -e tokens.json
check "temp copy has only demo_site data" test "$(ls system_data | tr -d '\n')" = demo_site

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

for base in "" "test-upload/"; do
  label="${base:-root}"
  idx="$(get "http://localhost:$PORT/${base}index.php")"
  site="$(get "http://localhost:$PORT/${base}site.php?site=demo_site")"
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
  never="$(get "http://localhost:$PORT/${base}site.php?site=never_site")"
  check "$label never-uploaded site: says no image yet"  body_has "$never" 'No image uploaded yet'
  check "$label never-uploaded site: meta url attribute" body_has "$never" 'data-meta-url="system_data/never_site/meta.json"'
  check "$label never-uploaded site: empty uploaded-at"  body_has "$never" 'data-uploaded-at=""'
  hdrs="$(head_of "http://localhost:$PORT/${base}index.php")"
  check "$label index: Cache-Control: no-store" body_has "$hdrs" 'Cache-Control: no-store'
  hdrs="$(head_of "http://localhost:$PORT/${base}site.php?site=demo_site")"
  check "$label site: Cache-Control: no-store" body_has "$hdrs" 'Cache-Control: no-store'
done

# A non-numeric stale_after_seconds must degrade to 900, not break the page.
mkdir badcfg
cp test-upload/index.php test-upload/site.php badcfg/
printf '<?php return array_merge(require __DIR__ . "/../test-upload/config.php", ["stale_after_seconds" => "abc"]);' > badcfg/config.php
for path in "index.php" "site.php?site=demo_site"; do
  html="$(get "http://localhost:$PORT/badcfg/${path}")"
  check "bad stale_after_seconds, $path: data-stale-after is 900" body_has "$html" 'data-stale-after="900"'
done

# Missing script: pages must fall back to an unconditional refresh, no empty <script>.
mv js/autorefresh.js js/autorefresh.js.off
for base in "" "test-upload/"; do
  label="${base:-root}"
  for path in "index.php" "site.php?site=demo_site"; do
    html="$(get "http://localhost:$PORT/${base}${path}")"
    check "$label $path (JS missing): unconditional meta refresh" has_bare_meta_refresh "$html"
    check "$label $path (JS missing): no inlined script"          body_lacks "$html" 'function humanAgo'
  done
done
mv js/autorefresh.js.off js/autorefresh.js

exit "$fail"
