#!/usr/bin/env bash
# Serves a throwaway copy of brainsaw/ with `php -S ... router.php` and a temp settings file
# (two sites with one token each, eighteen microscopes in all, a panopticon word; every name and
# token random) and
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
MD1="d$(r 4)"; MD2="e$(r 4)"; MD3="f$(r 4)"; MD4="g$(r 4)"; MD5="h$(r 4)"; MD6="i$(r 4)"; MD7="j$(r 4)"; MD8="o$(r 4)"; MD9="q$(r 4)"; MT="t$(r 4)"; MTA="u$(r 4)"; ML="l$(r 4)"; MW="v$(r 4)"   # one microscope per display-rule case; MT, MTA: thumbnails; ML: the lag rule; MW: start-of-run wipe
MA1="m$(r 4)"; MA2="n$(r 4)"; MB="k$(r 4)"; MSPACE="Scope_$(r 3)"   # MSPACE: its recipe says "Scope <hex>"
TKA="$(r 32)"; TKB="$(r 32)"; TOLD="$(r 32)"   # one token per site; TOLD stands for a per-microscope token of the old format
SETTINGS="$TMP/www/brainsaw_settings.json"   # config.php default: next to brainsaw/
write_settings() { # panopticon word, site A id
  cat > "$SETTINGS" <<EOF
{"panopticon": "$1",
 "sites": {
  "$2": {"display_name": "Lab A $SA", "token": "$TKA", "microscopes": {
     "$MA1": {"display_name": "Scope A1 $MA1"},
     "$MA2": {"display_name": "Scope A2 $MA2"},
     "$MSPACE": {"display_name": "Scope with a space"},
     "$MD1": {}, "$MD2": {}, "$MD3": {}, "$MD4": {}, "$MD5": {}, "$MD6": {}, "$MD7": {}, "$MD8": {}, "$MD9": {}, "$MT": {}, "$MTA": {}, "$ML": {}, "$MW": {}}},
  "$SB": {"display_name": "Lab B $SB", "token": "$TKB", "microscopes": {
     "$MB": {"display_name": "Scope B $MB"},
     "logs": {}}}}}
EOF
}
write_settings "$PAN" "$SA"

# Microscope A1 has the four test files and a meta.json in its acq folder; A2 and B have never uploaded.
D="$APP/system_data/$SA/$MA1/acq"
mkdir -p "$D"
cp "$IMAGES/LastCompleteSection_01.jpg" "$D/LastCompleteSection.jpg"
cp "$IMAGES/montage.jpg" "$D/montage.jpg"
cp "$IMAGES"/recipe_*.yml "$D/recipe.yml"
cp "$IMAGES"/acqLog_*.txt "$D/acqLog.txt"
UPLOADED_AT="$(php -r 'echo gmdate("c", time() - 3600);')"   # old enough not to rate-limit A1
printf '{"uploaded_at":"%s"}' "$UPLOADED_AT" > "$D/meta.json"
RECIPE=recipe.yml; ACQLOG=acqLog.txt
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
# Signature of a response: status, every header except Date, and the body.
sig() { printf '%s\n%s\n%s' "$STATUS" "$HEADERS" "$BODY" | tr -d '\r' | grep -v '^Date:'; }
fetch "$B/zz$(r 4)";    REF="$(sig)"
check "unknown word: 404" test "$STATUS" = 404
fetch "$B/zz$(r 4)" -I; REF_HEAD="$(sig)"
check "unknown word, HEAD: 404" test "$STATUS" = 404
same_404()  { fetch "$1";    [ "$(sig)" = "$REF" ]; }
same_head() { fetch "$1" -I; [ "$(sig)" = "$REF_HEAD" ]; }
for p in "no/such/page.html" "a/b/c/d" "$SA/nomic" "$SA/$MB" "$SB/$MA1" "$SA/$MA1/extra" \
         "$PAN/$SA" "$PAN/$SA/nomic" "$PAN/$SB/$MA1" "$PAN/$SA/$MA1/x" "$SA/$SA" "$SA/" "$PAN/" "$SA/$MA1/" \
         "12345" "$SA/12345" "$SA?f=main" "$PAN?f=meta" "$SA/$MA1?f=recipe" "$SA/$MA1?f=log" \
         "$SA/$MA1?f=..%2Fmeta.json" "$SA/$MA2?f=main" "$SA/$MA2?f=meta" "view.php" \
         "$(tr a-z A-Z <<<"$SA")" "$SA%2F$MA1"; do
  check "identical 404: /$p" same_404 "$B/$p"
  check "identical 404 (HEAD): /$p" same_head "$B/$p"
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
for p in "$SB/logs" "$PAN/$SB/logs"; do  # "logs" is reserved only as a first segment
  fetch "$B/$p"
  check "microscope named logs: /$p is 200" test "$STATUS" = 200
done

for view in "$SA/$MA1" "$PAN/$SA/$MA1"; do
  fetch "$B/$view"; page="$BODY"
  check "/$view: 200" test "$STATUS" = 200
  check "/$view: main image" body_has "$page" 'id="main-image"'
  check "/$view: image through PHP" test "$(attr_of src "$(grep 'id="main-image"' <<<"$page")" | html_unescape | sed 's/&v=.*//')" = "/brainsaw/$view?f=main"
  check "/$view: acq only, no thumbnails or montage" body_lacks "$page" 'id="thumb-'
  check "/$view: meta url attribute" body_has "$page" "data-meta-url=\"/brainsaw/$view?f=meta\""
  check "/$view: self-hosted jQuery" body_has "$page" 'src="/brainsaw/js/jquery-3.7.1.min.js"'
  check "/$view: magnifier script"   body_has "$page" 'src="/brainsaw/js/jquery.imageLens.js"'
  check "/$view: section metadata"   body_has "$page" "Acquisition time per section"
  for f in main bakingtray; do
    fetch "$B/$view?f=$f&t=1"
    check "/$view?f=$f: 200 image/jpeg" test "$STATUS $(header_of Content-Type)" = "200 image/jpeg"
    check "/$view?f=$f: the uploaded bytes" cmp -s "$TMP/b" "$D/LastCompleteSection.jpg"
  done
  check "/$view?f=montage: the acq montage is not shown, so 404" same_404 "$B/$view?f=montage"
  fetch "$B/$view?f=meta&t=123"
  check "/$view?f=meta: 200 application/json" test "$STATUS $(header_of Content-Type)" = "200 application/json"
  check "/$view?f=meta: no-store" test "$(header_of Cache-Control)" = "no-store"
  check "/$view?f=meta: only the version" test "$BODY" = "{\"version\":\"acq=$UPLOADED_AT\"}"
done

# --- image caching: a versioned URL may be cached for good; a new upload gives a new URL ---
main_src() { fetch "$B/$SA/$MA1"; attr_of src "$(grep 'id="main-image"' <<<"$BODY")" | html_unescape; }
SRC1="$(main_src)"
check "caching: image URL carries a version" grep -qE '\?f=main&v=[0-9a-f]{16}$' <<<"$SRC1"
fetch "http://localhost:$PORT$SRC1"
check "caching: versioned image is cacheable" test "$(header_of Cache-Control)" = "private, max-age=31536000, immutable"
ETAG="$(header_of ETag)"
check "caching: ETag is the version" test "$ETAG" = "\"${SRC1##*&v=}\""
fetch "$B/$SA/$MA1?f=main&v=0123456789abcdef"
check "caching: wrong version must be revalidated" test "$(header_of Cache-Control)" = "private, no-cache"
check "caching: wrong version still gets the image" cmp -s "$TMP/b" "$D/LastCompleteSection.jpg"
fetch "$B/$SA/$MA1?f=main"
check "caching: unversioned must be revalidated" test "$(header_of Cache-Control)" = "private, no-cache"
: > "$TMP/b"   # curl leaves the file untouched when the body is empty
fetch "http://localhost:$PORT$SRC1" -H "If-None-Match: $ETAG"
check "caching: If-None-Match with the version gives 304, no body" test "$STATUS:${#BODY}" = "304:0"
cp "$D/LastCompleteSection.jpg" "$TMP/orig.jpg"
cp "$IMAGES/montage.jpg" "$D/LastCompleteSection.jpg"   # stands for a new upload
SRC2="$(main_src)"
check "caching: a new image gives a new URL" test "$SRC2" != "$SRC1"
fetch "http://localhost:$PORT$SRC1" -H "If-None-Match: $ETAG"
check "caching: the old ETag no longer gives 304" test "$STATUS" = 200
check "caching: ... and the new bytes are sent" cmp -s "$TMP/b" "$IMAGES/montage.jpg"
check "caching: ... under an old URL, revalidated" test "$(header_of Cache-Control)" = "private, no-cache"
cp "$TMP/orig.jpg" "$D/LastCompleteSection.jpg"
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
  check "$name: version names the displayed source" body_has "$html" "data-version=\"acq=$UPLOADED_AT\""
  check "$name: not finished"                  body_has  "$html" 'data-finished="0"'
  check "$name: stale-after equals config"     body_has  "$html" "data-stale-after=\"$STALE_AFTER\""
  check "$name: server-now on body"            body_has  "$html" '<body data-server-now="'
  check "$name: noscript meta refresh"         body_has  "$html" '<noscript><meta http-equiv="refresh" content="60"></noscript>'
  check "$name: no unconditional meta refresh" no_bare_meta_refresh "$html"
  url="$(attr_of data-meta-url "$html" | html_unescape)"
  fetch "http://localhost:$PORT${url}&t=1"     # what fetchVersion() requests
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
for p in "system_data/" "system_data/$SA/$MA1/acq/meta.json" "system_data/$SA/$MA1/acq/LastCompleteSection.jpg" \
         "system_data/$SA/$MA1/acq/montage.jpg" "system_data/$SA/$MA1/acq/$RECIPE" "system_data/$SA/$MA1/acq/$ACQLOG" \
         "System_Data/$SA/$MA1/acq/meta.json" "js/../system_data/$SA/$MA1/acq/meta.json" "/system_data/$SA/$MA1/acq/meta.json" \
         "logs/" ".htaccess" "lib.php" "config.php" "router.php" "x.json" "js/x.php"; do
  check "direct /$p refused" not_200 "$B/$p"
done
check "settings file next to brainsaw/ not served" not_200 "http://localhost:$PORT/brainsaw_settings.json"
check "settings file via the app folder not served" not_200 "$B/../brainsaw_settings.json"

# --- the URL base comes from DOCUMENT_ROOT, and fails closed outside it ---
base_of() { php -r '$_SERVER["DOCUMENT_ROOT"] = $argv[2]; require $argv[1]; var_export(bs_base_path());' "$APP/lib.php" "$1" 2>/dev/null; }
check "base path below the document root"     test "$(base_of "$TMP/www")" = "'/brainsaw'"
check "base path at the document root"        test "$(base_of "$APP")" = "''"
check "app outside the document root: null"   test "$(base_of "$IMAGES")" = "NULL"
check "no document root: null"                test "$(base_of "")" = "NULL"

# --- uploads ---
U="$B/upload.php"
hdr() { printf 'Authorization: Bearer %s' "$1"; }   # tokens are random test values
# upload TOKEN SITE MIC SOURCE ZIP: one contract-conforming POST; sets STATUS and BODY.
upload() { fetch "$U" -X POST -H "$(hdr "$1")" -F site_id="$2" -F microscope_id="$3" -F source="$4" -F "data=@$5;type=application/zip"; }

