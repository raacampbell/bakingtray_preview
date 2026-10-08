#!/usr/bin/env bash
# Serves a throwaway copy of brainsaw/ with `php -S ... router.php` and a temp settings file
# (two sites, two microscopes in one, a panopticon word; every name and token random) and
# checks the views, the 404 page, the asset route, uploads, settings validation and the
# auto-refresh wiring. The copy sits in a sub-folder of the server's document root, so the
# pages are also checked at a nested base path. Never touches tracked data or real settings.
# Usage (from anywhere): tests/web/check_pages.sh [port]
# Port: first argument, else $CHECK_PAGES_PORT, else 18765.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/brainsaw"
IMAGES="$ROOT/test_images"
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
# Any src/href/url() pointing at another host (absolute or protocol-relative).
no_third_party() { ! grep -qiE '(src|href)="(https?:)?//|url\((https?:)?//' <<<"$1"; }
lint_ok() { php -l "$1" >/dev/null; }

# fetch URL [curl args...]: sets STATUS, HEADERS (CR stripped) and BODY. Aborts if curl itself fails.
fetch() {
  local url="$1"; shift
  if ! STATUS="$(curl -sS -D "$TMP/h" -o "$TMP/b" -w '%{http_code}' "$@" "$url" 2>&1)"; then
    echo "FAIL  curl $url -> $STATUS" >&2; exit 1
  fi
  HEADERS="$(tr -d '\r' < "$TMP/h")"; BODY="$(cat "$TMP/b")"
}
header_of() { sed -n "s/^$1: //Ip" <<<"$HEADERS" | head -n1; }
attr_of() { sed -n "s/.*$1=\"\([^\"]*\)\".*/\1/p" <<<"$2" | head -n1; }
html_unescape() { sed 's/&amp;/\&/g'; }

# --- a temp copy of brainsaw/: tracked and new (not ignored) files only, never data or secrets ---
APP="$TMP/www/brainsaw"         # served as http://localhost:PORT/brainsaw/
mkdir -p "$APP"
while IFS= read -r -d '' f; do
  [ -f "$ROOT/$f" ] || continue   # tracked but deleted in the working tree
  mkdir -p "$TMP/www/$(dirname "$f")"
  cp "$ROOT/$f" "$TMP/www/$f"
