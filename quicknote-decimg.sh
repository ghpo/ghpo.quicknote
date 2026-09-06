#!/bin/bash
# Decode a base64 data URI payload into a temp image file for preview.
# Usage: quicknote-decimg.sh <out-file> <base64payload>
# The payload is validated by the caller to be [A-Za-z0-9+/=]* only.
set -u
OUT="${1:-}"
B64="${2:-}"
if [[ -z $OUT || -z $B64 ]]; then exit 2; fi
mkdir -p "$(dirname "$OUT")"
printf '%s' "$B64" | base64 -d > "$OUT" 2>/dev/null
chmod 600 "$OUT" 2>/dev/null || true
exit 0