# Zips are built from real-format recipes: the test recipe with SYSTEM.ID and sample.ID replaced.
# new_dir NAME SYSTEM_ID SAMPLE_ID: $TMP/z/NAME holds the five uploadable files ("-" as the
# sample ID removes it from the recipe). zip_dir NAME: $TMP/z/NAME.zip from that folder.
new_dir() {
  local d="$TMP/z/$1"; rm -rf "$d" "$d.zip"; mkdir -p "$d"
  cp "$IMAGES/LastCompleteSection_01.jpg" "$d/LastCompleteSection.jpg"
  cp "$IMAGES/montage.jpg" "$d/"; cp "$IMAGES"/acqLog_*.txt "$d/acqLog.txt"
  local sample; if [ "$3" = "-" ]; then sample='sample: {objectiveName: nikon 16x}'; else sample="sample: {ID: $3, objectiveName: nikon 16x}"; fi
  LC_ALL=C sed -e "s/^sample: .*/$sample/" -e "s/^  ID: brainsaw/  ID: $2/" "$IMAGES"/recipe_*.yml > "$d/recipe.yml"
  echo '{"finished": false, "extra_key": 1}' > "$d/status.json"
}
zip_dir() { rm -f "$TMP/z/$1.zip"; (cd "$TMP/z/$1" && zip -q -r -X "../$1.zip" .); }
good_zip() { new_dir "$1" "$2" "$3"; zip_dir "$1"; }   # NAME SYSTEM_ID SAMPLE_ID
# Content fingerprint of a folder (names and bytes), to show a refused upload changed nothing.
snapshot() { (cd "$1" && find . -type f -exec cksum {} + | sort); }
# Make the last upload to FOLDER look SECONDS old (default 3600), so the 5 s rate limit lets the next one in.
backdate() { php -r '$f = $argv[1] . "/meta.json"; $m = json_decode(file_get_contents($f), true); $m["uploaded_at"] = gmdate("c", time() - (int) $argv[2]); file_put_contents($f, json_encode($m));' "$1" "${2:-3600}"; }
meta_of() { php -r '$m = json_decode(file_get_contents($argv[1] . "/meta.json"), true); echo $m[$argv[2]] ?? "";' "$1" "$2"; }

good_zip main "$MB" S1
ZIP="$TMP/z/main.zip"
fetch "$U"
check "GET upload.php: 405" test "$STATUS" = 405
fetch "$U" -X POST -F site_id="$SB" -F microscope_id="$MB" -F source=acq -F "data=@$ZIP;type=application/zip"
check "upload without token: 401" test "$STATUS" = 401
fetch "$U" -X POST -H "$(hdr "$TKB")" -F site_id="$SB" -F source=acq -F "data=@$ZIP;type=application/zip"
check "upload without microscope_id: 403" test "$STATUS" = 403
NOMIC="$BODY"
upload "$TKB" nosite "$MB" acq "$ZIP"
check "unknown site: 403" test "$STATUS" = 403
UNKSITE="$BODY"
upload "$TKB" "$SB" nomic acq "$ZIP"
check "unlisted microscope: 403" test "$STATUS" = 403
check "unknown site and unlisted microscope: same message" test "$BODY" = "$UNKSITE"
check "missing microscope_id: same message" test "$NOMIC" = "$UNKSITE"
upload "$TOLD" "$SB" "$MB" acq "$ZIP"
check "an old per-microscope token: 403" test "$STATUS" = 403
check "old per-microscope token: same message" test "$BODY" = "$UNKSITE"
upload "$TKA" "$SB" "$MB" acq "$ZIP"
check "another site's token: 403" test "$STATUS" = 403
check "another site's token: same message" test "$BODY" = "$UNKSITE"
upload "$TKB" "$SB" "$MB" nonsense "$ZIP"
check "bad source with a good token: 400" test "$STATUS" = 400
upload "$TOLD" "$SB" "$MB" nonsense "$ZIP"
check "bad source with a bad token: 403, the source is not looked at" test "$STATUS" = 403
for src in ACQ "" analysis2 "../acq"; do
  upload "$TKB" "$SB" "$MB" "$src" "$ZIP"
  check "source '$src': 400" test "$STATUS" = 400
done
for src in "acq%20" "acq%0A"; do   # form-urlencoded, because curl -F trims trailing spaces
  fetch "$U" -X POST -H "$(hdr "$TKB")" -d "site_id=$SB&microscope_id=$MB&source=$src"
  check "source '$src': 400" test "$STATUS" = 400
done
fetch "$U" -X POST -H "$(hdr "$TKB")" -F site_id="$SB" -F microscope_id="$MB" -F "data=@$ZIP;type=application/zip"
check "missing source: 400" test "$STATUS" = 400
check "refused uploads created no folder" test ! -e "$APP/system_data/$SB/$MB/acq"
fetch "$U" -X POST -H "$(hdr "$TKB")" -F site_id="$SB" -F microscope_id="$MB" -F source=acq -F "image=@$IMAGES/montage.jpg;type=image/jpeg"
check "no data field: 400" test "$STATUS" = 400
# Raw IDs never reach the log: a newline/tab payload must not forge a log line.
LOG="$APP/logs/upload.log"
lines="$(wc -l < "$LOG")"
fetch "$U" -X POST -H "$(hdr "$TKB")" -F "site_id=$(printf 'x\nFAKE\tLINE')" -F microscope_id="$MB" -F source=acq
check "bad site_id: 403" test "$STATUS" = 403
check "bad site_id: exactly one log line" test "$(wc -l < "$LOG")" -eq $((lines + 1))
check "bad site_id: payload not logged" bash -c '! grep -q FAKE "$1"' _ "$LOG"
check "bad site_id: logged as ?" bash -c 'tail -n1 "$1" | cut -f2 | grep -qx "?"' _ "$LOG"
# Form-urlencoded, because PHP's multipart parser drops a trailing newline before we see it.
for id in "12345" "$SB%0A"; do
  fetch "$U" -X POST -H "$(hdr "$TKB")" -d "site_id=$id&microscope_id=$MB&source=acq"
  check "site_id $id (all digits / trailing newline): 403" test "$STATUS" = 403
done

# Accepted uploads: acq, then analysis straight after (the rate limit is per source).
MBD="$APP/system_data/$SB/$MB"
upload "$TKB" "$SB" "$MB" acq "$ZIP"
check "valid acq upload: 200 ok" body_has "$STATUS $BODY" '200 {"status":"ok"'
check "acq upload lands in system_data/<site>/<mic>/acq/" test -f "$MBD/acq/recipe.yml" -a -f "$MBD/acq/status.json" -a -f "$MBD/acq/meta.json"
check "meta.json holds the sample ID" test "$(meta_of "$MBD/acq" sample_id)" = S1
check "meta.json holds uploaded_at" test -n "$(meta_of "$MBD/acq" uploaded_at)"
check "nothing written to system_data/<site>/<mic>/ itself but lock files" test -z "$(find "$MBD" -maxdepth 1 -type f ! -name '.lock-*')"
check "nothing written to system_data/<site>/ itself" test -z "$(find "$APP/system_data/$SB" -maxdepth 1 -type f)"
check "no temporary folder left behind" test -z "$(find "$MBD" -name '.tmp-*')"
check "the upload log records the source" bash -c 'tail -n1 "$1" | cut -f2 | grep -qx "$2"' _ "$LOG" "$SB/$MB/acq"
upload "$TKB" "$SB" "$MB" acq "$ZIP"
check "second acq upload within 5 s: 429" test "$STATUS" = 429
upload "$TKB" "$SB" "$MB" analysis "$ZIP"
check "analysis upload right after acq: 200, not 429" test "$STATUS" = 200
check "analysis upload lands in .../analysis/" test -f "$MBD/analysis/recipe.yml" -a -f "$MBD/analysis/meta.json"
upload "$TKB" "$SB" "$MB" analysis "$ZIP"
check "second analysis upload within 5 s: 429" test "$STATUS" = 429
check "the upload log records the analysis source" bash -c 'grep -q "$2" "$1"' _ "$LOG" "$SB/$MB/analysis"
fetch "$B/$SB/$MB"
check "uploaded microscope page shows its acq image" body_has "$BODY" 'id="main-image"'

# Refused uploads: 400, and the stored folders stay exactly as they were. Each zip has a NEW
# sample ID, so a check run after the folder was emptied would show.
backdate "$MBD/acq"; backdate "$MBD/analysis"
BEFORE_ACQ="$(snapshot "$MBD/acq")"; BEFORE_AN="$(snapshot "$MBD/analysis")"
refused() { # description, zip name, expected status (default 400)
  upload "$TKB" "$SB" "$MB" acq "$TMP/z/$2.zip"
  check "$1: ${3:-400}" test "$STATUS" = "${3:-400}"
  check "$1: acq folder untouched" test "$(snapshot "$MBD/acq")" = "$BEFORE_ACQ"
  check "$1: analysis folder untouched" test "$(snapshot "$MBD/analysis")" = "$BEFORE_AN"
}
new_dir norecipe "$MB" S2;     rm "$TMP/z/norecipe/recipe.yml";     zip_dir norecipe;     refused "missing recipe.yml" norecipe
new_dir nostatus "$MB" S2;     rm "$TMP/z/nostatus/status.json";    zip_dir nostatus;     refused "missing status.json" nostatus
for bad in 'not json' '[]' '{}' '[true]' '"finished"' '{"finished": "true"}' '{"finished": 1}' '{"finished": null}' '{"Finished": true}'; do
  new_dir badstatus "$MB" S2; printf '%s' "$bad" > "$TMP/z/badstatus/status.json"; zip_dir badstatus
  refused "status.json $bad" badstatus
done
mkdir "$MBD/.tmp-stale"; touch -t 200001010000 "$MBD/.tmp-stale"   # left by a killed upload
good_zip wrongid "other_scope" S2;                                refused "SYSTEM.ID differs from microscope_id" wrongid
check "a temporary folder over an hour old is swept" test ! -e "$MBD/.tmp-stale"
good_zip nosample "$MB" -;                                        refused "recipe without sample.ID" nosample
good_zip badutf "$MB" "$(printf 'S\377x')";                       refused "sample ID that is not UTF-8" badutf
new_dir dup "$MB" S2; mkdir "$TMP/z/dup/sub"; cp "$TMP/z/dup/recipe.yml" "$TMP/z/dup/sub/"; zip_dir dup
refused "two entries with the same base name" dup
new_dir big "$MB" S2; head -c 3000000 /dev/zero | tr '\0' 'a' >> "$TMP/z/big/recipe.yml"; zip_dir big
refused "recipe.yml over the size cap" big 413
check "refused uploads leave no temporary folder" test -z "$(find "$MBD" -name '.tmp-*')"
fetch "$U" -X POST -H "$(hdr "$TKB")" -F site_id="$SB" -F microscope_id="$MB" -F source=acq -F "data=@$IMAGES/montage.jpg;type=application/zip;filename=x.zip"
check "not a zip: 415, acq folder untouched" test "$STATUS $(snapshot "$MBD/acq")" = "415 $BEFORE_ACQ"

