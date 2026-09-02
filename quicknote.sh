#!/bin/bash
# Wrapper that builds the crypto storage daemon (quicknote-crypto.c) on first
# use and execs it. The daemon reads line-framed JSON commands from stdin; the
# optional --plain flag disables encryption. Requires cc + libsodium headers
# (libsodium is standard on Arch/Omarchy).
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$dir/quicknote-crypto"

if [[ ! -x $bin ]]; then
  for C in cc gcc clang; do
    if command -v "$C" >/dev/null 2>&1; then
      "$C" -O2 -o "$bin" "$dir/quicknote-crypto.c" -lsodium 2>/dev/null && break
      rm -f "$bin"
    fi
  done
fi

if [[ -x $bin ]]; then
  exec "$bin" "$@"
fi

echo "quicknote: failed to build storage helper (needs cc + libsodium headers)" >&2
exit 3