done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard -- brainsaw)
mkdir -p "$APP/logs"
check "temp copy has no site data" test -z "$(find "$APP/system_data" -mindepth 1 -type d)"
check "temp copy has no log files"  test -z "$(find "$APP" -name '*.log')"
for f in "$SRC"/*.php; do check "php -l $(basename "$f")" lint_ok "$f"; done

# --- random settings: nothing here may look like anything in the repo ---
r() { openssl rand -hex "$1"; }
PAN="p$(r 6)"; SA="a$(r 5)"; SB="b$(r 5)"
MA1="m$(r 4)"; MB="k$(r 4)"
MA2="$((RANDOM + 1000))"     # all digits on purpose: PHP turns such a JSON key into an int
TA1="$(r 32)"; TA2="$(r 32)"; TB="$(r 32)"
SETTINGS="$TMP/www/brainsaw_settings.json"   # config.php default: next to brainsaw/
write_settings() { # panopticon word, site A id
  cat > "$SETTINGS" <<EOF
{"panopticon": "$1",
 "sites": {
  "$2": {"display_name": "Lab A $SA", "microscopes": {
     "$MA1": {"display_name": "Scope A1 $MA1", "token": "$TA1"},
     "$MA2": {"display_name": "Scope A2 $MA2", "token": "$TA2"}}},
  "$SB": {"display_name": "Lab B $SB", "microscopes": {
     "$MB": {"display_name": "Scope B $MB", "token": "$TB"}}}}}
EOF
}
write_settings "$PAN" "$SA"

# Microscope A1 has the four test files and a meta.json; A2 and B have never uploaded.
D="$APP/system_data/$SA/$MA1"
mkdir -p "$D"
cp "$IMAGES"/LastCompleteSection_01.jpg "$IMAGES"/montage.jpg "$IMAGES"/recipe_*.yml "$IMAGES"/acqLog_*.txt "$D/"
UPLOADED_AT="$(php -r 'echo gmdate("c", time() - 3600);')"   # old enough not to rate-limit A1
printf '{"uploaded_at":"%s"}' "$UPLOADED_AT" > "$D/meta.json"
RECIPE="$(basename "$D"/recipe_*.yml)"; ACQLOG="$(basename "$D"/acqLog_*.txt)"
STALE_AFTER="$(php -r '$c = require $argv[1]; echo (int) $c["stale_after_seconds"];' "$APP/config.php")"

if curl -s -o /dev/null "http://localhost:$PORT/"; then
  echo "FAIL  port $PORT is already in use; pass another port"; exit 1
fi
php -S "localhost:$PORT" -t "$TMP/www" "$APP/router.php" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
B="http://localhost:$PORT/brainsaw"
for _ in $(seq 1 50); do curl -s -o /dev/null "$B/" && break; sleep 0.2; done
curl -s -o /dev/null "$B/" || { echo "FAIL  server did not start within 10 s"; exit 1; }

# --- the one 404 response: every path that is not a view must give exactly this ---
fetch "$B/zz$(r 4)"
REF="$STATUS|$(header_of Content-Type)|$BODY"
check "unknown word: 404" test "$STATUS" = 404
same_404() { fetch "$1"; [ "$STATUS|$(header_of Content-Type)|$BODY" = "$REF" ]; }
for p in "no/such/page.html" "a/b/c/d" "$SA/nomic" "$SA/$MB" "$SB/$MA1" "$SA/$MA1/extra" \
         "$PAN/$SA" "$PAN/$SA/nomic" "$PAN/$SB/$MA1" "$PAN/$SA/$MA1/x" "$SA/$SA" \
         "$SA?f=main" "$PAN?f=meta" "$SA/$MA1?f=recipe" "$SA/$MA1?f=log" "$SA/$MA1?f=..%2Fmeta.json" \
         "$SA/$MA2?f=main" "$SA/$MA2?f=meta" "view.php" "$(tr a-z A-Z <<<"$SA")" "$SA%2F$MA1"; do
  check "identical 404: /$p" same_404 "$B/$p"
done

# --- landing page lists nothing ---
fetch "$B/"
check "landing: 200" test "$STATUS" = 200
check "landing: says Brainsaw" body_has "$BODY" "Brainsaw"
for s in "$PAN" "$SA" "$SB" "$MA1" "Lab A" "card"; do check "landing: lacks $s" body_lacks "$BODY" "$s"; done

# --- views ---
fetch "$B/$PAN";  PANO="$BODY"
check "panopticon: 200" test "$STATUS" = 200
for s in "Lab A $SA" "Lab B $SB" "Scope A1 $MA1" "Scope A2 $MA2" "Scope B $MB" \
         "href=\"/brainsaw/$PAN/$SA/$MA1\"" "href=\"/brainsaw/$PAN/$SB/$MB\""; do
  check "panopticon: has $s" body_has "$PANO" "$s"
done
fetch "$B/$SA"; SITEA="$BODY"
check "site A: 200" test "$STATUS" = 200
for s in "Lab A $SA" "Scope A1 $MA1" "Scope A2 $MA2" "href=\"/brainsaw/$SA/$MA1\"" "href=\"/brainsaw/$SA/$MA2\""; do
  check "site A: has $s" body_has "$SITEA" "$s"
done
for s in "$SB" "$MB" "$PAN"; do check "site A: lacks $s" body_lacks "$SITEA" "$s"; done
fetch "$B/$SB"
for s in "$SA" "$MA1" "$MA2" "$PAN"; do check "site B: lacks $s" body_lacks "$BODY" "$s"; done

for view in "$SA/$MA1" "$PAN/$SA/$MA1"; do
  fetch "$B/$view"; page="$BODY"
  check "/$view: 200" test "$STATUS" = 200
  check "/$view: main image" body_has "$page" 'id="main-image"'
  check "/$view: image through PHP" test "$(attr_of src "$(grep 'id="main-image"' <<<"$page")" | html_unescape | sed 's/&t=.*//')" = "/brainsaw/$view?f=main"
  check "/$view: montage link"      body_has "$page" "href=\"/brainsaw/$view?f=montage"
  check "/$view: meta url attribute" body_has "$page" "data-meta-url=\"/brainsaw/$view?f=meta\""
  check "/$view: self-hosted jQuery" body_has "$page" 'src="/brainsaw/js/jquery-3.7.1.min.js"'
  check "/$view: magnifier script"   body_has "$page" 'src="/brainsaw/js/jquery.imageLens.js"'
  check "/$view: section metadata"   body_has "$page" "Acquisition time per section"
  for f in main montage; do
    fetch "$B/$view?f=$f&t=1"
    check "/$view?f=$f: 200 image/jpeg" test "$STATUS $(header_of Content-Type)" = "200 image/jpeg"
  done
  fetch "$B/$view?f=main"
  check "/$view?f=main: the uploaded bytes" cmp -s "$TMP/b" "$D/LastCompleteSection_01.jpg"
  fetch "$B/$view?f=meta&t=123"
  check "/$view?f=meta: 200 application/json" test "$STATUS $(header_of Content-Type)" = "200 application/json"
  check "/$view?f=meta: no-store" test "$(header_of Cache-Control)" = "no-store"
  check "/$view?f=meta: the meta.json" test "$BODY" = "$(cat "$D/meta.json")"
