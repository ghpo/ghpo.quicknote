#!/bin/bash
# Plays the embedded MIDI (sandstorm.mid.b64) with the self-contained C
# synthesizer (quicknote-music.c), which needs only gcc + alsa-lib (both
# standard on Arch/Omarchy) — no timidity/fluidsynth/soundfont packages.
# Falls back to timidity if the C synth cannot be built.
set -euo pipefail

notify() {
  command -v omarchy-notification-send >/dev/null 2>&1 \
    && omarchy-notification-send -g 󰎚 "Quick Notes · help music" "$1" >/dev/null 2>&1 || true
}

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
b64="$dir/sandstorm.mid.b64"
bin="$dir/quicknote-music"
tmp="${XDG_RUNTIME_DIR:-/tmp}/omarchy-quicknote-music.mid"

if [[ ! -x $bin ]] && command -v cc >/dev/null 2>&1; then
  cc -O2 -o "$bin" "$dir/quicknote-music.c" -lasound -lm 2>/dev/null || rm -f "$bin"
fi

base64 -d -- "$b64" > "$tmp" 2>/dev/null

if [[ -x $bin ]]; then
  exec "$bin" "$tmp"
fi

# Fallback: timidity (requires timidity++ + a soundfont).
if command -v timidity >/dev/null 2>&1; then
  sf="/usr/share/soundfonts/FluidR3_GM.sf2"
  if [[ -f $sf ]]; then
    exec env TERM=xterm timidity --config-string="soundfont $sf" -in "$tmp" >/dev/null 2>&1
  else
    exec env TERM=xterm timidity -in "$tmp" >/dev/null 2>&1
  fi
fi

notify "Help music needs a synthesizer. Install timidity++ + soundfont-fluid, or ensure cc + alsa-lib are present."
exit 0
