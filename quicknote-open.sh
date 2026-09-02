#!/bin/bash
# Open/toggle Quick Notes with the settings saved for it in shell.json, so the
# keyboard shortcut behaves exactly like clicking the bar button. Without this,
# `omarchy-shell shell toggle ghpo.quicknote` opens the overlay with an empty
# payload and Quick Notes falls back to plain (unencrypted) mode.
set -euo pipefail

CFG="${HOME}/.config/omarchy/shell.json"
QN="ghpo.quicknote"

PAYLOAD="$(python3 - "$CFG" "$QN" <<'PY'
import json, sys
cfg, qn = sys.argv[1], sys.argv[2]

def find(obj):
    if isinstance(obj, dict):
        if obj.get("id") == qn:
            return {k: v for k, v in obj.items() if k != "id"}
        for v in obj.values():
            r = find(v)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = find(v)
            if r is not None:
                return r
    return None

try:
    data = json.load(open(cfg))
except Exception:
    data = {}
# Compact (no spaces) so the JSON survives shell word-splitting as one argument.
print(json.dumps(find(data) or {}, separators=(",", ":")))
PY
)"

exec omarchy-shell shell toggle "$QN" "$PAYLOAD"