done
fetch "$B/$SA/$MA2"
check "never-uploaded microscope: says no image yet" body_has "$BODY" 'No image uploaded yet'
check "never-uploaded microscope: empty uploaded-at" body_has "$BODY" 'data-uploaded-at=""'

# --- headers and HTML of every kind of view response ---
for p in "$PAN" "$SA" "$SA/$MA1" "$PAN/$SB/$MB" "$SA/$MA1?f=main" "$SA/$MA1?f=meta" "zz$(r 3)" "a/b/c/d"; do
  fetch "$B/$p"
  check "/$p: Referrer-Policy no-referrer" test "$(header_of Referrer-Policy)" = "no-referrer"
  check "/$p: X-Robots-Tag noindex"        test "$(header_of X-Robots-Tag)" = "noindex, nofollow"
  case "$(header_of Content-Type)" in
    text/html*)
      check "/$p: robots meta"          body_has "$BODY" '<meta name="robots" content="noindex, nofollow">'
      check "/$p: no third-party URL"   no_third_party "$BODY" ;;
  esac
done

# --- auto-refresh wiring (the JS reads only these attributes) ---
fetch "$B/$SA";      grid="$BODY"
fetch "$B/$SA/$MA1"; micpage="$BODY"
for pair in "grid:$grid" "microscope:$micpage"; do
  name="${pair%%:*}"; html="${pair#*:}"
  check "$name: inlined script present"        body_has  "$html" 'function humanAgo'
  check "$name: no src= to autorefresh.js"     body_lacks "$html" 'autorefresh.js"'
  check "$name: uploaded-at equals meta.json"  body_has  "$html" "data-uploaded-at=\"$UPLOADED_AT\""
  check "$name: stale-after equals config"     body_has  "$html" "data-stale-after=\"$STALE_AFTER\""
  check "$name: server-now on body"            body_has  "$html" '<body data-server-now="'
  check "$name: noscript meta refresh"         body_has  "$html" '<noscript><meta http-equiv="refresh" content="60"></noscript>'
  check "$name: no unconditional meta refresh" no_bare_meta_refresh "$html"
  url="$(attr_of data-meta-url "$html" | html_unescape)"
  fetch "http://localhost:$PORT${url}&t=1"     # what fetchUploadedAt() requests
  check "$name: embedded meta URL returns 200" test "$STATUS" = 200
done
fetch "$B/$SA"
check "grid: Cache-Control no-store" test "$(header_of Cache-Control)" = "no-store"

# An invalid stale_after_seconds (PHP literal) must degrade to 900, not break the page.
mv "$APP/config.php" "$APP/config.orig.php"
for bad in "'abc'" 0 -5 0.5; do
  printf '<?php return array_merge(require __DIR__ . "/config.orig.php", ["stale_after_seconds" => %s]);' "$bad" > "$APP/config.php"
  for p in "$SA" "$SA/$MA1"; do
    fetch "$B/$p"
    check "stale_after_seconds=$bad, /$p: data-stale-after is 900" body_has "$BODY" 'data-stale-after="900"'
  done
done
mv "$APP/config.orig.php" "$APP/config.php"

# Missing script: pages fall back to an unconditional refresh, no empty <script>.
mv "$APP/js/autorefresh.js" "$APP/js/autorefresh.js.off"
for p in "$SA" "$SA/$MA1"; do
  fetch "$B/$p"
  check "/$p (JS missing): unconditional meta refresh" has_bare_meta_refresh "$BODY"
  check "/$p (JS missing): no inlined script"          body_lacks "$BODY" 'function humanAgo'