# A new sample empties only that source's folder.
new_dir s2 "$MB" S2; rm "$TMP/z/s2/acqLog.txt" "$TMP/z/s2/LastCompleteSection.jpg"; echo '{"finished": true}' > "$TMP/z/s2/status.json"; zip_dir s2
# s2 and s2b send no image, so with finished:false they would be start-of-run calls that also empty analysis/.
# They send finished:true (an end-of-run call) so that only the sample-ID rule and the merge are tested here.
upload "$TKB" "$SB" "$MB" acq "$TMP/z/s2.zip"
check "new sample, acq: 200" test "$STATUS" = 200
check "new sample: old acq files gone" test ! -e "$MBD/acq/acqLog.txt" -a ! -e "$MBD/acq/LastCompleteSection.jpg"
check "new sample: new acq files present" test -f "$MBD/acq/recipe.yml" -a -f "$MBD/acq/montage.jpg"
check "new sample: meta.json has the new sample ID" test "$(meta_of "$MBD/acq" sample_id)" = S2
check "new sample in acq: analysis folder untouched" test "$(snapshot "$MBD/analysis")" = "$BEFORE_AN"
# The same sample merges: files not in this upload stay.
backdate "$MBD/acq"
new_dir s2b "$MB" S2; rm "$TMP/z/s2b/montage.jpg" "$TMP/z/s2b/LastCompleteSection.jpg"; echo '{"finished": true}' > "$TMP/z/s2b/status.json"; zip_dir s2b
upload "$TKB" "$SB" "$MB" acq "$TMP/z/s2b.zip"
check "same sample, acq: 200" test "$STATUS" = 200
check "same sample: the earlier montage.jpg stays" test -f "$MBD/acq/montage.jpg"
check "same sample: the new acqLog.txt is added" test -f "$MBD/acq/acqLog.txt"
# An analysis upload of a new sample leaves acq alone.
backdate "$MBD/analysis"; ACQ_NOW="$(snapshot "$MBD/acq")"
upload "$TKB" "$SB" "$MB" analysis "$TMP/z/s2.zip"
check "new sample, analysis: 200" test "$STATUS" = 200
check "new sample in analysis: its old files are gone" test ! -e "$MBD/analysis/acqLog.txt"
check "new sample in analysis: acq folder untouched" test "$(snapshot "$MBD/acq")" = "$ACQ_NOW"
# A folder with no stored sample ID (e.g. made by hand) counts as a new sample.
mkdir -p "$APP/system_data/$SA/$MA2/acq"; echo old > "$APP/system_data/$SA/$MA2/acq/acqLog.txt"
good_zip a2 "$MA2" S1; rm "$TMP/z/a2/acqLog.txt"; zip_dir a2
upload "$TKA" "$SA" "$MA2" acq "$TMP/z/a2.zip"
check "folder without a stored sample ID: 200" test "$STATUS" = 200
check "folder without a stored sample ID is emptied" test ! -e "$APP/system_data/$SA/$MA2/acq/acqLog.txt"

# Extra files are skipped, whatever their name or folder; the five names are kept (flattened).
EX="$APP/system_data/$SA/$MA2"
good_zip extras "$MA2" S1; mkdir -p "$TMP/z/extras/sub/dir"
for f in evil.php .htaccess notes.txt recipe_old.yml montage.JPG montage.jpg.bak data.csv; do echo x > "$TMP/z/extras/$f"; done
mv "$TMP/z/extras/montage.jpg" "$TMP/z/extras/sub/dir/montage.jpg"; echo x > "$TMP/z/extras/sub/dir/other.json"
mkdir -p "$TMP/z/extras/d/status.json"   # a directory entry is not a file, whatever its name
zip_dir extras
backdate "$EX/acq"
upload "$TKA" "$SA" "$MA2" acq "$TMP/z/extras.zip"
check "upload with extra files: 200" test "$STATUS" = 200
check "only the five names (and meta.json) on disk" test "$(ls -A "$EX/acq" | LC_ALL=C sort | tr '\n' ' ')" = "LastCompleteSection.jpg acqLog.txt meta.json montage.jpg recipe.yml status.json "
check "a directory entry named status.json is skipped" test -f "$EX/acq/status.json"
check "extra files: the response lists only kept names" bash -c '! grep -qE "evil|htaccess|notes|csv|bak|JPG|other" <<<"$1"' _ "$BODY"

# The microscope ID in the recipe is trimmed and its spaces become "_".
new_dir spaced "Scope ${MSPACE#Scope_}" "Sample 1"
sed -i.bak "s/^  ID: \(.*\)\$/  ID:   \1   /" "$TMP/z/spaced/recipe.yml"; rm "$TMP/z/spaced/recipe.yml.bak"; zip_dir spaced
upload "$TKA" "$SA" "$MSPACE" acq "$TMP/z/spaced.zip"
check "SYSTEM.ID 'Scope xyz' (padded) matches microscope_id Scope_xyz: 200" test "$STATUS" = 200
check "a sample ID with a space is accepted and stored" test "$(meta_of "$APP/system_data/$SA/$MSPACE/acq" sample_id)" = "Sample 1"
good_zip spaced2 "Scope $(r 3)" S1
backdate "$APP/system_data/$SA/$MSPACE/acq"
upload "$TKA" "$SA" "$MSPACE" acq "$TMP/z/spaced2.zip"
check "SYSTEM.ID with a different word: 400" test "$STATUS" = 400
good_zip spaced3 "${MSPACE}" S1
upload "$TKA" "$SA" "$MSPACE" acq "$TMP/z/spaced3.zip"
check "SYSTEM.ID already written with '_': 200" test "$STATUS" = 200

# Rate limits are independent per source and per microscope.
good_zip a1 "$MA1" S1
backdate "$D"
upload "$TKA" "$SA" "$MA1" analysis "$TMP/z/a1.zip"
check "microscope A1 analysis upload while acq is recent: 200" test "$STATUS" = 200
upload "$TKA" "$SA" "$MA1" acq "$TMP/z/a1.zip"
check "microscope A1 acq upload (old meta): 200" test "$STATUS" = 200
upload "$TKA" "$SA" "$MA1" acq "$TMP/z/a1.zip"
check "A1 acq again within 5 s: 429" test "$STATUS" = 429
mkdir -p "$APP/system_data/$SB/logs/acq/montage.jpg"   # a folder where a file must go: the rename fails
good_zip logs logs S1
upload "$TKB" "$SB" logs acq "$TMP/z/logs.zip"
check "install that cannot complete: 500, not ok" test "$STATUS" = 500
check "  ... and no meta.json claims an upload" test ! -e "$APP/system_data/$SB/logs/acq/meta.json"
check "  ... and no file of the upload is left in the folder" test -z "$(find "$APP/system_data/$SB/logs/acq" -type f)"

# Two uploads of one source arriving together: exactly one is installed, the other gets 429.
conc() { curl -s "$U" -o /dev/null -w '%{http_code}' -X POST -H "$(hdr "$TKA")" -F site_id="$SA" -F microscope_id="$MA2" -F source=analysis -F "data=@$TMP/z/a2.zip;type=application/zip" > "$TMP/conc.$1"; }
conc 1 & P1=$!; conc 2 & P2=$!; wait "$P1" "$P2"
check "concurrent uploads of one source: one 200, one 429" test "$(sort "$TMP/conc.1" "$TMP/conc.2" | tr '\n' ' ')" = "200 429 "
fetch "$B/$PAN/$SA/$MA2?f=main"
check "microscope A2 through the panopticon: image served" test "$STATUS" = 200

# --- the display rule: which sources a view shows, finished, staleness, assets ---
# One microscope per case, all in site A. Every upload carries images tagged with its source, so
# a served asset can be told apart by its bytes.
# dz NAME SYSTEM_ID SAMPLE FINISHED TAG [LAST]: the zip $TMP/z/NAME.zip, its folder kept to compare
# bytes with. LAST cuts the acquisition log after that finished section ("-": a log with no finished
# section); the fixture log ends at section 283 and is kept whole when LAST is not given.
dz() {
  new_dir "$1" "$2" "$3"; printf '{"finished": %s}' "$4" > "$TMP/z/$1/status.json"
  if [ "${6:-}" = "-" ]; then : > "$TMP/z/$1/acqLog.txt"
  elif [ -n "${6:-}" ]; then sed "/FINISHED section number $6,/q" "$TMP/z/$1/acqLog.txt" > "$TMP/z/$1/acqLog.cut" && mv "$TMP/z/$1/acqLog.cut" "$TMP/z/$1/acqLog.txt"; fi
  printf '%s' "$5" >> "$TMP/z/$1/LastCompleteSection.jpg"; printf '%s' "$5" >> "$TMP/z/$1/montage.jpg"
  zip_dir "$1"
}
# up SOURCE MIC NAME: upload $TMP/z/NAME.zip as SOURCE for MIC of site A, which must succeed.
up() { upload "$TKA" "$SA" "$2" "$1" "$TMP/z/$3.zip"; [ "$STATUS" = 200 ] || echo "FAIL  setup upload $1 $3 gave $STATUS $BODY" >&2; }
src_dir() { echo "$APP/system_data/$SA/$1/$2"; }   # MIC SOURCE
page() { fetch "$B/$SA/$1"; PAGE="$BODY"; }
# card MIC: the grid card of a microscope in site A.
card() { fetch "$B/$SA"; CARD="$(awk -v h="href=\"/brainsaw/$SA/$1\"" 'index($0, h) { p = 1 } p { print } p && /<\/a>/ { exit }' <<<"$BODY")"; }
# asset_is MIC KIND DIR: ?f=KIND is served with the bytes of DIR/LastCompleteSection.jpg (or montage.jpg for KIND montage).
asset_is() {
  local file=LastCompleteSection.jpg; [ "$2" = montage ] && file=montage.jpg
  fetch "$B/$SA/$1?f=$2"; [ "$STATUS" = 200 ] && cmp -s "$TMP/b" "$TMP/z/$3/$file"
}
is_stale_card() { grep -q 'class="card stale"' <<<"$CARD"; }
is_stale_page() { grep -q 'class="status stale"' <<<"$PAGE"; }
img_src_has() { grep -o 'src="[^"]*"' <<<"$1" | grep -qF -- "$2"; }
# card_bytes_are DIR: the image the last card() shows is DIR's full image (images carry a source tag).
card_bytes_are() { fetch "http://localhost:$PORT$(attr_of src "$(grep '<img' <<<"$CARD")" | html_unescape)"; [ "$STATUS" = 200 ] && cmp -s "$TMP/b" "$TMP/z/$1/LastCompleteSection.jpg"; }
# thumb_overlays PAGE KIND: the strip link of KIND opens the overlay (it has data-overlay, not a new tab).
thumb_overlays() { grep "id=\"thumb-$2\"" <<<"$1" | grep -q 'data-overlay'; }

# acq alone: BakingTray image, magnifier, no montage; the card shows that image.
dz d1acq "$MD1" ALPHA false ACQ;  up acq "$MD1" d1acq
page "$MD1"; card "$MD1"
check "acq only: main image is the acq image" asset_is "$MD1" main d1acq
check "acq only: magnifier on the main image" body_has "$PAGE" "imageLens({ lensSize"
check "acq only: no thumbnails" body_lacks "$PAGE" 'id="thumb-'
check "acq only: recipe table from acq" body_has "$PAGE" ">ALPHA<"
check "acq only: the acq montage is not served" same_404 "$B/$SA/$MD1?f=montage"
check "acq only: the card shows the acq image" card_bytes_are d1acq
check "acq only: not finished" body_lacks "$CARD$PAGE" 'class="finished"'
backdate "$(src_dir "$MD1" acq)" 7200
page "$MD1"; card "$MD1"
check "an old unfinished acquisition: card is stale" is_stale_card
check "an old unfinished acquisition: page is stale" is_stale_page

