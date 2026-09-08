#!/bin/bash
# Adds the Ctrl+Alt+Enter quick-open binding for Crypto Notes on THIS machine
# (system keybindings live per-machine in bindings.lua). Idempotent: skips if
# the marker or the key combo already exists.
set -u
CFG="${HOME}/.config/hypr/bindings.lua"
HELPER="${HOME}/.config/omarchy/plugins/ghpo.quicknote/quicknote-open.sh"
MARK="-- Crypto Notes quick-open (managed)"

mkdir -p "$(dirname "$CFG")"

if ! grep -qF "$MARK" "$CFG" 2>/dev/null; then
  if grep -q "CTRL + ALT + RETURN" "$CFG" 2>/dev/null; then
    # Already bound on this machine (maybe not to the helper) — do not fight it.
    echo "already"
    exit 0
  fi
  {
    printf '\n'
    printf '%s\n' "$MARK"
    printf 'o.bind("CTRL + ALT + RETURN", "Crypto Notes", "%s")\n' "$HELPER"
  } >> "$CFG"
fi

if command -v hyprctl >/dev/null 2>&1; then
  hyprctl reload >/dev/null 2>&1 || true
fi
echo done
exit 0
