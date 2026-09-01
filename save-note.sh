#!/bin/bash

# Save a quick note to $NOTES_DIR (default ~/Documents/QuickNotes) as a
# timestamped markdown file.
# Usage: save-note.sh "note text"

set -euo pipefail

DIR="${NOTES_DIR:-$HOME/Documents/QuickNotes}"
note="${1:-}"

[[ -n ${note// /} ]] || exit 0

mkdir -p "$DIR"
stamp=$(date +%Y-%m-%d_%H-%M-%S)
printf '%s\n' "$note" > "$DIR/$stamp.md"
