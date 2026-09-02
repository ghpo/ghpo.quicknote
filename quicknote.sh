#!/bin/bash
# Wrapper that builds the secure C storage helper on first use and execs it.
# All storage logic lives in quicknote-helper.c; this file only guarantees the
# binary exists (compiled from the shipped source with the system C compiler)
# and forwards stdin/argv unchanged.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$dir/quicknote-helper"

if [[ ! -x $bin ]]; then
  cc -O2 -Wall -o "$bin" "$dir/quicknote-helper.c" 2>/dev/null \
    || { echo "quicknote: failed to build helper (cc unavailable?)" >&2; exit 3; }
fi

exec "$bin" "$@"
