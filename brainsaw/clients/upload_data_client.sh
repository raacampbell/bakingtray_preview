#!/usr/bin/env bash
# Brainsaw system_data upload client (curl, zip mode). Zips up everything in
# a directory (last completed section, montage, recipe, acquisition log(s),
# and anything else you want the server to have) and uploads it in one shot.
# The server unzips it into system_data/<site_id>/, flattening paths and
# keeping only recognized extensions (jpg/jpeg/png/txt/yml/yaml/json/csv/log).
#
# Only TOKEN/SITE_ID/URL need editing. DATA_DIR is the one argument passed at
# call time — point it at a directory containing the files to send, e.g.
# LastCompleteSection.jpg, montage.jpg, recipe_*.yml, acqLog_*.txt.
#
# Usage: upload_data_client.sh /path/to/dir_with_latest_files
set -euo pipefail

TOKEN="THEIR_TOKEN_HERE"
SITE_ID="THEIR_SITE_ID"
URL="https://brainsaw.mouse.vision/brainsaw/upload.php"
DATA_DIR="$1"

ZIP_PATH="$(mktemp -d)/system_data.zip"
( cd "$DATA_DIR" && zip -q -j "$ZIP_PATH" -- * )

curl -s -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" \
  -F "site_id=$SITE_ID" \
  -F "data=@${ZIP_PATH};type=application/zip"

rm -f "$ZIP_PATH"
