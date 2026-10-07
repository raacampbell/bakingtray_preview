#!/usr/bin/env bash
# Brainsaw upload client (curl). Works from any shell, or from MATLAB via
# system(). Only TOKEN/SITE_ID/URL need editing, and IMAGE_PATH is the one
# argument passed at call time.
#
# Usage: upload_client.sh /path/to/latest_downsampled.jpg
set -euo pipefail

TOKEN="THEIR_TOKEN_HERE"
SITE_ID="THEIR_SITE_ID"
URL="https://brainsaw.mouse.vision/brainsaw/upload.php"
IMAGE_PATH="$1"

curl -s -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" \
  -F "site_id=$SITE_ID" \
  -F "image=@${IMAGE_PATH}"
