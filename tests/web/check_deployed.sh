#!/usr/bin/env bash
# Checks a deployed Brainsaw server (server-setup.md section 7).
# Usage: check_deployed.sh BASE_URL TOKEN_FILE ZIP [--big]
#   BASE_URL   e.g. https://brainsaw.org/testserver  (no trailing slash)
#   TOKEN_FILE file holding the test_site token (read, never printed)
#   ZIP        a real test zip, e.g. test_images/all_data.zip
#   --big      also upload a 30 MB zip (checks PHP size limits)
set -u
BASE="${1:?base url}"; TOKFILE="${2:?token file}"; ZIP="${3:?zip}"; BIG="${4:-}"
TOKEN="$(tr -d '[:space:]' < "$TOKFILE")"
SITE=test_site
pass=0; fail=0
check(){ # name expected actual
  if [ "$2" = "$3" ]; then printf 'PASS  %-34s %s\n' "$1" "$3"; pass=$((pass+1))
  else printf 'FAIL  %-34s expected %s, got %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
code(){ curl -s -o /dev/null -w '%{http_code}' "$@"; }
http="${BASE/https:/http:}"

loc="$(curl -sI "$http/" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')"
case "$loc" in https://*) check "http redirects to https" ok ok;; *) check "http redirects to https" ok "no redirect ($loc)";; esac
check "GET upload.php" 405 "$(code "$BASE/upload.php")"
check "no token" 401 "$(code -X POST "$BASE/upload.php" -F site_id=$SITE)"
check "wrong token" 403 "$(code -X POST "$BASE/upload.php" -H 'Authorization: Bearer wrong' -F site_id=$SITE)"
check "unknown site" 403 "$(code -X POST "$BASE/upload.php" -H "Authorization: Bearer $TOKEN" -F site_id=nope)"

sleep 6
resp="$(curl -s -X POST "$BASE/upload.php" -H "Authorization: Bearer $TOKEN" -F site_id=$SITE -F "data=@$ZIP;type=application/zip")"
case "$resp" in *'"status":"ok"'*) check "valid zip upload" ok ok;; *) check "valid zip upload" ok "$resp";; esac

sleep 6
if [ "$BIG" = "--big" ]; then
  tmp="$(mktemp -d)"; head -c 30000000 /dev/urandom > "$tmp/big.txt"; (cd "$tmp" && zip -q big.zip big.txt)
  resp="$(curl -s -X POST "$BASE/upload.php" -H "Authorization: Bearer $TOKEN" -F site_id=$SITE -F "data=@$tmp/big.zip;type=application/zip")"
  case "$resp" in *'"status":"ok"'*) check "30 MB zip upload" ok ok;; *) check "30 MB zip upload" ok "$resp";; esac
  rm -rf "$tmp"; sleep 6
  curl -s -o /dev/null -X POST "$BASE/upload.php" -H "Authorization: Bearer $TOKEN" -F site_id=$SITE -F "data=@$ZIP;type=application/zip"
fi

echo "--- protected files (must be blocked) and public files"
r="$(basename "$(unzip -Z1 "$ZIP" | grep -i 'ecipe.*ml$' | head -1)")"
a="$(basename "$(unzip -Z1 "$ZIP" | grep -i 'cqLog.*txt$' | head -1)")"
check "tokens.json blocked"   403 "$(code "$BASE/tokens.json" | sed 's/404/403/')"
check "upload.log blocked"    403 "$(code "$BASE/logs/upload.log")"
check "raw recipe blocked"    403 "$(code "$BASE/system_data/$SITE/$r")"
check "raw acq log blocked"   403 "$(code "$BASE/system_data/$SITE/$a")"
check "dir listing blocked"   403 "$(code "$BASE/system_data/")"
check "meta.json public"      200 "$(code "$BASE/system_data/$SITE/meta.json")"
check "landing page"          200 "$(code "$BASE/index.php")"
check "site page"             200 "$(code "$BASE/site.php?site=$SITE")"
check "site page has image"   1   "$(curl -s "$BASE/site.php?site=$SITE" | grep -c 'id="main-image"')"
echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
