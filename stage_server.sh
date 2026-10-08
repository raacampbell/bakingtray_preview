#!/usr/bin/env bash
# Build the deployable copy of the Brainsaw server in ./staging/<dest>/.
#
# Run from the project root:   ./stage_server.sh [options]
#
# What it does
#   Copies the git-TRACKED files under ./brainsaw/ (never untracked or ignored ones, so a
#   local secret, log, upload or editor file cannot be staged) into ./staging/<dest>/,
#   leaving out the local-only dev router and scripts/. It then points the staged
#   config.php at the settings file's location on the server and runs safety checks.
#   Edits to tracked files are staged as they are in the working tree.
#
#   ./staging/ mirrors the server's `public/` folder:   staging/<dest>/  ->  public/<dest>/
#   The deploy command printed at the end does exactly that.
#
# The staging folder holds NO secrets and is git-ignored. The settings file (sites,
# microscopes, tokens, view words) is NOT staged: it lives outside the web root on the
# server (see server-setup.md).
#
# Options
#   --dest NAME            folder under public/ to deploy into, letters, digits, _ and -
#                          only (default: testserver)
#   --settings-path PATH   absolute path of the settings file ON THE SERVER; required
#                          unless --dest is testserver (default for testserver:
#                          /home/www/www/brainsaw_private/brainsaw_settings.json)
#   -h, --help             show this text
#
# Re-running is safe: ./staging/<dest>/ is rebuilt from scratch.
set -euo pipefail

DEST="testserver"
SETTINGS_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)          DEST="${2-}"; shift 2 || shift ;;
    --settings-path) SETTINGS_PATH="${2-}"; shift 2 || shift ;;
    -h|--help)       sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/brainsaw"

fail() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$SRC/lib.php" ] || fail "could not find $SRC/lib.php"
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || fail "$ROOT is not a git checkout; only tracked files may be staged"

# The name ends up in rm -rf and rsync --delete paths, so only a plain folder name is allowed.
[[ "$DEST" =~ ^[A-Za-z0-9_-]+$ ]] || fail "--dest must be letters, digits, _ or - only (got '$DEST')"
if [ -z "$SETTINGS_PATH" ]; then
  [ "$DEST" = testserver ] || fail "--settings-path is required for --dest $DEST (each deployment has its own settings file)"
  SETTINGS_PATH="/home/www/www/brainsaw_private/brainsaw_settings.json"
fi
# Plain characters only, so the path needs no quoting in sed or PHP.
[[ "$SETTINGS_PATH" =~ ^/[A-Za-z0-9_./-]+$ ]] || fail "--settings-path must be an absolute path of letters, digits, _ . / - (got '$SETTINGS_PATH')"

OUT="$ROOT/staging/$DEST"
rm -rf "$OUT"
mkdir -p "$OUT"

# --- copy the tracked app files ------------------------------------------------
while IFS= read -r -d '' f; do
  rel="${f#brainsaw/}"
  case "$rel" in router.php|scripts/*) continue ;; esac   # local-only tools
  [ -f "$ROOT/$f" ] || fail "$f is tracked but missing from the working tree; commit or restore it"
  mkdir -p "$OUT/$(dirname "$rel")"
  cp "$ROOT/$f" "$OUT/$rel"
done < <(git -C "$ROOT" ls-files -z -- brainsaw)

# --- point config.php at the server's settings file -----------------------------
CFG="$OUT/config.php"
LOCAL_SETTINGS="dirname(__DIR__) . '/brainsaw_settings.json'"
[ "$(grep -cF "$LOCAL_SETTINGS" "$CFG")" -eq 1 ] || fail "config.php no longer has the expected settings_file line; edit this script"
sed -i.bak "s#dirname(__DIR__) \. '/brainsaw_settings\.json'#'$SETTINGS_PATH'#" "$CFG"
rm -f "$CFG.bak"

# --- safety checks ------------------------------------------------------------
problems=0
note() { echo "  CHECK FAILED: $*" >&2; problems=$((problems+1)); }

echo "Checks:"
[ -z "$(find "$OUT" -name '*settings*.json' -o -name tokens.json)" ] || note "a settings or tokens file is in the staged tree"
[ -z "$(find "$OUT" -name '*.log')" ] || note "a .log file is in the staged tree"
[ -z "$(find "$OUT" -name '.*' ! -name .htaccess)" ] || note "a dotfile other than .htaccess is in the staged tree"
grep -q 'E=HTTP_AUTHORIZATION' "$OUT/.htaccess" || note ".htaccess is missing the Authorization rewrite rule (uploads would fail with 401 on FastCGI hosts)"
grep -q 'RewriteRule ^ view.php' "$OUT/.htaccess" || note ".htaccess is missing the rule that sends missing paths to view.php"
grep -q -- '-MultiViews' "$OUT/.htaccess" || note ".htaccess does not switch off MultiViews"
grep -q 'Require all denied' "$OUT/system_data/.htaccess" || note "system_data/.htaccess is missing its deny rule"
grep -q 'Require all denied' "$OUT/logs/.htaccess" || note "logs/.htaccess is missing its deny rule"

# A 64-character hex string looks like a token. None should be in text files here.
leaks="$(grep -rIlE '[0-9a-fA-F]{64}' "$OUT" || true)"
[ -z "$leaks" ] || note "a 64-hex-character string (looks like a token) is in: $leaks"

# Only the settings_file line may differ from the repo's config.php.
changed="$(diff "$SRC/config.php" "$CFG" | grep -c '^[<>]' || true)"
[ "$changed" -eq 2 ] || note "config.php differs from the repo copy in more than the settings_file line"
grep -q "'settings_file' *=> '$SETTINGS_PATH'," "$CFG" || note "config.php does not point at $SETTINGS_PATH"

if command -v php >/dev/null; then
  for f in "$OUT"/*.php; do
    php -l "$f" >/dev/null 2>&1 || note "PHP syntax error in $f"
  done
else
  echo "  (php not found: skipped syntax check)"
fi

[ "$problems" -eq 0 ] || fail "$problems check(s) failed; staging is NOT safe to upload"
echo "  all checks passed"

# --- report ---------------------------------------------------------------------
# --delete removes files that left the app (old endpoints); the protect filters keep what
# the server itself writes: uploaded data in system_data/<site>/ and logs/*.log.
FLAGS="--delete --chmod=D755,F644 --filter='P /system_data/*/' --filter='P /logs/*.log'"
echo
echo "Staged into: $OUT"
echo "Files:"
( cd "$OUT" && find . -type f | sort | sed 's/^\.\//  /' )
echo
echo "The settings file on the server will be read from: $SETTINGS_PATH"
echo "(it is NOT staged; put it there separately: see server-setup.md)"
echo
echo "Next: send staging/$DEST/ to the server's public/$DEST/ (USER@HOST: your SSH login). Dry run first:"
echo "  rsync -azn $FLAGS -e ssh staging/$DEST/ USER@HOST:/home/www/public/$DEST/"
echo "  rsync -az $FLAGS -e ssh staging/$DEST/ USER@HOST:/home/www/public/$DEST/"
echo "--delete removes server files that are no longer part of the app; the two protect"
echo "filters keep uploaded data (system_data/<site>/) and the logs."