# acq + analysis of the same sample: the StitchIt image is the main image, thumbnails below.
dz d2acq "$MD2" BETA false ACQ;  up acq "$MD2" d2acq
dz d2an  "$MD2" BETA false STITCH; up analysis "$MD2" d2an
page "$MD2"; card "$MD2"
check "acq + same-sample analysis: main image is the StitchIt image" asset_is "$MD2" main d2an
check "  ... the page's main image is ?f=main" img_src_has "$(grep 'id="main-image"' <<<"$PAGE")" "f=main"
check "  ... with the magnifier" body_has "$PAGE" "imageLens({ lensSize"
check "  ... no thumbnail sent: the strip's BakingTray image is the full image" bash -c 'l="$(grep -A1 "id=\"thumb-bakingtray\"" <<<"$1" | grep "<img")"; grep -q "src=\"[^\"]*f=bakingtray&" <<<"$l" && ! grep -q bakingtray_tile <<<"$l"' _ "$PAGE"
check "  ... no montage thumbnail sent: the strip shows the full montage" bash -c 'grep -A1 "id=\"thumb-montage\"" <<<"$1" | grep "<img" | grep -q "src=\"[^\"]*f=montage&"' _ "$PAGE"
check "  ... BakingTray thumbnail present, enlarges on click" body_has "$PAGE" '<a id="thumb-bakingtray" href="/brainsaw/'"$SA/$MD2"'?f=bakingtray'
check "  ... montage thumbnail present, enlarges on click" body_has "$PAGE" '<a id="thumb-montage" href="/brainsaw/'"$SA/$MD2"'?f=montage'
check "  ... the BakingTray asset is the acq image" asset_is "$MD2" bakingtray d2acq
check "  ... the montage asset is the StitchIt montage" asset_is "$MD2" montage d2an
check "  ... montage link opens the overlay, and no thumbnail yet: the strip shows the full montage" body_has "$PAGE" 'data-overlay'
check "  ... the BakingTray link opens the same overlay" thumb_overlays "$PAGE" bakingtray
check "  ... the montage link opens the overlay" thumb_overlays "$PAGE" montage
check "  ... no StitchIt thumbnail (it is the main image)" body_lacks "$PAGE" 'id="thumb-stitchit"'
check "  ... the overlay script is present" body_has "$PAGE" "querySelectorAll('a[data-overlay]')"
check "  ... the page has the overlay and its close button" body_has "$PAGE" 'id="overlay-close"'
check "  ... ?f=montage_tile is the usual 404" same_404 "$B/$SA/$MD2?f=montage_tile"
backdate "$(src_dir "$MD2" analysis)"; dz d2mt "$MD2" BETA false STITCH; cp "$IMAGES/tile_thumbnail.jpeg" "$TMP/z/d2mt/montage_thumbnail.jpg"; zip_dir d2mt; up analysis "$MD2" d2mt
page "$MD2"
check "  ... montage thumbnail: the strip shows it" img_src_has "$(grep -A1 'id="thumb-montage"' <<<"$PAGE")" "f=montage_tile"
fetch "$B/$SA/$MD2?f=montage_tile"
check "  ... served with the uploaded bytes" cmp -s "$TMP/b" "$IMAGES/tile_thumbnail.jpeg"
backdate "$(src_dir "$MD2" analysis)"; dz d2mn "$MD2" BETA false STITCH; up analysis "$MD2" d2mn
check "  ... a new montage without a thumbnail removes the old one" same_404 "$B/$SA/$MD2?f=montage_tile"
check "  ... the card image is the StitchIt image" card_bytes_are d2an
check "  ... the version covers both sources" body_has "$CARD" 'data-version="acq='
check "  ... and the analysis" body_has "$CARD" ';analysis='
fetch "$B/$SA/$MD2?f=meta"
check "  ... the meta endpoint's version covers both" bash -c 'grep -q "\"version\":\"acq=.*;analysis=" <<<"$1"' _ "$BODY"
check "  ... the recipe table is the ground truth's" body_has "$PAGE" ">BETA<"

# acq + analysis of another sample: analysis is hidden, and so are its files.
dz d3acq "$MD3" GAMMA false ACQ;  up acq "$MD3" d3acq
dz d3an  "$MD3" OTHER false STITCH; up analysis "$MD3" d3an
page "$MD3"; card "$MD3"
check "non-matching analysis: main image is the acq image" asset_is "$MD3" main d3acq
check "  ... no thumbnails" body_lacks "$PAGE" 'id="thumb-'
check "  ... the analysis montage gives the usual 404" same_404 "$B/$SA/$MD3?f=montage"
check "  ... the version names only acq" bash -c '! grep -q "analysis=" <<<"$1"' _ "$CARD"
check "  ... the card shows the acq sample" body_has "$CARD" "Sample: GAMMA"
# It appears when its sample matches, and is hidden again when acq starts a new sample.
backdate "$(src_dir "$MD3" analysis)"
dz d3an2 "$MD3" GAMMA false STITCH2; up analysis "$MD3" d3an2
page "$MD3"
check "analysis of the same sample appears" asset_is "$MD3" montage d3an2
check "  ... as the main image" asset_is "$MD3" main d3an2
backdate "$(src_dir "$MD3" acq)"
dz d3acq3 "$MD3" DELTA false ACQ3; up acq "$MD3" d3acq3
page "$MD3"
check "acq starts a new sample: the old analysis is hidden again" same_404 "$B/$SA/$MD3?f=montage"
check "  ... and the acq image is the main image" asset_is "$MD3" main d3acq3

# No acq/: analysis alone (a BakingTray that is not upgraded).
dz d4an "$MD4" EPSILON false STITCH; up analysis "$MD4" d4an
page "$MD4"; card "$MD4"
check "analysis only: main image is the analysis image" asset_is "$MD4" main d4an
check "  ... the card image is the analysis image" img_src_has "$CARD" "f=main"
check "  ... no BakingTray thumbnail" body_lacks "$PAGE" 'id="thumb-bakingtray"'
check "  ... the BakingTray asset is a 404" same_404 "$B/$SA/$MD4?f=bakingtray"
check "  ... the recipe table comes from analysis" body_has "$PAGE" ">EPSILON<"
check "  ... freshness is the analysis upload's" body_has "$CARD" "data-uploaded-at=\"$(meta_of "$(src_dir "$MD4" analysis)" uploaded_at)\""
check "  ... the version names the analysis" body_has "$CARD" 'data-version="analysis='
dz d4acq "$MD4" EPSILON false ACQ;  up acq "$MD4" d4acq
page "$MD4"
check "  ... a matching acq upload then becomes the ground truth: BakingTray thumbnail" body_has "$PAGE" 'id="thumb-bakingtray"'

# Finished comes from the ground truth (acq) only; stale is not drawn when finished.
dz f1acq "$MD5" ZETA false ACQ;  up acq "$MD5" f1acq
dz f1an  "$MD5" ZETA false STITCH; up analysis "$MD5" f1an
page "$MD5"; card "$MD5"
check "both unfinished: not finished" body_lacks "$CARD$PAGE" 'class="finished"'
check "  ... data-finished is 0" body_has "$CARD" 'data-finished="0"'
ACQ5="$(src_dir "$MD5" acq)"; AN5="$(src_dir "$MD5" analysis)"
backdate "$ACQ5" 7200; backdate "$AN5" 10800
dz f2acq "$MD5" ZETA true ACQ;  up acq "$MD5" f2acq     # BakingTray's end upload
backdate "$ACQ5" 7200
page "$MD5"; card "$MD5"
check "acq finished: card says finished" body_has "$CARD" '<span class="finished">finished</span>'
check "  ... page says Finished" body_has "$PAGE" '<strong class="finished">Finished</strong>'
check "  ... data-finished is 1" body_has "$CARD" 'data-finished="1"'
check "  ... the 2 h old card is not drawn stale" bash -c '! grep -q "card stale" <<<"$1"' _ "$CARD"
check "  ... the 2 h old page is not drawn stale" bash -c '! grep -q "status stale" <<<"$1"' _ "$PAGE"
check "  ... \"ago\" is still shown" body_has "$CARD" '<span data-ago>2h ago</span>'
# A later analysis upload with finished false: still finished, still not stale (staleness is acq's).
dz f3an "$MD5" ZETA false STITCH; up analysis "$MD5" f3an
page "$MD5"; card "$MD5"
check "later unfinished analysis upload: still finished" body_has "$CARD" '<span class="finished">finished</span>'
check "  ... the page too" body_has "$PAGE" '<strong class="finished">Finished</strong>'
check "  ... freshness is acq's, 2 h old" body_has "$CARD" "data-uploaded-at=\"$(meta_of "$ACQ5" uploaded_at)\""
check "  ... and a still-sending analysis does not make the card stale" bash -c '! grep -q "card stale" <<<"$1"' _ "$CARD"
# Resume: an acq upload with finished false clears it.
dz f4acq "$MD5" ZETA false ACQ;  up acq "$MD5" f4acq
page "$MD5"; card "$MD5"
check "acq resume (finished false): finished cleared" body_lacks "$CARD$PAGE" 'class="finished"'
check "  ... and the fresh card is not stale" bash -c '! grep -q "card stale" <<<"$1"' _ "$CARD"
# An analysis upload with finished true cannot set it.
backdate "$AN5" 3600
dz f5an "$MD5" ZETA true STITCH; up analysis "$MD5" f5an
page "$MD5"; card "$MD5"
check "acq unfinished, later analysis finished: not finished" body_lacks "$CARD$PAGE" 'class="finished"'

# The estimated completion is shown while acquiring, not once finished.
page "$MD2"
check "unfinished page shows the estimated completion" body_has "$PAGE" 'Estimated completion'
check "  ... as a machine-readable UTC instant the browser can localise" grep -qE '<time id="eta" datetime="[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z">[0-9-]+ [0-9:]+ UTC</time> \(estimated\)' <<<"$PAGE"
check "  ... with the script that shows it in the viewer's own time zone" body_has "$PAGE" "toLocaleString(undefined"
# The metadata table: voxel size as 1 x 1 x 0 decimals, no objective, no planned-sections row.
check "metadata: voxel size row" body_has "$PAGE" 'Voxel size X / Y / Z (&micro;m)'
check "  ... formatted 1 x 1 x 0 decimals" body_has "$PAGE" '<td>2.2 x 2.2 x 6</td>'
check "  ... no longer called resolution" body_lacks "$PAGE" 'Resolution'
check "metadata: no objective row" bash -c '! grep -q "Objective\|nikon" <<<"$1"' _ "$PAGE"
check "metadata: no total-sections row" body_lacks "$PAGE" 'Total sections planned'
check "metadata: sample, laser power and optical planes remain" bash -c 'grep -q "<td>Sample</td>" <<<"$1" && grep -q "Laser power" <<<"$1" && grep -q "Optical planes" <<<"$1"' _ "$PAGE"
backdate "$(src_dir "$MD5" acq)" 7200
dz f6acq "$MD5" ZETA true ACQ; up acq "$MD5" f6acq
page "$MD5"
check "finished page has no estimated completion" body_lacks "$PAGE" 'Estimated completion'

