#!/usr/bin/env bash
# Generate a new bearer token for a Brainsaw upload site.
# Usage: scripts/generate_token.sh
set -euo pipefail
openssl rand -hex 32
