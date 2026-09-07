#!/bin/bash
# Adds/keeps the Ctrl+Alt+Enter quick-open binding for Crypto Notes in
# ~/.config/hypr/bindings.lua (idempotent) and reloads Hyprland.
set -u
CFG="${HOME}/.config/hypr/bindings.lua"
HELPER="${HOME}/.config/omarchy/plugins/ghpo.quicknote/quicknote-open.sh"
MARK="-- Crypto Notes quick-open (managed)"

mkdir -p "$(dirname "$CFG")"
if ! grep -qF "$MARK" "$CFG" 2>/dev/null; then
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
