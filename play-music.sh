#!/bin/bash
# Plays the embedded pre-rendered music (quicknote-music.ulaw, G.711 mu-law)
# with the native C player (quicknote-audio.c). The audio is pre-rendered from
# a real GM soundfont, so there is no real-time synthesis and no hiss — and no
# timidity/soundfont packages are needed at runtime (only gcc + alsa-lib).
set -euo pipefail

notify() {
  command -v omarchy-notification-send >/dev/null 2>&1 \
    && omarchy-notification-send -g 󰎚 "Quick Notes · help music" "$1" >/dev/null 2>&1 || true
}

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$dir/quicknote-audio"
ulaw="$dir/quicknote-music.ulaw"

if [[ ! -x $bin ]]; then
  for C in cc gcc clang; do
    if command -v "$C" >/dev/null 2>&1; then
      "$C" -O2 -o "$bin" "$dir/quicknote-audio.c" -lasound 2>/dev/null && break
      rm -f "$bin"
    fi
  done
fi

if [[ -x $bin && -f $ulaw ]]; then
  exec "$bin" "$ulaw"
fi

notify "Help music needs a player. Ensure cc + alsa-lib are installed."
exit 0