# A hidden source never contributes: an unfinished acq with a non-matching, finished analysis.
dz h1acq "$MD6" SAMPA false ACQ;  up acq "$MD6" h1acq
dz h1an  "$MD6" SAMPB true STITCH; up analysis "$MD6" h1an
page "$MD6"; card "$MD6"
check "hidden analysis says finished: not finished" body_lacks "$CARD$PAGE" 'class="finished"'
fetch "$B/$SA/$MD6?f=meta"
check "  ... ?f=meta version excludes the hidden analysis" bash -c '! grep -q "analysis" <<<"$1" && grep -q "acq=" <<<"$1"' _ "$BODY"
# While acq/meta.json is missing (an install in progress) or unreadable, acq is still the ground truth.
ACQ6="$(src_dir "$MD6" acq)"; cp "$ACQ6/meta.json" "$TMP/meta6.json"; rm "$ACQ6/meta.json"
page "$MD6"; card "$MD6"
check "acq/meta.json missing: analysis stays hidden (montage 404)" same_404 "$B/$SA/$MD6?f=montage"
check "  ... the main image is still the acq image" asset_is "$MD6" main h1acq
check "  ... finished is not taken from the hidden analysis" body_lacks "$CARD$PAGE" 'class="finished"'
check "  ... the page and card still render" test "$STATUS" = 200
echo '{garbage' > "$ACQ6/meta.json"
page "$MD6"; card "$MD6"
check "acq/meta.json corrupt: page renders, analysis hidden" bash -c '[ "$1" = 200 ] && ! grep -q "thumb-montage" <<<"$2"' _ "$STATUS" "$PAGE"
check "  ... the corrupt file is logged" grep -q "meta.json is not a JSON object" "$TMP/server.log"
check "  ... assets of the hidden analysis are 404" same_404 "$B/$SA/$MD6?f=montage"
cp "$TMP/meta6.json" "$ACQ6/meta.json"
echo 'not json' > "$ACQ6/status.json"
page "$MD6"
check "unusable status.json: page renders, not finished" bash -c '[ "$1" = 200 ] && ! grep -q "class=\"finished\"" <<<"$2"' _ "$STATUS" "$PAGE"
check "  ... and the file is logged" grep -q "status.json is not a JSON object" "$TMP/server.log"

# analysis alone can be finished.
dz g1an "$MD7" ETA true STITCH; up analysis "$MD7" g1an
page "$MD7"; card "$MD7"
check "analysis only, finished: card says finished" body_has "$CARD" '<span class="finished">finished</span>'
backdate "$(src_dir "$MD7" analysis)" 7200
card "$MD7"
check "  ... still not drawn stale at 2 h" bash -c '! grep -q "card stale" <<<"$1"' _ "$CARD"

# analysis alone: its own status.json decides.
dz u1an "$MD8" THETA false STITCH; up analysis "$MD8" u1an
card "$MD8"
check "analysis only, unfinished: not finished" body_lacks "$CARD" 'class="finished"'
backdate "$(src_dir "$MD8" analysis)"
dz u2an "$MD8" THETA true STITCH; up analysis "$MD8" u2an
card "$MD8"
check "analysis only, then finished: finished" body_has "$CARD" '<span class="finished">finished</span>'

# acq/ exists but has no image: the matching analysis image stands in on the page and the card.
dz n1acq "$MD9" IOTA false ACQ; rm "$TMP/z/n1acq/LastCompleteSection.jpg"; zip_dir n1acq; up acq "$MD9" n1acq
dz n1an  "$MD9" IOTA false STITCH; up analysis "$MD9" n1an
card "$MD9"; page "$MD9"
check "acq without an image: the card shows the analysis image" card_bytes_are n1an
check "  ... the page's main image is still the analysis image" asset_is "$MD9" main n1an

# An acq/ folder with no upload in it (empty, or left by a failed first install) is still the
# ground truth: a valid analysis/ beside it stays hidden until an acq upload succeeds.
clear_blocker() { rm -rf "$APP/system_data/$SB/logs/acq/montage.jpg"; }
good_zip logs logs S1
upload "$TKB" "$SB" logs analysis "$TMP/z/logs.zip"
check "analysis upload beside a failed acq install: 200" test "$STATUS" = 200
fetch "$B/$SB/logs"
check "acq/ left by a failed install: nothing is shown from analysis (no image)" body_lacks "$BODY" 'id="main-image"'
check "  ... no thumbnails" body_lacks "$BODY" 'id="thumb-'
check "  ... the analysis montage is a 404" same_404 "$B/$SB/logs?f=montage"
check "  ... and its main image" same_404 "$B/$SB/logs?f=main"
clear_blocker
check "empty acq/ folder: analysis montage still a 404" same_404 "$B/$SB/logs?f=montage"
check "  ... no version from analysis" bash -c '! curl -s "$1" | grep -q analysis' _ "$B/$SB/logs?f=meta"
upload "$TKB" "$SB" logs acq "$TMP/z/logs.zip"
check "the acq upload then succeeds: 200" test "$STATUS" = 200
fetch "$B/$SB/logs?f=montage"
check "  ... and the matching analysis appears (montage served)" test "$STATUS" = 200

# Assets: only what the display rule shows; the recipe and log never; no traversal.
for kind in recipe log acqLog acqlog recipe.yml acqLog.txt status status.json meta.json LastCompleteSection.jpg "../analysis/montage.jpg" "..%2Fanalysis%2Fmontage.jpg" "bakingtray/../montage"; do
  check "?f=$kind is the usual 404 (matching analysis shown)" same_404 "$B/$SA/$MD5?f=$kind"
done
check "?f[]=main (an array) is the usual 404" same_404 "$B/$SA/$MD5?f%5B%5D=main"

# --- card thumbnails: the client's tile_thumbnail.jpg, from the card image's folder and only beside it ---
# tz NAME SAMPLE TAG: like dz (not finished) plus a thumbnail tagged with TAG, so its bytes can be told apart.
tz() { dz "$1" "$MT" "$2" false "$3"; cp "$IMAGES/tile_thumbnail.jpeg" "$TMP/z/$1/tile_thumbnail.jpg"; printf '%s' "$3" >> "$TMP/z/$1/tile_thumbnail.jpg"; zip_dir "$1"; }
tile_is() { fetch "$B/$SA/$MT?f=${2:-tile}"; [ "$STATUS" = 200 ] && cmp -s "$TMP/b" "$TMP/z/$1/tile_thumbnail.jpg"; }   # NAME [KIND]
tz t1 THETA T1; up acq "$MT" t1
page "$MT"; card "$MT"
check "thumbnail: the card shows it" img_src_has "$CARD" "f=tile"
check "  ... served with the uploaded bytes" tile_is t1
TSRC="$(attr_of src "$(grep '<img' <<<"$CARD")" | html_unescape)"; fetch "http://localhost:$PORT$TSRC"
check "  ... versioned and cacheable" test "$(header_of Cache-Control)" = "private, max-age=31536000, immutable"
check "  ... the card still links the microscope page" body_has "$CARD" "href=\"/brainsaw/$SA/$MT\""
check "  ... the page's main image is still the full image" asset_is "$MT" main t1
check "  ... acq alone: no thumbnail strip" body_lacks "$PAGE" 'id="thumb-'
# A matching analysis upload moves the BakingTray image into the strip: it shows the thumbnail and opens the full image.
backdate "$(src_dir "$MT" acq)"; tz t2an THETA STITCH; up analysis "$MT" t2an
page "$MT"; card "$MT"
check "  ... strip: the BakingTray link opens the full image" body_has "$PAGE" '<a id="thumb-bakingtray" href="/brainsaw/'"$SA/$MT"'?f=bakingtray'
check "  ... strip: the BakingTray image is acq's thumbnail" img_src_has "$(grep -A1 'id="thumb-bakingtray"' <<<"$PAGE")" "f=bakingtray_tile"
check "  ... served with acq's thumbnail bytes" tile_is t1 bakingtray_tile
check "  ... the card thumbnail is now the StitchIt one" tile_is t2an
check "  ... and the card shows it" img_src_has "$CARD" "f=tile"
# A new section image without a thumbnail: the old thumbnail is removed.
backdate "$(src_dir "$MT" acq)"; dz t3 "$MT" THETA false T3; up acq "$MT" t3
card "$MT"
check "new image without a thumbnail: old thumbnail removed" test ! -e "$(src_dir "$MT" acq)/tile_thumbnail.jpg"
check "  ... the acq thumbnail is the usual 404" same_404 "$B/$SA/$MT?f=bakingtray_tile"
check "  ... the card still shows the StitchIt thumbnail" tile_is t2an
# An end-of-run upload without an image keeps the thumbnail that sits beside its image.
backdate "$(src_dir "$MT" acq)"; tz t4 THETA T4; up acq "$MT" t4
backdate "$(src_dir "$MT" acq)"; new_dir t5 "$MT" THETA; rm "$TMP/z/t5/LastCompleteSection.jpg" "$TMP/z/t5/montage.jpg"; echo '{"finished": true}' > "$TMP/z/t5/status.json"; zip_dir t5; up acq "$MT" t5
# t5 sends finished:true: with finished:false and no image it would be a start-of-run call, which removes the thumbnail.
check "upload without an image keeps the thumbnail" tile_is t4 bakingtray_tile
# A thumbnail is never shown without its image: a new sample with no image (and finished) empties the folder.
backdate "$(src_dir "$MT" acq)"; new_dir t6 "$MT" IOTA; rm "$TMP/z/t6/LastCompleteSection.jpg" "$TMP/z/t6/montage.jpg"; echo '{"finished": true}' > "$TMP/z/t6/status.json"; zip_dir t6; up acq "$MT" t6   # finished:true: with finished:false this no-image upload would be a start-of-run call (tested as t8 below); this way the new sample ID alone empties the folder
card "$MT"
check "new sample without an image: no thumbnail, placeholder card" test "$(img_src_has "$CARD" "f=" && echo img || echo none)" = none
check "  ... ?f=tile is the usual 404" same_404 "$B/$SA/$MT?f=tile"
# The start-of-run twin: the same sample, no image, finished false also removes the thumbnail.
backdate "$(src_dir "$MT" acq)"; tz t7 IOTA T7; up acq "$MT" t7
backdate "$(src_dir "$MT" acq)"; new_dir t8 "$MT" IOTA; rm "$TMP/z/t8/LastCompleteSection.jpg" "$TMP/z/t8/montage.jpg"; zip_dir t8; up acq "$MT" t8
card "$MT"
check "start call without an image: no thumbnail, placeholder card" test "$(img_src_has "$CARD" "f=" && echo img || echo none)" = none
check "  ... ?f=tile is the usual 404" same_404 "$B/$SA/$MT?f=tile"
# No acq/: the card shows the analysis image, so the analysis thumbnail.
dz ta "$MTA" KAPPA false STITCH; cp "$IMAGES/tile_thumbnail.jpeg" "$TMP/z/ta/tile_thumbnail.jpg"; printf TA >> "$TMP/z/ta/tile_thumbnail.jpg"; zip_dir ta
up analysis "$MTA" ta; card "$MTA"
check "analysis only: the card shows the analysis thumbnail" img_src_has "$CARD" "f=tile"
fetch "$B/$SA/$MTA?f=tile"
check "  ... with its bytes" cmp -s "$TMP/b" "$TMP/z/ta/tile_thumbnail.jpg"

