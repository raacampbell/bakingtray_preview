#!/usr/bin/env bash
# Checks stage_server.sh on a throwaway git copy of this repo's working tree: untracked
# secrets and junk planted in brainsaw/ are never staged, unsafe options are refused, the
# safety net catches a token-like string, and the printed deploy command removes files that
# left the app while keeping what the server wrote (uploaded data, logs).
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

# --- plant things that must never be staged ---
B="$REPO/brainsaw"
printf 'SECRET=%s\n' "$(openssl rand -hex 32)" > "$B/.env"
openssl rand -hex 32 > "$B/.lib.php.swp"
echo 'a log line' > "$B/logs/extra.log"
echo '{"panopticon": "x"}' > "$B/brainsaw_settings.json"
echo '{}' > "$B/tokens.json"
echo 'notes' > "$B/js/untracked.js"
mkdir -p "$B/system_data/s/m"
echo '{"uploaded_at": "x"}' > "$B/system_data/s/m/meta.json"

check "stage (default testserver) succeeds" stage
OUT="$REPO/staging/testserver"
for f in .env .lib.php.swp logs/extra.log brainsaw_settings.json tokens.json js/untracked.js system_data/s router.php scripts; do
  check "not staged: $f" test ! -e "$OUT/$f"
done
staged="$(cd "$OUT" && find . -type f | sed 's#^\./##' | sort)"
tracked="$(git -C "$REPO" ls-files brainsaw | sed 's#^brainsaw/##' | grep -v -e '^router\.php$' -e '^scripts/' | sort)"
check "staged files are exactly the tracked app files" test "$staged" = "$tracked"
check "config points at the default server settings path" \
  grep -q "'settings_file' *=> '/home/www/www/brainsaw_private/brainsaw_settings.json'," "$OUT/config.php"

# --- options ---
for d in ./ ../x . .. a/b "" "x y" /abs 'a$b' '-x'; do
  check "--dest '$d' refused" refused --dest "$d"
done
check "--dest other than testserver needs --settings-path" refused --dest live
check "--settings-path must be absolute"                   refused --dest live --settings-path rel/settings.json
check "--settings-path with odd characters refused"        refused --dest live --settings-path "/a b/settings.json"
check "--tokens-path is gone"                              refused --tokens-path /x/tokens.json
check "--dest live with --settings-path succeeds"          stage --dest live --settings-path /srv/private/live_settings.json
check "live config points at the given path" grep -q "'settings_file' *=> '/srv/private/live_settings.json'," "$REPO/staging/live/config.php"

# --- the deploy command: --delete removes old endpoints, protect filters keep server data ---
stage
SERVER="$TMP/server/public/testserver"
mkdir -p "$SERVER/system_data/site1/mic1" "$SERVER/logs" "$SERVER/test-upload"
echo '{"uploaded_at": "y"}' > "$SERVER/system_data/site1/mic1/meta.json"
echo 'server log' > "$SERVER/logs/upload.log"
echo '<?php' > "$SERVER/site.php"
echo '<?php' > "$SERVER/test-upload/upload.php"
cmd="$(grep -m1 -E '^  rsync -az --delete' "$TMP/out" || true)"
check "a deploy command is printed" test -n "$cmd"
cmd="${cmd/-e ssh /}"
cmd="${cmd/USER@HOST:\/home\/www\/public\//$TMP/server/public/}"
(cd "$REPO" && eval "$cmd")
check "deploy: removed endpoint deleted"      test ! -e "$SERVER/site.php" -a ! -e "$SERVER/test-upload"
check "deploy: uploaded data kept"            test -f "$SERVER/system_data/site1/mic1/meta.json"
check "deploy: server log kept"               test -f "$SERVER/logs/upload.log"
check "deploy: app files arrived"             test -f "$SERVER/view.php" -a -f "$SERVER/system_data/.htaccess"
check "deploy: dry-run variant printed"       grep -qE '^  rsync -azn --delete' "$TMP/out"

# --- the safety net: a token-like string in a tracked file stops staging ---
openssl rand -hex 32 > "$B/js/oops.txt"
G add brainsaw/js/oops.txt
G commit -qm oops
check "64-hex string in a tracked file: staging refused" refused
check "  ... and says why" grep -q '64-hex' "$TMP/out"

exit "$fail"
