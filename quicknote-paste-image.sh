#!/bin/bash
# Turn the clipboard image into an inline markdown data URI.
# Fixed, deterministic pipeline (no user-supplied arguments). Exits:
#   0  printed "data:image/jpeg;base64,...." on stdout
#   1  no image / conversion failed (printed nothing)
#   4  imagemagick (magick) is not installed
set -u

MAX_W="1200"
QUALITY="80"

have_image=""
if command -v wl-paste >/dev/null 2>&1; then
  have_image="$(wl-paste --list-types 2>/dev/null | grep -E '^image/' | head -n1 || true)"
fi
if [[ -z $have_image ]]; then
  exit 1
fi

if ! command -v magick >/dev/null 2>&1; then
  exit 4
fi

B64="$(wl-paste --type "$have_image" 2>/dev/null \
  | magick - -strip -resize "${MAX_W}x${MAX_W}>" -quality "$QUALITY" \
       -background white -flatten jpg:- 2>/dev/null \
  | base64 -w0 2>/dev/null || true)"

if [[ -z $B64 || ${#B64} -gt 2500000 ]]; then
  exit 1
fi

printf 'data:image/jpeg;base64,%s' "$B64"
exit 0
