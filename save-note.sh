#!/bin/bash

# Save a quick note to the notes dir as a timestamped markdown file.
# Compatibility wrapper — the storage logic lives in quicknote.sh.
# Usage: save-note.sh "note text"

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$dir/quicknote.sh" save "$@"