done
mv "$APP/js/autorefresh.js.off" "$APP/js/autorefresh.js"

# --- nothing private is served directly ---
not_200() { fetch "$1" --path-as-is; [ "$STATUS" != 200 ]; }   # keep ../ as sent
for p in "system_data/" "system_data/$SA/$MA1/meta.json" "system_data/$SA/$MA1/LastCompleteSection_01.jpg" \
         "system_data/$SA/$MA1/montage.jpg" "system_data/$SA/$MA1/$RECIPE" "system_data/$SA/$MA1/$ACQLOG" \
         "System_Data/$SA/$MA1/meta.json" "js/../system_data/$SA/$MA1/meta.json" "logs/" ".htaccess"; do
  check "direct /$p refused" not_200 "$B/$p"
done
check "settings file next to brainsaw/ not served" not_200 "http://localhost:$PORT/brainsaw_settings.json"
check "settings file via the app folder not served" not_200 "$B/../brainsaw_settings.json"

# --- uploads ---
ZIP="$IMAGES/all_data.zip"
U="$B/upload.php"
hdr() { printf 'Authorization: Bearer %s' "$1"; }   # tokens are random test values
fetch "$U"
check "GET upload.php: 405" test "$STATUS" = 405
fetch "$U" -X POST -F site_id="$SB" -F microscope_id="$MB" -F "data=@$ZIP;type=application/zip"
check "upload without token: 401" test "$STATUS" = 401
fetch "$U" -X POST -H "$(hdr "$TB")" -F site_id="$SB" -F "data=@$ZIP;type=application/zip"
check "upload without microscope_id: 403" test "$STATUS" = 403
NOMIC="$BODY"
fetch "$U" -X POST -H "$(hdr "$TB")" -F site_id="nosite" -F microscope_id="$MB" -F "data=@$ZIP;type=application/zip"
check "unknown site: 403" test "$STATUS" = 403
UNKSITE="$BODY"
fetch "$U" -X POST -H "$(hdr "$TB")" -F site_id="$SB" -F microscope_id="nomic" -F "data=@$ZIP;type=application/zip"
check "unknown microscope: 403" test "$STATUS" = 403
check "unknown site and unknown microscope: same message" test "$BODY" = "$UNKSITE"
check "missing microscope_id: same message" test "$NOMIC" = "$UNKSITE"
fetch "$U" -X POST -H "$(hdr "$TA1")" -F site_id="$SB" -F microscope_id="$MB" -F "data=@$ZIP;type=application/zip"
check "another microscope's token: 403" test "$STATUS" = 403
check "wrong token: same message" test "$BODY" = "$UNKSITE"
fetch "$U" -X POST -H "$(hdr "$TB")" -F site_id="$SB" -F microscope_id="$MB" -F "image=@$IMAGES/montage.jpg;type=image/jpeg"
check "legacy single-image upload: 400" test "$STATUS" = 400
fetch "$U" -X POST -H "$(hdr "$TB")" -F site_id="$SB" -F microscope_id="$MB" -F "data=@$ZIP;type=application/zip"
check "valid upload: 200 ok" body_has "$STATUS $BODY" '200 {"status":"ok"'
check "upload lands in system_data/<site>/<mic>/" test -f "$APP/system_data/$SB/$MB/LastCompleteSection_01.jpg" -a -f "$APP/system_data/$SB/$MB/meta.json"
check "nothing written to system_data/<site>/ itself" test -z "$(find "$APP/system_data/$SB" -maxdepth 1 -type f)"
fetch "$U" -X POST -H "$(hdr "$TB")" -F site_id="$SB" -F microscope_id="$MB" -F "data=@$ZIP;type=application/zip"
check "second upload within 5 s: 429" test "$STATUS" = 429
fetch "$U" -X POST -H "$(hdr "$TA2")" -F site_id="$SA" -F microscope_id="$MA2" -F "data=@$ZIP;type=application/zip"
check "all-digit microscope ID: upload 200" test "$STATUS" = 200
fetch "$U" -X POST -H "$(hdr "$TA1")" -F site_id="$SA" -F microscope_id="$MA1" -F "data=@$ZIP;type=application/zip"
check "rate limit is per microscope (A1 right after A2): 200" test "$STATUS" = 200
fetch "$B/$SB/$MB"
check "uploaded microscope page shows its image" body_has "$BODY" 'id="main-image"'
fetch "$B/$PAN/$SA/$MA2?f=main"
check "all-digit microscope ID: image served" test "$STATUS" = 200

