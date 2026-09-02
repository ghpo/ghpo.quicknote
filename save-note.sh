#!/bin/bash

# Save a quick note to the notes dir as a timestamped markdown file.
# Compatibility wrapper — storage logic lives in quicknote-helper.c.
# Usage: save-note.sh "note text"
#
# The helper reads note bodies from stdin (NUL-terminated), so the argv note
# is piped over; this keeps the old CLI working without exposing content in
# the child argv.

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ${1:-} == --* ]]; then
  exec "$dir/quicknote.sh" save "$@"
fi

printf '%s\0' "${1:-}" | "$dir/quicknote.sh" save
