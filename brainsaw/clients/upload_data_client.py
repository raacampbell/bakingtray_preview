"""
Brainsaw system_data upload client (zip mode). Zips up every recognized file
in a directory (last completed section, montage, recipe, acquisition log(s))
and uploads it in one request. The server unzips it into
system_data/<site_id>/, flattening paths and keeping only recognized
extensions (jpg/jpeg/png/txt/yml/yaml/json/csv/log).

Only TOKEN and SITE_ID (and, for local testing, URL) need editing.
"""

import io
import zipfile
from pathlib import Path

import requests

TOKEN = "THEIR_TOKEN_HERE"
SITE_ID = "THEIR_SITE_ID"
URL = "https://brainsaw.mouse.vision/brainsaw/upload.php"

ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".txt", ".yml", ".yaml", ".json", ".csv", ".log"}


def _zip_directory(data_dir: Path) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in data_dir.iterdir():
            if path.is_file() and path.suffix.lower() in ALLOWED_EXTENSIONS:
                zf.write(path, arcname=path.name)
    return buf.getvalue()


def upload_system_data(data_dir):
    data_dir = Path(data_dir)
    zip_bytes = _zip_directory(data_dir)
    resp = requests.post(
        URL,
        headers={"Authorization": f"Bearer {TOKEN}"},
        data={"site_id": SITE_ID},
        files={"data": ("system_data.zip", zip_bytes, "application/zip")},
        timeout=60,
    )
    resp.raise_for_status()
    return resp.json()


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path-to-directory-of-files>")
        raise SystemExit(1)
    print(upload_system_data(sys.argv[1]))
