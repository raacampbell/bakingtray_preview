#!/usr/bin/env bash
# Checks a deployed Brainsaw server (server-setup.md section 7).
# Usage: check_deployed.sh BASE_URL TOKEN_FILE SITE_ID MIC_ID ZIP [--big]
#   BASE_URL   https base of the deployment, e.g. https://mouse.vision/livefeed
#   TOKEN_FILE file holding that microscope's token. It is copied into a private temp header
#              file that curl reads (-H @file), so it is never printed or on a command line.
#   SITE_ID    a site in the server's settings file (its view is BASE_URL/SITE_ID)
#   MIC_ID     one of that site's microscopes
#   ZIP        a test zip holding a recipe and an acquisition log, e.g. test_images/all_data.zip
#   --big      also upload a 30 MB zip (checks the PHP size limits)
# The panopticon word is deliberately not an argument (it would land in shell history);
# server-setup.md says how to check it by hand.
set -u
die() { echo "ERROR: $*" >&2; exit 2; }
[ $# -ge 5 ] || die "usage: $0 BASE_URL TOKEN_FILE SITE_ID MIC_ID ZIP [--big]"
BASE="${1%/}"; TOKFILE="$2"; SITE="$3"; MIC="$4"; ZIP="$5"; BIG="${6:-}"
case "$BASE" in https://*) ;; *) die "BASE_URL must start with https:// (the token must never travel unencrypted)" ;; esac
[ -s "$TOKFILE" ] || die "token file '$TOKFILE' is missing or empty"
[ -f "$ZIP" ] || die "zip '$ZIP' not found"
member() { unzip -Z1 "$ZIP" | grep -i "$1" | head -1 | sed 's#.*/##'; }   # file name of the first match
RECIPE="$(member 'ecipe.*\.ya\{0,1\}ml$')"
ACQLOG="$(member 'cqLog.*\.txt$')"
IMAGE="$(member 'LastCompleteSection.*\.jpe\{0,1\}g$')"
[ -n "$RECIPE" ] && [ -n "$ACQLOG" ] || die "the zip must contain a recipe (*recipe*.yml) and an acquisition log (*acqLog*.txt)"
[ "$(tr -d '[:space:]' < "$TOKFILE" | wc -c)" -gt 0 ] || die "token file '$TOKFILE' holds only whitespace"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
AUTH="$TMP/auth"
( umask 077; { printf 'Authorization: Bearer '; tr -d '[:space:]' < "$TOKFILE"; echo; } > "$AUTH" )
ORIGIN="$(sed -E 's#^(https://[^/]+).*#\1#' <<<"$BASE")"

pass=0; fail=0
result() { # ok?, name, detail
  if [ "$1" = 0 ]; then printf 'PASS  %-40s %s\n' "$2" "$3"; pass=$((pass+1))
  else printf 'FAIL  %-40s %s\n' "$2" "$3"; fail=$((fail+1)); fi; }
expect() { [ "$2" = "$3" ]; result $? "$1" "expected $2, got $3"; }           # name expected actual
blocked() { case "$2" in 403|404) result 0 "$1" "$2";; *) result 1 "$1" "expected 403 or 404, got $2";; esac; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
get() { curl -s -D "$TMP/h" -o "$TMP/b" -w '%{http_code}' "$@"; }           # status; headers and body to files
post() { curl -s -o "$TMP/p" -w '%{http_code}' -X POST "$BASE/upload.php" "$@"; }
has() { grep -qF -- "$2" "$1"; result $? "$3" "looked for $2"; }               # file, text, name
upload_zip() { post -H @"$AUTH" -F "site_id=$SITE" -F "microscope_id=$MIC" -F "data=@$1;type=application/zip"; }

echo "--- redirect and upload endpoint"
loc="$(curl -sI "${BASE/https:/http:}/" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')"
case "$loc" in https://*) result 0 "http redirects to https" "$loc";; *) result 1 "http redirects to https" "no redirect ($loc)";; esac
expect "GET upload.php"                 405 "$(code "$BASE/upload.php")"
expect "no token"                       401 "$(post -F "site_id=$SITE" -F "microscope_id=$MIC")"
expect "wrong token"                    403 "$(post -H 'Authorization: Bearer wrong' -F "site_id=$SITE" -F "microscope_id=$MIC")"
expect "no microscope_id"               403 "$(post -H @"$AUTH" -F "site_id=$SITE")"
expect "unknown site"                   403 "$(post -H @"$AUTH" -F "site_id=nosite$RANDOM" -F "microscope_id=$MIC")"
cp "$TMP/p" "$TMP/unknown_site"
expect "unknown microscope"             403 "$(post -H @"$AUTH" -F "site_id=$SITE" -F "microscope_id=nomic$RANDOM")"
cmp -s "$TMP/p" "$TMP/unknown_site"; result $? "unknown site/microscope: same reply" ""