# --- the Authorization header is found under every name a host may use ---
auth_of() { php -r 'require $argv[1]; echo bs_authorization_header(json_decode($argv[2], true));' "$APP/lib.php" "$1"; }
check "auth from HTTP_AUTHORIZATION"          test "$(auth_of '{"HTTP_AUTHORIZATION":"Bearer x"}')" = "Bearer x"
check "auth from REDIRECT_HTTP_AUTHORIZATION" test "$(auth_of '{"HTTP_AUTHORIZATION":"","REDIRECT_HTTP_AUTHORIZATION":"Bearer y"}')" = "Bearer y"
check "auth absent"                           test -z "$(auth_of '{}')"

# --- settings validation: collisions and bad values are rejected ---
# Prints "ok" for a valid file, else the reason. Reserved names are the app folder's entries.
validate() { php -r 'require $argv[1]; echo bs_validate_settings(json_decode($argv[2], true), bs_reserved_names()) ?? "ok";' "$APP/lib.php" "$1"; }
mic='{"m": {"token": "t"}}'
# JSON goes through variables: escaped quotes inside "$(...)" are mangled by bash 3.2.
good="{\"panopticon\":\"w\",\"sites\":{\"s\":{\"microscopes\":$mic},\"t\":{\"microscopes\":$mic}}}"
check "valid settings accepted"        test "$(validate "$good")" = ok
good="{\"sites\":{\"s\":{\"microscopes\":$mic}}}"
check "no panopticon is allowed"       test "$(validate "$good")" = ok
for bad in \
  "{\"panopticon\":\"s\",\"sites\":{\"s\":{\"microscopes\":$mic}}}" \
  "{\"panopticon\":\"S\",\"sites\":{\"s\":{\"microscopes\":$mic}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"microscopes\":$mic},\"S\":{\"microscopes\":$mic}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"js\":{\"microscopes\":$mic}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"System_Data\":{\"microscopes\":$mic}}}" \
  "{\"panopticon\":\"logs\",\"sites\":{\"s\":{\"microscopes\":$mic}}}" \
  "{\"panopticon\":\"Upload.php\",\"sites\":{\"s\":{\"microscopes\":$mic}}}" \
  "{\"panopticon\":\"w w\",\"sites\":{\"s\":{\"microscopes\":$mic}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s.x\":{\"microscopes\":$mic}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"microscopes\":{\"m/1\":{\"token\":\"t\"}}}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"microscopes\":{\"m\":{\"token\":\"\"}}}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"microscopes\":{\"m\":{}}}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"microscopes\":[{\"token\":\"t\"}]}}}" \
  "{\"panopticon\":5,\"sites\":{\"s\":{\"microscopes\":$mic}}}" \
  "[1,2]"; do
  why="$(validate "$bad")"
  check "rejected ($why): $bad" test "$why" != ok
done

# A colliding settings file is treated as empty: every view 404s, uploads 403, no details leak.
write_settings "$SA" "$SA"
check "collision: site view 404s like any missing page" same_404 "$B/$SA"
fetch "$U" -X POST -H "$(hdr "$TB")" -F site_id="$SB" -F microscope_id="$MB" -F "data=@$ZIP;type=application/zip"
check "collision: upload 403" test "$STATUS" = 403
check "collision: same message as an unknown site" test "$BODY" = "$UNKSITE"
check "collision: logged on the server" grep -q 'brainsaw: invalid settings file' "$TMP/server.log"
echo '{not json' > "$SETTINGS"
check "unparsable settings: 404" same_404 "$B/$SB"
rm "$SETTINGS"
check "missing settings: 404" same_404 "$B/$SB"
write_settings "$PAN" "$SA"
check "restored settings: site view 200" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' '$B/$SA')\" = 200 ]"

# --- no test word, site ID or token appears in any tracked file ---
check "no test settings value in tracked files" \
  bash -c '! git -C "$1" grep -qF -e "$2" -e "$3" -e "$4" -e "$5" -e "$6" -e "$7" -- .' _ "$ROOT" "$PAN" "$SA" "$SB" "$TA1" "$TA2" "$TB"

exit "$fail"