# --- an upload with no image and finished:false (the start of a run) ---
# An acq start call empties acq/ and removes analysis/. An analysis start call empties analysis/
# and removes acq/ only when acq's stored sample ID differs from the upload's (or is unreadable).
WSAMP=WIPE
WD="$APP/system_data/$SA/$MW"
backdate_if_any() { [ -f "$1/meta.json" ] && backdate "$1" || true; }
other_of() { if [ "$1" = acq ]; then echo analysis; else echo acq; fi; }
# The file names (not meta.json) in a folder.
files_in() { find "$1" -type f ! -name 'meta.json' -exec basename {} \; | LC_ALL=C sort | tr '\n' ' '; }
# wipe_seed: acq and analysis of one sample, each with image, montage, both thumbnails, acqLog, recipe and status; both old enough to upload again.
wipe_seed() {
  local n
  for n in wacq wan; do
    dz "$n" "$MW" "$WSAMP" false "$n"
    cp "$IMAGES/tile_thumbnail.jpeg" "$TMP/z/$n/tile_thumbnail.jpg"; cp "$IMAGES/tile_thumbnail.jpeg" "$TMP/z/$n/montage_thumbnail.jpg"; zip_dir "$n"
  done
  backdate_if_any "$WD/acq"; up acq "$MW" wacq
  backdate_if_any "$WD/analysis"; up analysis "$MW" wan
  backdate "$WD/acq"; backdate "$WD/analysis"
}
# wipe_start NAME FINISHED [image|noimage] [SAMPLE]: a recipe that differs from the seeded one (9 optical planes), without the images unless "image" is given.
wipe_start() {
  new_dir "$1" "$MW" "${4:-$WSAMP}"; printf '{"finished": %s}' "$2" > "$TMP/z/$1/status.json"
  sed -i.bak 's/numOpticalPlanes: 7.0/numOpticalPlanes: 9.0/' "$TMP/z/$1/recipe.yml"; rm "$TMP/z/$1/recipe.yml.bak"
  if [ "${3:-}" != image ]; then rm "$TMP/z/$1/LastCompleteSection.jpg" "$TMP/z/$1/montage.jpg"; fi
  zip_dir "$1"
}
wipe_seed
page "$MW"
check "wipe setup: the stitched image is the main image" asset_is "$MW" main wan
check "wipe setup: the stitched montage is shown" asset_is "$MW" montage wan
check "wipe setup: the card thumbnail is served" test "$(fetch "$B/$SA/$MW?f=tile"; echo "$STATUS")" = 200
check "wipe setup: the montage thumbnail is served" test "$(fetch "$B/$SA/$MW?f=montage_tile"; echo "$STATUS")" = 200
check "wipe setup: the page does not show 9 optical planes yet" body_lacks "$PAGE" '<td>9</td>'

# acq start call: acq/ holds only the new files, analysis/ is gone.
wipe_start wst1 false; upload "$TKA" "$SA" "$MW" acq "$TMP/z/wst1.zip"
check "start call (acq): 200" test "$STATUS" = 200
check "  ... acq/ holds only the new files" test "$(files_in "$WD/acq")" = "acqLog.txt recipe.yml status.json "
check "  ... acq/ has a fresh meta.json" test "$(meta_of "$WD/acq" sample_id)" = "$WSAMP"
check "  ... analysis/ is removed" test ! -e "$WD/analysis"
check "  ... the lock files remain" test -e "$WD/.lock-acq" -a -e "$WD/.lock-analysis"
page "$MW"
check "  ... the page shows the new recipe" body_has "$PAGE" '<td>9</td>'
check "  ... and no image" body_lacks "$PAGE" 'id="main-image"'
for kind in main bakingtray montage tile montage_tile; do check "  ... ?f=$kind is the usual 404" same_404 "$B/$SA/$MW?f=$kind"; done
# A later analysis upload recreates its folder.
backdate "$WD/acq"; dz wan2 "$MW" "$WSAMP" false STITCH2; up analysis "$MW" wan2
check "  ... a later analysis upload recreates analysis/" test -f "$WD/analysis/meta.json" -a -f "$WD/analysis/montage.jpg"

# analysis start call, same sample as acq: acq/ is untouched, acq's images are still served.
wipe_seed; BEFORE_ACQ="$(snapshot "$WD/acq")"
wipe_start wst2 false; upload "$TKA" "$SA" "$MW" analysis "$TMP/z/wst2.zip"
check "start call (analysis, same sample as acq): 200" test "$STATUS" = 200
check "  ... analysis/ holds only the new files" test "$(files_in "$WD/analysis")" = "acqLog.txt recipe.yml status.json "
check "  ... acq/ is completely untouched" test "$(snapshot "$WD/acq")" = "$BEFORE_ACQ"
check "  ... acq's image is still the main image" asset_is "$MW" main wacq
check "  ... the card thumbnail is still served" test "$(fetch "$B/$SA/$MW?f=tile"; echo "$STATUS")" = 200

# analysis start call, another sample than acq's: acq/ is removed and the page shows the analysis data.
wipe_seed; wipe_start wst3 false noimage OTHERSAMP; upload "$TKA" "$SA" "$MW" analysis "$TMP/z/wst3.zip"
check "start call (analysis, other sample): 200" test "$STATUS" = 200
check "  ... analysis/ holds only the new files" test "$(files_in "$WD/analysis")" = "acqLog.txt recipe.yml status.json "
check "  ... acq/ is removed" test ! -e "$WD/acq"
page "$MW"
check "  ... the page shows the new recipe" body_has "$PAGE" '<td>9</td>'
check "  ... and the new sample" body_has "$PAGE" '>OTHERSAMP<'
check "  ... and no image" body_lacks "$PAGE" 'id="main-image"'
for kind in main bakingtray montage tile montage_tile; do check "  ... ?f=$kind is the usual 404" same_404 "$B/$SA/$MW?f=$kind"; done

# analysis start call, acq/ without a meta.json: acq counts as another sample and is removed.
wipe_seed; rm "$WD/acq/meta.json"
wipe_start wst4 false; upload "$TKA" "$SA" "$MW" analysis "$TMP/z/wst4.zip"
check "start call (analysis, acq without meta.json): 200" test "$STATUS" = 200
check "  ... acq/ is removed" test ! -e "$WD/acq"

# A montage-only analysis upload (a montage but no section image, finished false) is a mid-run
# result, not an empty start call: nothing is wiped and it merges into analysis/ as before.
wipe_seed; BEFORE_ACQ="$(snapshot "$WD/acq")"
wipe_start wmon false; printf M > "$TMP/z/wmon/montage.jpg"; zip_dir wmon
upload "$TKA" "$SA" "$MW" analysis "$TMP/z/wmon.zip"
check "montage-only analysis upload: 200" test "$STATUS" = 200
check "  ... analysis/ keeps its other files (the old montage thumbnail goes with the old montage) and gets the new ones" test "$(files_in "$WD/analysis")" = "LastCompleteSection.jpg acqLog.txt montage.jpg recipe.yml status.json tile_thumbnail.jpg "
check "  ... the montage is the new one" cmp -s "$WD/analysis/montage.jpg" "$TMP/z/wmon/montage.jpg"
check "  ... acq/ is untouched" test "$(snapshot "$WD/acq")" = "$BEFORE_ACQ"

# End-of-run call without an image (finished true): nothing is wiped.
for src in acq analysis; do
  other="$(other_of "$src")"
  wipe_seed; BEFORE_OTHER="$(snapshot "$WD/$other")"
  wipe_start wend true; upload "$TKA" "$SA" "$MW" "$src" "$TMP/z/wend.zip"
  check "end call ($src), no image, finished: 200" test "$STATUS" = 200
  check "  ... the other source is untouched" test "$(snapshot "$WD/$other")" = "$BEFORE_OTHER"
  check "  ... the sender's images stay" test -f "$WD/$src/LastCompleteSection.jpg" -a -f "$WD/$src/montage.jpg"
  check "  ... and its thumbnails" test -f "$WD/$src/tile_thumbnail.jpg" -a -f "$WD/$src/montage_thumbnail.jpg"
  check "  ... an image is still served" test "$(fetch "$B/$SA/$MW?f=main"; echo "$STATUS")" = 200
done

# An upload with an image never wipes the other source, even when unfinished.
for src in acq analysis; do
  other="$(other_of "$src")"
  wipe_seed; BEFORE_OTHER="$(snapshot "$WD/$other")"
  wipe_start wimg false image; upload "$TKA" "$SA" "$MW" "$src" "$TMP/z/wimg.zip"
  check "upload with an image ($src), finished false: 200" test "$STATUS" = 200
  check "  ... the other source is untouched" test "$(snapshot "$WD/$other")" = "$BEFORE_OTHER"
done

# A refused start call wipes nothing.
wipe_seed; BEFORE_ACQ="$(snapshot "$WD/acq")"; BEFORE_AN="$(snapshot "$WD/analysis")"
wipe_start wbad false; sed -i.bak "s/^  ID: $MW/  ID: other_scope/" "$TMP/z/wbad/recipe.yml"; rm "$TMP/z/wbad/recipe.yml.bak"; zip_dir wbad
upload "$TKA" "$SA" "$MW" acq "$TMP/z/wbad.zip"
check "refused start call (wrong SYSTEM.ID): 400" test "$STATUS" = 400
check "  ... acq/ untouched" test "$(snapshot "$WD/acq")" = "$BEFORE_ACQ"
check "  ... analysis/ untouched" test "$(snapshot "$WD/analysis")" = "$BEFORE_AN"

# A rate-limited start call wipes nothing. The second call comes straight after an accepted one,
# so this exercises the early rate-limit check.
wipe_seed; wipe_start wimg2 false image; upload "$TKA" "$SA" "$MW" acq "$TMP/z/wimg2.zip"
BEFORE_ACQ="$(snapshot "$WD/acq")"; BEFORE_AN="$(snapshot "$WD/analysis")"
wipe_start wrl false; upload "$TKA" "$SA" "$MW" acq "$TMP/z/wrl.zip"
check "rate-limited start call: 429" test "$STATUS" = 429
check "  ... acq/ untouched" test "$(snapshot "$WD/acq")" = "$BEFORE_ACQ"
check "  ... analysis/ untouched" test "$(snapshot "$WD/analysis")" = "$BEFORE_AN"
# Two start calls arriving together: exactly one is installed and the other gets 429. Whether the
# loser is stopped by the early check or by the check under the lock depends on timing.
wipe_seed
conc_start() { curl -s "$U" -o /dev/null -w '%{http_code}' -X POST -H "$(hdr "$TKA")" -F site_id="$SA" -F microscope_id="$MW" -F source=acq -F "data=@$TMP/z/wst1.zip;type=application/zip" > "$TMP/cs.$1"; }
conc_start 1 & P1=$!; conc_start 2 & P2=$!; wait "$P1" "$P2"
check "concurrent start calls: one 200, one 429" test "$(sort "$TMP/cs.1" "$TMP/cs.2" | tr '\n' ' ')" = "200 429 "
check "  ... acq/ holds the new files only" test "$(files_in "$WD/acq")" = "acqLog.txt recipe.yml status.json "

# A folder that cannot be emptied: 500 and nothing at all changes, in either folder (names and bytes).
if [ "$(id -u)" != 0 ]; then
  wipe_seed; BEFORE_ACQ="$(snapshot "$WD/acq")"; BEFORE_AN="$(snapshot "$WD/analysis")"; chmod 555 "$WD/analysis"
  wipe_start wfail false; upload "$TKA" "$SA" "$MW" acq "$TMP/z/wfail.zip"
  chmod 755 "$WD/analysis"
  check "acq start call, analysis/ cannot be emptied: 500" test "$STATUS" = 500
  check "  ... acq/ unchanged" test "$(snapshot "$WD/acq")" = "$BEFORE_ACQ"
  check "  ... analysis/ unchanged" test "$(snapshot "$WD/analysis")" = "$BEFORE_AN"
  check "  ... the failure is logged with the file" bash -c 'tail -n1 "$1" | cut -f3,5 | grep -q "^500.*analysis/"' _ "$LOG"
  wipe_seed; BEFORE_ACQ="$(snapshot "$WD/acq")"; BEFORE_AN="$(snapshot "$WD/analysis")"; chmod 555 "$WD/acq"
  wipe_start wfail2 false noimage OTHERSAMP; upload "$TKA" "$SA" "$MW" analysis "$TMP/z/wfail2.zip"
  chmod 755 "$WD/acq"
  check "analysis start call, acq/ cannot be emptied: 500" test "$STATUS" = 500
  check "  ... acq/ unchanged" test "$(snapshot "$WD/acq")" = "$BEFORE_ACQ"
  check "  ... analysis/ unchanged" test "$(snapshot "$WD/analysis")" = "$BEFORE_AN"
