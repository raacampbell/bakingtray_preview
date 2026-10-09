#!/usr/bin/env bash
# Build the deployable copy of the Brainsaw server in ./staging/<dest>/.
#
# Run from the project root:   ./stage_server.sh [options]
#
# What it does
#   Refuses to run if a tracked file under ./brainsaw/ has uncommitted changes, then
#   extracts ./brainsaw/ as committed in HEAD (git archive) into ./staging/<dest>/,
#   leaving out the local-only dev router. Untracked or ignored files (a local settings
#   file, logs, uploads, editor files) can therefore never be staged. It then points the
#   staged config.php at the settings file's location on the server and runs safety checks.
#
#   ./staging/ mirrors the server's `public/` folder:   staging/<dest>/  ->  public/<dest>/
#   The deploy command printed at the end does exactly that. Its --delete removes server
#   files that are no longer part of the app; its protect filters keep what the server
#   writes: uploaded data in system_data/<site>/ and logs/*.log.
#
# The staging folder holds NO secrets and is git-ignored. The settings file (sites,
# microscopes, tokens, view words) is NOT staged: it lives outside the web root on the
# server (see server-setup.md).
#
# Options
#   --dest NAME            folder under public/ to deploy into, letters, digits, _ and -
#                          only (default: livefeed)
#   --settings-path PATH   absolute path of the settings file ON THE SERVER; required
#                          unless --dest is livefeed (default for livefeed, on the
#                          GoDaddy host: /home/raacampbell/config/brainsaw_settings.json)
#   --webroot PATH         the server's web root (default: /home/raacampbell/public_html); the
#                          settings path must not be inside it
#   -h, --help             show this text
#
# Re-running is safe: ./staging/<dest>/ is rebuilt from scratch.
set -euo pipefail

DEST="livefeed"
SETTINGS_PATH=""
WEBROOT="/home/raacampbell/public_html"

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)          DEST="${2-}"; shift 2 || shift ;;
    --settings-path) SETTINGS_PATH="${2-}"; shift 2 || shift ;;
    --webroot)       WEBROOT="${2-}"; shift 2 || shift ;;
    -h|--help)       sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/brainsaw"

fail() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$SRC/lib.php" ] || fail "could not find $SRC/lib.php"
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || fail "$ROOT is not a git checkout; only committed files may be staged"
[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no -- brainsaw)" ] \
  || fail "tracked files under brainsaw/ have uncommitted changes; commit or discard them first (only HEAD is staged)"

# The name ends up in rm -rf and rsync --delete paths, so only a plain folder name is allowed.
[[ "$DEST" =~ ^[A-Za-z0-9_-]+$ ]] || fail "--dest must be letters, digits, _ or - only (got '$DEST')"
if [ -z "$SETTINGS_PATH" ]; then
  [ "$DEST" = livefeed ] || fail "--settings-path is required for --dest $DEST (each deployment has its own settings file)"
  SETTINGS_PATH="/home/raacampbell/config/brainsaw_settings.json"
fi
# Plain characters only, so the paths need no quoting in sed or PHP.
[[ "$SETTINGS_PATH" =~ ^/[A-Za-z0-9_./-]+$ ]] || fail "--settings-path must be an absolute path of letters, digits, _ . / - (got '$SETTINGS_PATH')"
[[ "$WEBROOT" =~ ^/[A-Za-z0-9_./-]+$ ]] || fail "--webroot must be an absolute path of letters, digits, _ . / - (got '$WEBROOT')"
case "$SETTINGS_PATH/" in "${WEBROOT%/}/"*) fail "--settings-path $SETTINGS_PATH is inside the web root $WEBROOT, where anyone could download it" ;; esac

OUT="$ROOT/staging/$DEST"
rm -rf "$OUT"
mkdir -p "$OUT"
git -C "$ROOT" archive --format=tar HEAD brainsaw | tar -x -C "$OUT" --strip-components 1
rm -f "$OUT/router.php"   # local-only

# --- point config.php at the server's settings file -----------------------------
CFG="$OUT/config.php"
[ "$(grep -cF "dirname(__DIR__) . '/brainsaw_settings.json'" "$CFG")" -eq 1 ] || fail "config.php no longer has the expected settings_file line; edit this script"
sed -i.bak "s#dirname(__DIR__) \. '/brainsaw_settings\.json'#'$SETTINGS_PATH'#" "$CFG"
rm -f "$CFG.bak"

# --- safety checks ------------------------------------------------------------
problems=0
note() { echo "  CHECK FAILED: $*" >&2; problems=$((problems+1)); }

echo "Checks:"
[ -z "$(find "$OUT" -name '*settings*.json' -o -name tokens.json)" ] || note "a settings or tokens file is in the staged tree"
[ -z "$(find "$OUT" -name '*.log')" ] || note "a .log file is in the staged tree"
[ -z "$(find "$OUT" -name '.*' ! -name .htaccess)" ] || note "a dotfile other than .htaccess is in the staged tree"
[ -z "$(find "$OUT" -type l)" ] || note "a symbolic link is in the staged tree"
grep -q 'E=HTTP_AUTHORIZATION' "$OUT/.htaccess" || note ".htaccess is missing the Authorization rewrite rule (uploads would fail with 401 on FastCGI hosts)"
grep -q 'RewriteRule ^ view.php' "$OUT/.htaccess" || note ".htaccess is missing the rule that sends missing paths to view.php"
grep -q -- '-MultiViews' "$OUT/.htaccess" || note ".htaccess does not switch off MultiViews"
grep -q 'Require all denied' "$OUT/system_data/.htaccess" || note "system_data/.htaccess is missing its deny rule"
grep -q 'Require all denied' "$OUT/logs/.htaccess" || note "logs/.htaccess is missing its deny rule"

# A 64-character hex string looks like a token. None should be in text files here.
leaks="$(grep -rIlE '[0-9a-fA-F]{64}' "$OUT" || true)"
[ -z "$leaks" ] || note "a 64-hex-character string (looks like a token) is in: $leaks"

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
FLAGS="--delete --chmod=D755,F644 --filter='P /system_data/*/' --filter='P /logs/*.log'"
echo
echo "Staged $(git -C "$ROOT" rev-parse --short HEAD) into: $OUT"
echo "Files:"
( cd "$OUT" && find . -type f | sort | sed 's/^\.\//  /' )
echo
echo "The settings file on the server will be read from: $SETTINGS_PATH"
echo "(it is NOT staged; put it there separately: see server-setup.md)"
echo
echo "Next: send staging/$DEST/ to the server's public/$DEST/ (USER@HOST: your SSH login). Dry run first:"
echo "rsync -avzn $FLAGS -e ssh staging/$DEST/ USER@mouse.vision:${WEBROOT%/}/$DEST/"
echo "rsync -avz $FLAGS -e ssh staging/$DEST/ USER@mouse.vision:${WEBROOT%/}/$DEST/"