sleep 6   # one upload per microscope every 5 s
s="$(upload_zip "$ZIP")"
grep -q '"status":"ok"' "$TMP/p"; ok=$?
[ "$s" = 200 ] && [ "$ok" = 0 ]; result $? "valid zip upload" "HTTP $s $(head -c 200 "$TMP/p")"
if [ "$BIG" = "--big" ]; then
  head -c 30000000 /dev/urandom > "$TMP/big.txt"; (cd "$TMP" && zip -q big.zip big.txt)
  sleep 6; s="$(upload_zip "$TMP/big.zip")"
  expect "30 MB zip upload" 200 "$s"
  sleep 6; upload_zip "$ZIP" >/dev/null   # put the real test images back
fi

echo "--- nothing private is served directly (403 or 404)"
D="system_data/$SITE/$MIC"
blocked "settings file"        "$(code "$BASE/brainsaw_settings.json")"
blocked "upload.log"           "$(code "$BASE/logs/upload.log")"
blocked "system_data/ listing" "$(code "$BASE/system_data/")"
blocked "raw meta.json"        "$(code "$BASE/$D/meta.json")"
blocked "raw recipe"           "$(code "$BASE/$D/$RECIPE")"
blocked "raw acquisition log"  "$(code "$BASE/$D/$ACQLOG")"
[ -n "$IMAGE" ] && blocked "raw section image" "$(code "$BASE/$D/$IMAGE")"
blocked "router.php (local only)" "$(code "$BASE/router.php")"
blocked "lib.php"              "$(code "$BASE/lib.php")"
s1="$(code "$BASE/system_data/$SITE/")"; s2="$(code "$BASE/system_data/nosite$RANDOM/")"
expect "system_data/<site>/: real and made-up alike" "$s1" "$s2"

echo "--- views"
s="$(get "$BASE/")"; expect "landing page" 200 "$s"
! grep -qF -- "$SITE" "$TMP/b"; result $? "landing page does not name the site" ""
s="$(get "$BASE/$SITE")"; expect "site view" 200 "$s"
grep -qF -- "/$SITE/$MIC\"" "$TMP/b"; result $? "site view links the microscope" ""
grep -qi '^referrer-policy: no-referrer' "$TMP/h"; result $? "site view: Referrer-Policy no-referrer" ""
grep -qi '^x-robots-tag: noindex' "$TMP/h"; result $? "site view: X-Robots-Tag noindex" ""
s="$(get "$BASE/$SITE/$MIC")"; expect "microscope page" 200 "$s"
has "$TMP/b" 'id="main-image"' "microscope page has the image"
src="$(grep 'id="main-image"' "$TMP/b" | sed -n 's/.*src="\([^"]*\)".*/\1/p' | sed 's/&amp;/\&/g')"
s="$(get "$ORIGIN$src")"; expect "image served through PHP" "200 image/jpeg" "$s $(tr -d '\r' < "$TMP/h" | awk 'tolower($1)=="content-type:"{print $2}')"
expect "meta through PHP" 200 "$(code "$BASE/$SITE/$MIC?f=meta")"
expect "recipe through PHP refused" 404 "$(code "$BASE/$SITE/$MIC?f=recipe")"
s1="$(get "$BASE/w$(openssl rand -hex 6)")"; cp "$TMP/b" "$TMP/word404"
s2="$(get "$BASE/no/such/$(openssl rand -hex 4)/page.html")"
[ "$s1" = 404 ] && [ "$s2" = 404 ] && cmp -s "$TMP/b" "$TMP/word404"
result $? "unknown word = random path (404, same body)" "$s1 / $s2"
s3="$(get "$BASE/$SITE/")"
[ "$s3" = 404 ] && cmp -s "$TMP/b" "$TMP/word404"
result $? "site view with a trailing slash = 404 page" "$s3"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