fi

# An upload with an image and a new sample empties only the sender's folder, as before.
for src in acq analysis; do
  other="$(other_of "$src")"
  wipe_seed; BEFORE_OTHER="$(snapshot "$WD/$other")"
  wipe_start wns false image NEWSAMP; upload "$TKA" "$SA" "$MW" "$src" "$TMP/z/wns.zip"
  check "new sample with an image ($src): 200" test "$STATUS" = 200
  check "  ... the other source is untouched" test "$(snapshot "$WD/$other")" = "$BEFORE_OTHER"
done

# A start call touches no other microscope and no other site.
wipe_seed; BEFORE_M="$(snapshot "$APP/system_data/$SA/$MA2")"; BEFORE_S="$(snapshot "$APP/system_data/$SB/$MB")"
wipe_start wst5 false; upload "$TKA" "$SA" "$MW" acq "$TMP/z/wst5.zip"
check "start call: 200" test "$STATUS" = 200
check "  ... another microscope of the site is untouched" test "$(snapshot "$APP/system_data/$SA/$MA2")" = "$BEFORE_M"
check "  ... another site is untouched" test "$(snapshot "$APP/system_data/$SB/$MB")" = "$BEFORE_S"

# acq has ended (finished true); then analysis starts. Same sample: acq stays and the page still says finished.
wipe_seed; backdate "$WD/acq"; dz wfin "$MW" "$WSAMP" true ACQFIN; up acq "$MW" wfin; backdate "$WD/acq"
BEFORE_ACQ="$(snapshot "$WD/acq")"
wipe_start wst6 false; upload "$TKA" "$SA" "$MW" analysis "$TMP/z/wst6.zip"
STATUS6="$STATUS"; page "$MW"
check "analysis start after acq finished, same sample: 200" test "$STATUS6" = 200
check "  ... acq/ is intact" test "$(snapshot "$WD/acq")" = "$BEFORE_ACQ"
check "  ... acq's status.json still says finished" grep -q true "$WD/acq/status.json"
check "  ... the page still says Finished" body_has "$PAGE" '<strong class="finished">Finished</strong>'
# Another sample: acq goes and the page shows analysis alone, not finished.
wipe_seed; backdate "$WD/acq"; up acq "$MW" wfin; backdate "$WD/acq"
wipe_start wst7 false noimage OTHERSAMP; upload "$TKA" "$SA" "$MW" analysis "$TMP/z/wst7.zip"
page "$MW"
check "analysis start after acq finished, other sample: acq/ is removed" test ! -e "$WD/acq"
check "  ... the page shows the analysis sample" body_has "$PAGE" '>OTHERSAMP<'
check "  ... and is not finished" body_lacks "$PAGE" 'class="finished"'

# A folder to be removed must be a real directory without sub-folders; otherwise 500 and nothing changes.
wipe_seed; mv "$WD/analysis" "$TMP/realan"; ln -s "$TMP/realan" "$WD/analysis"
BEFORE_ACQ="$(snapshot "$WD/acq")"; BEFORE_AN="$(snapshot "$TMP/realan")"
wipe_start wlink false; upload "$TKA" "$SA" "$MW" acq "$TMP/z/wlink.zip"
check "acq start call, analysis/ is a symlink: 500" test "$STATUS" = 500
check "  ... acq/ unchanged" test "$(snapshot "$WD/acq")" = "$BEFORE_ACQ"
check "  ... the folder behind the link unchanged" test "$(snapshot "$TMP/realan")" = "$BEFORE_AN"
rm "$WD/analysis"; mv "$TMP/realan" "$WD/analysis"
wipe_seed; mkdir "$WD/analysis/sub"; echo x > "$WD/analysis/sub/f"
BEFORE_ACQ="$(snapshot "$WD/acq")"; BEFORE_AN="$(snapshot "$WD/analysis")"
wipe_start wsub false; upload "$TKA" "$SA" "$MW" acq "$TMP/z/wsub.zip"
check "acq start call, analysis/ has a sub-folder: 500" test "$STATUS" = 500
check "  ... acq/ unchanged" test "$(snapshot "$WD/acq")" = "$BEFORE_ACQ"
check "  ... analysis/ unchanged" test "$(snapshot "$WD/analysis")" = "$BEFORE_AN"
rm -r "$WD/analysis/sub"

# Sample IDs are compared exactly, as the display rule does; an empty stored ID is no ID.
wipe_seed; wipe_start wcase false noimage "$(tr A-Z a-z <<<"$WSAMP")"; upload "$TKA" "$SA" "$MW" analysis "$TMP/z/wcase.zip"
check "analysis start with a sample ID differing only in case: acq/ is removed" test "$STATUS:$(test -e "$WD/acq" && echo there)" = "200:"
wipe_seed; printf '{"uploaded_at":"%s","sample_id":""}' "$UPLOADED_AT" > "$WD/acq/meta.json"
wipe_start wempty false; upload "$TKA" "$SA" "$MW" analysis "$TMP/z/wempty.zip"
check "analysis start, acq/meta.json with an empty sample_id: acq/ is removed" test "$STATUS:$(test -e "$WD/acq" && echo there)" = "200:"

# An acq start call and an analysis upload arriving together, each needing a lock the other may hold: both finish.
wipe_seed; wipe_start wcs false; wipe_start wca false image
conc_a() { curl -s "$U" -o /dev/null -w '%{http_code}' -X POST -H "$(hdr "$TKA")" -F site_id="$SA" -F microscope_id="$MW" -F source="$2" -F "data=@$TMP/z/$3.zip;type=application/zip" > "$TMP/ca.$1"; }
conc_a 1 acq wcs & P1=$!; conc_a 2 analysis wca & P2=$!; wait "$P1" "$P2"
check "acq start call with a simultaneous analysis upload: both 200" test "$(cat "$TMP/ca.1") $(cat "$TMP/ca.2")" = "200 200"
check "  ... acq/ holds the new files only" test "$(files_in "$WD/acq")" = "acqLog.txt recipe.yml status.json "

# The decisions as pure functions.
purefn() { php -r 'require $argv[1]; echo json_encode([
  bs_is_start_of_run([], false), bs_is_start_of_run(["recipe.yml", "montage.jpg"], false), bs_is_start_of_run(["recipe.yml", "status.json", "acqLog.txt"], false),
  bs_is_start_of_run(["LastCompleteSection.jpg"], false), bs_is_start_of_run([], true),
  bs_clears_other_source("acq", "S", "S"), bs_clears_other_source("acq", "S", null),
  bs_clears_other_source("analysis", "S", "S"), bs_clears_other_source("analysis", "S", "T"), bs_clears_other_source("analysis", "S", null)]);' "$APP/lib.php"; }
check "start-of-run and other-source decisions" test "$(purefn)" = "[true,false,true,false,false,true,true,false,true,true]"

# --- the lag rule: StitchIt lags acq by more than BS_STITCHIT_LAG_SECTIONS (2) sections ---
# Lag = acq's latest finished section minus the latest finished section in the log copy that
# StitchIt uploads. The fixture log ends at section 283, so an analysis log cut after section 280
# lags by 3, after 281 by 2. Images are tagged: ACQ is the BakingTray image, STITCH the StitchIt one.
lag_up() { # LAST [NAME]: a matching analysis upload whose log is cut after section LAST (whole when empty)
  if [ -d "$(src_dir "$ML" analysis)" ]; then backdate "$(src_dir "$ML" analysis)"; fi
  dz "${2:-lagan}" "$ML" LAMBDA false STITCH "$1"; up analysis "$ML" "${2:-lagan}"
}
dz lagacq "$ML" LAMBDA false ACQ; up acq "$ML" lagacq
lag_up 280 lag3
page "$ML"; card "$ML"
check "lag 3: the main image is the acq image" asset_is "$ML" main lagacq
check "  ... the card shows the acq image" card_bytes_are lagacq
check "  ... the StitchIt image is in the strip, opening the overlay" thumb_overlays "$PAGE" stitchit
check "  ... the montage is in the strip, opening the overlay" thumb_overlays "$PAGE" montage
check "  ... the acq image is not repeated in the strip" body_lacks "$PAGE" 'id="thumb-bakingtray"'
check "  ... ?f=stitchit is the StitchIt image" asset_is "$ML" stitchit lag3
check "  ... ?f=bakingtray is the acq image" asset_is "$ML" bakingtray lagacq
check "  ... ?f=montage is the StitchIt montage" asset_is "$ML" montage lag3
check "  ... the recipe table is still acq's" body_has "$PAGE" ">LAMBDA<"
check "  ... still not finished" body_lacks "$CARD$PAGE" 'class="finished"'
# Lag 2 (log cut after 281) is not lagging; nor is lag 0, nor a log with no finished section (unknown).
for last in 281 283 "" "-"; do
  lag_up "$last" lagok
  page "$ML"; card "$ML"
  check "analysis log cut after '${last:-whole}': not lagging, the main image is the StitchIt image" asset_is "$ML" main lagok
  check "  ... the card shows the StitchIt image" card_bytes_are lagok
  check "  ... the acq image is in the strip, opening the overlay" thumb_overlays "$PAGE" bakingtray
  check "  ... no StitchIt thumbnail" body_lacks "$PAGE" 'id="thumb-stitchit"'
  check "  ... ?f=bakingtray is the acq image" asset_is "$ML" bakingtray lagacq
