#!/usr/bin/env bash
#
# Send staging/livefeed/ to the server. Dry run by default; -s really sends it.
#
# --delete removes server files that are no longer part of the app. The two protect
# filters stop it deleting what the server itself writes: uploaded data in
# system_data/<site>/ and the upload log. The '*' in them are essential: without them
# --delete wipes all uploaded data. Keep them inside single quotes, and do not copy this
# command through anything that renders Markdown (a pair of '*' becomes italics and
# disappears).

arg='-avzn'

while getopts "s" opt; do
case "$opt" in
s) arg='-avz' ;;
*) exit 1 ;;
esac
done

rsync $arg --delete --chmod=D755,F644 \
  --filter='P /system_data/*/' \
  --filter='P /logs/*.log' \
  -e ssh staging/livefeed/ raacampbell@mouse.vision:/home/raacampbell/brainsaw/livefeed/
