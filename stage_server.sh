#!/usr/bin/env bash
# Build the deployable copy of the Brainsaw server in ./staging/.
#
# Run from the project root:   ./stage_server.sh
#
# What it does
#   Copies the files that belong on the web server from ./brainsaw/ into
#   ./staging/<dest>/, leaving out everything that must never be uploaded
#   (tokens, local logs, local test data, the dev router, the test-upload canary,
#   client scripts). It then points the staged config.php at the token file's
#   location on the server and runs safety checks.
#
#   ./staging/ mirrors the server's `public/` folder, so one rsync puts everything
#   in the right place:   staging/<dest>/  ->  public/<dest>/
#
# The staging folder holds NO secrets and is git-ignored. tokens.json is NOT
# staged: it lives outside the project and outside the web root (see server-setup.md §4).
#
# Options
#   --dest NAME          folder under public/ to deploy into (default: testserver)
#   --tokens-path PATH   absolute path of tokens.json ON THE SERVER
#                        (default: /home/www/www/brainsaw_private/tokens.json)
#   --no-demo            leave out system_data/demo_site (the pre-filled demo card)
#   -h, --help           show this text
#
# Re-running is safe: ./staging/<dest>/ is rebuilt to match exactly (files that
# were staged before and are no longer wanted are removed from staging only).
set -euo pipefail

DEST="testserver"
TOKENS_PATH="/home/www/www/brainsaw_private/tokens.json"
INCLUDE_DEMO=1

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)        DEST="${2:?--dest needs a value}"; shift 2 ;;
    --tokens-path) TOKENS_PATH="${2:?--tokens-path needs a value}"; shift 2 ;;
    --no-demo)     INCLUDE_DEMO=0; shift ;;
    -h|--help)     sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/brainsaw"
STAGING="$ROOT/staging"

fail() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$SRC/lib.php" ] || fail "run this from the project root (could not find $SRC/lib.php)"
command -v rsync >/dev/null || fail "rsync not found"

# Because rsync --delete is used below, only accept a plain relative sub-folder name.
case "$DEST" in
  ""|"."|".."|/*|*..*|*[!A-Za-z0-9._/-]*) fail "--dest must be a simple relative folder name like 'testserver' (got '$DEST')" ;;
esac
case "$TOKENS_PATH" in
  /*) ;;
  *) fail "--tokens-path must be an absolute path on the server (got '$TOKENS_PATH')" ;;
esac

OUT="$STAGING/$DEST"
mkdir -p "$OUT"

EXCLUDES=(
  --exclude='.DS_Store'
  --exclude='tokens.json'
  --exclude='test-upload/'
  --exclude='router.php'
  --exclude='clients/'
  --exclude='scripts/'
  --exclude='logs/*.log'
  --exclude='system_data/sim_local/'
  --exclude='system_data/our_scope_1/'
)
if [ "$INCLUDE_DEMO" -eq 0 ]; then
  EXCLUDES+=(--exclude='system_data/demo_site/')
fi

# --delete-excluded also removes anything staged earlier that is now excluded.
rsync -a --delete --delete-excluded "${EXCLUDES[@]}" "$SRC/" "$OUT/"

# The server needs logs/ and system_data/ to exist (rsync keeps their .htaccess files).
mkdir -p "$OUT/logs" "$OUT/system_data"

# --- point config.php at the server's token file ------------------------------
CFG="$OUT/config.php"
grep -q "__DIR__ . '/tokens.json'" "$CFG" || fail "config.php no longer has the expected tokens_file line; edit this script"
python3 - "$CFG" "$TOKENS_PATH" <<'PYEOF'
import sys
cfg, path = sys.argv[1], sys.argv[2]
t = open(cfg, encoding='utf-8').read()
old = "__DIR__ . '/tokens.json'"
assert t.count(old) == 1
open(cfg, 'w', encoding='utf-8', newline='').write(t.replace(old, "'" + path.replace("\\", "\\\\").replace("'", "\\'") + "'"))
PYEOF

# --- safety checks ------------------------------------------------------------
problems=0
note() { echo "  CHECK FAILED: $*" >&2; problems=$((problems+1)); }

echo "Checks:"
[ -z "$(find "$OUT" -name tokens.json)" ] || note "a tokens.json is in the staged tree"
[ -z "$(find "$OUT" -name '*.log')" ]     || note "a .log file is in the staged tree"
grep -q 'E=HTTP_AUTHORIZATION' "$OUT/.htaccess" || note ".htaccess is missing the Authorization rewrite rule (uploads would fail with 401 on FastCGI hosts)"
grep -q 'Require all denied' "$OUT/system_data/.htaccess" || note "system_data/.htaccess is missing its deny rule"
[ -f "$OUT/logs/.htaccess" ] || note "logs/.htaccess is missing"

# A 64-character hex string looks like a token. None should be in text files here.
leaks="$(grep -rIlE '[0-9a-fA-F]{64}' "$OUT" || true)"
[ -z "$leaks" ] || note "a 64-hex-character string (looks like a token) is in: $leaks"

# Only the tokens_file line may differ from the repo's config.php.
changed="$(diff "$SRC/config.php" "$CFG" | grep -c '^[<>]' || true)"
[ "$changed" -eq 2 ] || note "config.php differs from the repo copy in more than the tokens_file line"
grep -q "'tokens_file' *=> '$TOKENS_PATH'," "$CFG" || note "config.php does not point at $TOKENS_PATH"

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
echo
echo "Staged into: $OUT"
echo "Files:"
( cd "$OUT" && find . -type f | sort | sed 's/^\.\//  /' )
echo
echo "tokens.json on the server will be read from: $TOKENS_PATH"
echo "(it is NOT staged; upload it once, separately: see server-setup.md section 4)"
echo
echo "Next: send staging/ to the server's public/ folder, for example"
echo "  rsync -avzn --chmod=D755,F644 -e ssh staging/ USER@HOST:/home/www/public/    # -n = dry run, shows what would change"
echo "  rsync -avz  --chmod=D755,F644 -e ssh staging/ USER@HOST:/home/www/public/    # the real thing"
echo "No --delete is used on purpose: it would delete uploaded site data and logs on the server."
