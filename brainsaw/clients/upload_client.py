"""
Brainsaw upload client. Drop this into your acquisition pipeline after the
downsample step and call upload_latest() with the path to the downsampled
JPEG. Only TOKEN, SITE_ID and (for local testing) URL need editing.
"""

import requests

TOKEN = "THEIR_TOKEN_HERE"
SITE_ID = "THEIR_SITE_ID"
URL = "https://brainsaw.mouse.vision/brainsaw/upload.php"


def upload_latest(image_path):
    with open(image_path, "rb") as f:
        resp = requests.post(
            URL,
            headers={"Authorization": f"Bearer {TOKEN}"},
            data={"site_id": SITE_ID},
            files={"image": f},
            timeout=15,
        )
    resp.raise_for_status()
    return resp.json()


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path-to-jpeg>")
        raise SystemExit(1)
    print(upload_latest(sys.argv[1]))
