#!/bin/bash
# Plays the embedded MIDI (sandstorm.mid.b64) synthesized with timidity.
# The MIDI is decoded from base64 to a per-user runtime path, so no external
# .mid file is needed. TERM is pinned (the shell runs headless) and output is
# silenced; this script execs timidity, so the caller's process handle IS the
# player (killing it stops the music).
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
b64="$dir/sandstorm.mid.b64"

tmp="${XDG_RUNTIME_DIR:-/tmp}/omarchy-quicknote-music.mid"
base64 -d -- "$b64" > "$tmp" 2>/dev/null

exec env TERM=xterm timidity -in "$tmp" >/dev/null 2>&1