done
lag_up 280 lag3
page "$ML"
check "lagging again when the analysis log falls behind: the main image is acq" asset_is "$ML" main lagacq
# The lag flag is a pure function of the two latest finished section numbers.
lag_cases() { php -r 'require $argv[1];
  $cases = [[283, 280, true], [283, 281, false], [283, 0, true], [283, 283, false], [283, 290, false],
            [283, null, false], [null, 280, false], [null, null, false], [0, 0, false]];
  foreach ($cases as [$acq, $stitch, $want]) {
    echo (bs_lag_exceeds_threshold($acq, $stitch) === $want ? "ok" : "bad"), "\t", json_encode([$acq, $stitch]), "\n";
  }' "$APP/lib.php"; }
lagc="$(lag_cases)"
check "lag rule: every case was run" test "$(wc -l <<<"$lagc")" -eq 9
while IFS=$'\t' read -r verdict name; do check "lag rule (acq latest, StitchIt latest) $name" test "$verdict" = ok; done <<<"$lagc"
# Thumbnails on both sources: the card shows the thumbnail beside the image it shows (acq's while
# lagging, StitchIt's otherwise); an image without a thumbnail never gets an older one.
# lt NAME TAG [LAST]: dz plus a tile_thumbnail.jpg tagged TAG, so its bytes can be told apart.
lt() { dz "$1" "$ML" LAMBDA false "$2" "${3:-}"; cp "$IMAGES/tile_thumbnail.jpeg" "$TMP/z/$1/tile_thumbnail.jpg"; printf '%s' "$2" >> "$TMP/z/$1/tile_thumbnail.jpg"; zip_dir "$1"; }
asset_tile_is() { fetch "$B/$SA/$ML?f=$1"; [ "$STATUS" = 200 ] && cmp -s "$TMP/b" "$TMP/z/$2/tile_thumbnail.jpg"; }   # KIND NAME
backdate "$(src_dir "$ML" acq)"; lt lagacqt ACQT; up acq "$ML" lagacqt
lag_up_t() { backdate "$(src_dir "$ML" analysis)"; lt "$1" STITCHT "$2"; up analysis "$ML" "$1"; }   # NAME LAST
lag_up_t lagt3 280
page "$ML"; card "$ML"
check "lag 3 with thumbnails: the card src is ?f=tile" img_src_has "$CARD" "f=tile"
check "  ... it serves acq's thumbnail" asset_tile_is tile lagacqt
check "  ... the strip's StitchIt image uses stitchit_tile" img_src_has "$(grep -A1 'id="thumb-stitchit"' <<<"$PAGE")" "f=stitchit_tile"
check "  ... served with the StitchIt thumbnail bytes" asset_tile_is stitchit_tile lagt3
lag_up 280 lagnt3   # StitchIt image without a thumbnail while lagging: only acq has one
page "$ML"
check "lagging, only acq has a thumbnail: the strip's StitchIt image is the full image" bash -c 'l="$(grep -A1 "id=\"thumb-stitchit\"" <<<"$1" | grep "<img")"; grep -q "src=\"[^\"]*f=stitchit&" <<<"$l" && ! grep -q stitchit_tile <<<"$l"' _ "$PAGE"
lag_up_t lagt0 283
page "$ML"; card "$ML"
check "not lagging with thumbnails: the card src is ?f=tile" img_src_has "$CARD" "f=tile"
check "  ... it serves the StitchIt thumbnail" asset_tile_is tile lagt0
check "  ... the strip's acq image uses bakingtray_tile" img_src_has "$(grep -A1 'id="thumb-bakingtray"' <<<"$PAGE")" "f=bakingtray_tile"
check "  ... served with acq's thumbnail bytes" asset_tile_is bakingtray_tile lagacqt
backdate "$(src_dir "$ML" analysis)"; dz lagnt "$ML" LAMBDA false STITCHN 283; up analysis "$ML" lagnt
page "$ML"; card "$ML"
check "a new StitchIt image without a thumbnail: the card shows the full image" img_src_has "$CARD" "f=main"
check "  ... not a thumbnail" bash -c '! grep -o "src=\"[^\"]*\"" <<<"$1" | grep -qF "f=tile"' _ "$CARD"
check "  ... its bytes are the new image" card_bytes_are lagnt
check "  ... the old StitchIt thumbnail is gone" same_404 "$B/$SA/$ML?f=stitchit_tile"
lag_up 280 lag3
# Without a finished section in acq's log the lag is unknown: not lagging.
rm "$(src_dir "$ML" acq)/acqLog.txt"
page "$ML"
check "acq without a log: not lagging even with StitchIt's log cut at 280" asset_is "$ML" main lag3
# A non-matching analysis stays hidden whatever its log says.
backdate "$(src_dir "$MD3" acq)"; backdate "$(src_dir "$MD3" analysis)"
dz lagh_acq "$MD3" GAMMA2 false ACQ; up acq "$MD3" lagh_acq
dz lagh_an "$MD3" OTHER2 false STITCH 100; up analysis "$MD3" lagh_an
page "$MD3"
check "non-matching analysis with a short log: hidden, its montage is a 404" same_404 "$B/$SA/$MD3?f=montage"
check "  ... and its image too" same_404 "$B/$SA/$MD3?f=stitchit"
check "  ... no StitchIt thumbnail" body_lacks "$PAGE" 'id="thumb-stitchit"'
check "  ... the version names only acq" body_lacks "$(attr_of data-version "$PAGE")" analysis

# --- shared contract (tests/web/upload_contract.json, see instructions.md): recipe IDs, names, limits ---
CONTRACT="$ROOT/tests/web/upload_contract.json"
# The recipe IDs: the cases pin the parsing rule (the MATLAB client runs the same cases from its copy).
VECTORS="$CONTRACT"
vector_results() { php -r 'require $argv[1]; foreach (json_decode(file_get_contents($argv[2]), true)["cases"] as $c) {
  $r = bs_recipe_ids($c["recipe"]);
  echo ($r["micID"] === $c["micID"] && $r["sampleID"] === $c["sampleID"] ? "ok" : "bad"), "\t", $c["name"], "\n"; }' "$APP/lib.php" "$VECTORS"; }
vec="$(vector_results)"
check "recipe ID vectors: every case in the file was run" test "$(wc -l <<<"$vec")" -eq "$(grep -c '"name"' "$VECTORS")"
while IFS=$'\t' read -r verdict name; do check "recipe ID vector: $name" test "$verdict" = ok; done <<<"$vec"
# The server's own names, zip limit and upload interval must equal the contract's.
contract_differs="$(php -r '$c = json_decode(file_get_contents($argv[1]), true); $cfg = require $argv[2]; require $argv[3];
  $bad = [];
  if (BS_ZIP_ALLOWED_NAMES !== $c["allowedNames"]) $bad[] = "allowedNames (lib.php)";
  if ($cfg["max_zip_size"] !== $c["maxZipBytes"]) $bad[] = "maxZipBytes (config.php)";
  if ($cfg["min_upload_interval_seconds"] !== $c["minUploadIntervalSec"]) $bad[] = "minUploadIntervalSec (config.php)";
  echo implode(", ", $bad);' "$CONTRACT" "$SRC/config.php" "$APP/lib.php")"
if [ -z "$contract_differs" ]; then echo "PASS  server matches the shared contract (names, zip limit, upload interval)"
else echo "FAIL  server matches the shared contract: differs: $contract_differs"; fail=1; fi
# The contract must be the version recorded as synced to the StitchIt copy. Changing it means
# syncing that copy and updating the record (instructions.md, the shared contract section).
recorded="$(cut -d' ' -f1 "$ROOT/tests/web/upload_contract.sha256")"
actual="$(php -r 'echo hash_file("sha256", $argv[1]);' "$CONTRACT")"
check "contract unchanged since its recorded sync (tests/web/upload_contract.sha256)" test "$recorded" = "$actual"
# TEMPORARY, until upload_core moves to StitchIt: the client's copy must equal the contract.
check "upload_core copy equals the contract (delete this line when upload_core moves)" cmp -s "$CONTRACT" "$ROOT/upload_core/tests/upload_contract.json"

# --- the Authorization header is found under every name a host may use ---
auth_of() { php -r 'require $argv[1]; echo bs_authorization_header(json_decode($argv[2], true));' "$APP/lib.php" "$1"; }
check "auth from HTTP_AUTHORIZATION"          test "$(auth_of '{"HTTP_AUTHORIZATION":"Bearer x"}')" = "Bearer x"
check "auth from REDIRECT_HTTP_AUTHORIZATION" test "$(auth_of '{"HTTP_AUTHORIZATION":"","REDIRECT_HTTP_AUTHORIZATION":"Bearer y"}')" = "Bearer y"
check "auth absent"                           test -z "$(auth_of '{}')"

# --- settings validation: collisions and bad values are rejected ---
# Prints "ok" for a valid file, else the reason. Reserved names are the app folder's entries.
validate() { php -r 'require $argv[1]; echo bs_validate_settings(json_decode($argv[2], true), bs_reserved_names()) ?? "ok";' "$APP/lib.php" "$1"; }
# JSON goes through variables: escaped quotes inside "$(...)" are mangled by bash 3.2.
T="$(r 16)"   # a 32-character token
site="{\"token\":\"$T\",\"microscopes\":{\"m\":{}}}"    # a valid site: its token is at site level
good="{\"panopticon\":\"w\",\"sites\":{\"s\":$site,\"t\":$site}}"
check "valid settings accepted"        test "$(validate "$good")" = ok
good="{\"sites\":{\"s\":$site}}"
check "no panopticon is allowed"       test "$(validate "$good")" = ok
good="{\"sites\":{\"s\":{\"display_name\":\"S\",\"token\":\"$T\",\"microscopes\":{\"m\":{\"display_name\":\"M\"}}}}}"
check "display names are allowed"      test "$(validate "$good")" = ok
for bad in \
  "{\"panopticon\":\"s\",\"sites\":{\"s\":$site}}" \
  "{\"panopticon\":\"S\",\"sites\":{\"s\":$site}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":$site,\"S\":$site}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"js\":$site}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"System_Data\":$site}}" \
  "{\"panopticon\":\"logs\",\"sites\":{\"s\":$site}}" \
  "{\"panopticon\":\"Upload.php\",\"sites\":{\"s\":$site}}" \
  "{\"panopticon\":\"w w\",\"sites\":{\"s\":$site}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s.x\":$site}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"token\":\"$T\",\"microscopes\":{\"m/1\":{}}}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"token\":\"$T\",\"microscopes\":{}}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"token\":\"$T\"}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"token\":\"$T\",\"microscopes\":[{}]}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"token\":\"$T\",\"microscopes\":{\"m\":\"x\"}}}}" \
  "{\"panopticon\":5,\"sites\":{\"s\":$site}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"0\":$site}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"1s\":$site}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"token\":\"$T\",\"microscopes\":{\"123\":{}}}}}" \
  "{\"panopticon\":\"w\\n\",\"sites\":{\"s\":$site}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\\n\":$site}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"token\":\"$T\",\"microscopes\":{\"m\":{},\"M\":{}}}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"microscopes\":{\"m\":{}}}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"token\":\"\",\"microscopes\":{\"m\":{}}}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"token\":\"short\",\"microscopes\":{\"m\":{}}}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"token\":\"$T $T\",\"microscopes\":{\"m\":{}}}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"token\":5,\"microscopes\":{\"m\":{}}}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"token\":\"$T\",\"microscopes\":{\"m\":{\"token\":\"$T\"}}}}}" \
  "{\"panopticon\":\"w\",\"sites\":{\"s\":{\"microscopes\":{\"m\":{\"token\":\"$T\"}}}}}" \
  "[1,2]"; do
  why="$(validate "$bad")"
  check "rejected ($why): $bad" test "$why" != ok
done

# A bad settings file is treated as empty: every view 404s, uploads 403, no details leak.
write_settings "$SA" "$SA"
check "collision: site view 404s like any missing page" same_404 "$B/$SA"
upload "$TKB" "$SB" "$MB" acq "$TMP/z/main.zip"
check "collision: upload 403" test "$STATUS" = 403
check "collision: same message as an unknown site" test "$BODY" = "$UNKSITE"
check "collision: logged on the server" grep -q 'brainsaw: invalid settings file' "$TMP/server.log"
# The old format, with the token inside each microscope, is refused whole, not half-accepted.
cat > "$SETTINGS" <<EOT
{"panopticon": "$PAN", "sites": {"$SA": {"microscopes": {"$MA1": {"token": "$TOLD"}}},
 "$SB": {"token": "$TKB", "microscopes": {"$MB": {"token": "$TOLD"}}}}}
EOT
check "old-format settings: site view 404s" same_404 "$B/$SB"
upload "$TKB" "$SB" "$MB" acq "$TMP/z/main.zip"
check "old-format settings: upload 403 even with the site token" test "$STATUS" = 403
echo '{not json' > "$SETTINGS"
check "unparsable settings: 404" same_404 "$B/$SB"
rm "$SETTINGS"
check "missing settings: 404" same_404 "$B/$SB"
write_settings "$PAN" "$SA"
fetch "$B/$SA"
check "restored settings: site view 200" test "$STATUS" = 200

exit "$fail"
