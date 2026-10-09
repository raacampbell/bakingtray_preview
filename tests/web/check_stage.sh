#!/usr/bin/env bash
# Checks stage_server.sh on a throwaway git copy of this repo's working tree: an untracked
# secret is never staged, uncommitted edits to tracked files stop staging, unsafe options are
# refused, the safety net catches a token-like string, and the printed deploy command removes
# files that left the app while keeping what the server wrote (uploaded data, logs).
# Usage (from anywhere): tests/web/check_stage.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"

fail=0
check() { # description, command...
  local desc="$1"; shift
  if "$@"; then echo "PASS  $desc"; else echo "FAIL  $desc"; fail=1; fi
}
stage()   { (cd "$REPO" && ./stage_server.sh "$@") >"$TMP/out" 2>&1; }
refused() { ! stage "$@"; }
G() { git -C "$REPO" -c user.name=check -c user.email=check@invalid "$@"; }

# --- a git repo holding the working tree's tracked and new (not ignored) files ---
mkdir -p "$REPO"
while IFS= read -r -d '' f; do
  [ -f "$ROOT/$f" ] || continue
  mkdir -p "$REPO/$(dirname "$f")"
  cp "$ROOT/$f" "$REPO/$f"
done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard)
G init -q
G add -A
G commit -qm snapshot
B="$REPO/brainsaw"
OUT="$REPO/staging/livefeed"

# --- an untracked secret is never staged ---
openssl rand -hex 32 > "$B/.env"
check "stage (default livefeed) succeeds with an untracked secret present" stage
check "untracked secret not staged" test ! -e "$OUT/.env"
staged="$(cd "$OUT" && find . -type f | sed 's#^\./##' | sort)"
tracked="$(git -C "$REPO" ls-files brainsaw | sed 's#^brainsaw/##' | grep -vx 'router\.php' | sort)"
check "staged files are exactly the committed app files minus router.php" test "$staged" = "$tracked"
check "config points at the default server settings path" \
  grep -q "'settings_file' *=> '/home/raacampbell/config/brainsaw_settings.json'," "$OUT/config.php"
rm "$B/.env"

# --- uncommitted edits to tracked files stop staging ---
echo '// local edit' >> "$B/lib.php"
check "uncommitted edit to a tracked file: refused" refused
check "  ... and says why" grep -q 'uncommitted changes' "$TMP/out"
G checkout -q -- brainsaw/lib.php

# --- options ---
check "--help prints the options" bash -c 'cd "$1" && ./stage_server.sh --help | grep -q -- "--settings-path PATH"' _ "$REPO"
for d in ./ ../x . .. a/b "" "x y" /abs 'a$b' '-x'; do
  check "--dest '$d' refused" refused --dest "$d"
done
check "--dest other than livefeed needs --settings-path" refused --dest live
check "--settings-path must be absolute"                   refused --dest live --settings-path rel/settings.json
check "--settings-path with odd characters refused"        refused --dest live --settings-path "/a b/settings.json"
check "--settings-path inside the web root refused"        refused --dest live --settings-path /home/raacampbell/public_html/s.json
check "  ... also with another --webroot"                  refused --dest live --settings-path /srv/web/x/s.json --webroot /srv/web
check "unknown option refused"                             refused --tokens-path /x/tokens.json
check "--dest live with --settings-path succeeds"          stage --dest live --settings-path /srv/private/live_settings.json
check "live config points at the given path" grep -q "'settings_file' *=> '/srv/private/live_settings.json'," "$REPO/staging/live/config.php"

# --- the deploy command: --delete removes old endpoints, protect filters keep server data ---
stage
SERVER="$TMP/server/public/livefeed"
mkdir -p "$SERVER/system_data/site1/mic1" "$SERVER/logs" "$SERVER/test-upload"
echo '{"uploaded_at": "y"}' > "$SERVER/system_data/site1/mic1/meta.json"
echo 'server log' > "$SERVER/logs/upload.log"
echo '<?php' > "$SERVER/site.php"
echo '<?php' > "$SERVER/test-upload/upload.php"
cmd="$(grep -m1 -E '^ *rsync -av?z --delete' "$TMP/out" || true)"
check "a deploy command is printed" test -n "$cmd"
cmd="${cmd/-e ssh /}"
cmd="$(sed -E "s#[^ ]+:/home/raacampbell/public_html/#$TMP/server/public/#" <<<"$cmd")"   # the remote target, made local
(cd "$REPO" && eval "$cmd")
check "deploy: removed endpoint deleted"      test ! -e "$SERVER/site.php" -a ! -e "$SERVER/test-upload"
check "deploy: uploaded data kept"            test -f "$SERVER/system_data/site1/mic1/meta.json"
check "deploy: server log kept"               test -f "$SERVER/logs/upload.log"
check "deploy: app files arrived"             test -f "$SERVER/view.php" -a -f "$SERVER/system_data/.htaccess"
check "deploy: dry-run variant printed"       grep -qE '^ *rsync -av?zn --delete' "$TMP/out"

# --- the safety net: a token-like string in a committed file stops staging ---
openssl rand -hex 32 > "$B/js/oops.txt"
G add brainsaw/js/oops.txt
G commit -qm oops
check "64-hex string in a committed file: staging refused" refused
check "  ... and says why" grep -q '64-hex' "$TMP/out"

exit "$fail"
