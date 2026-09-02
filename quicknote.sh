#!/bin/bash
# Quick note storage helper. Ships inside the plugin; also usable standalone.
#
# Usage:
#   quicknote.sh [--dir <notesDir>] save [--file <path>] <text>
#   quicknote.sh [--dir <notesDir>] list [<limit>]
#   quicknote.sh [--dir <notesDir>] search <query> [<limit>]
#   quicknote.sh [--dir <notesDir>] view <path>

set -euo pipefail

DIR="${NOTES_DIR:-$HOME/Documents/QuickNotes}"

while [[ ${1:-} == "--dir" ]]; do
  DIR="${2:-}"
  shift 2
done

# Expand a leading tilde the same way the shell would for a literal path.
DIR="${DIR/#\~/$HOME}"
mkdir -p "$DIR"

emit_note() {
  # Emit one JSON object for a note file.
  local f="$1"
  local content title mtime stamp tags_json
  content=$(cat "$f" 2>/dev/null || true)
  title=$(printf '%s' "$content" | awk 'NF{print; exit}')
  mtime=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
  stamp=$(date -d "@$mtime" '+%d/%m %H:%M' 2>/dev/null || echo "")

  # Tags are carried with the leading '#', one per line, so QML can render
  # them as-is and a tag click becomes a literal search.
  tags_json=$(printf '%s' "$content" | grep -oE '#[A-Za-z0-9_][A-Za-z0-9_-]*' | sort -u | head -n 6 | jq -Rs 'split("\n") | map(select(length > 0))') || tags_json="[]"

  jq -cn \
    --arg path "$f" \
    --arg file "$(basename "$f")" \
    --arg title "$title" \
    --arg content "$content" \
    --arg stamp "$stamp" \
    --argjson mtime "$mtime" \
    --argjson tags "$tags_json" \
    '{path:$path, file:$file, title:$title, content:$content, stamp:$stamp, mtime:$mtime, tags:$tags}'
}

list_notes() {
  local limit="${1:-50}"
  local -a files=()
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    files+=("$f")
  done < <(find "$DIR" -maxdepth 1 -type f -name '*.md' -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2- | head -n "$limit")

  local i
  for i in "${files[@]}"; do
    emit_note "$i"
  done | jq -cs .
}

search_notes() {
  local q="${1:-}"
  local limit="${2:-50}"
  if [[ -z $q ]]; then
    list_notes "$limit"
    return
  fi

  local -a files=()
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    files+=("$f")
  done < <(find "$DIR" -maxdepth 1 -type f -name '*.md' -printf '%p\n')

  local -a out=()
  local i
  for i in "${files[@]}"; do
    if grep -qiF -- "$q" "$i"; then
      out+=("$i")
    fi
  done

  local j
  for j in "${out[@]}"; do
    printf '%s %s\n' "$(stat -c '%Y' "$j" 2>/dev/null || echo 0)" "$j"
  done | sort -rn | cut -d' ' -f2- | head -n "$limit" | while IFS= read -r k; do
    emit_note "$k"
  done | jq -cs .
}

save_note() {
  local target_file=""
  if [[ ${1:-} == "--file" ]]; then
    target_file="${2:-}"
    shift 2
  fi

  local note="${1:-}"
  if [[ -z $note ]] || [[ -z ${note//[[:space:]]/} ]]; then
    exit 0
  fi

  if [[ -n $target_file ]]; then
    mkdir -p "$(dirname "$target_file")"
    printf '%s\n' "$note" > "$target_file"
  else
    local stamp
    stamp=$(date +%Y-%m-%d_%H-%M-%S)
    printf '%s\n' "$note" > "$DIR/$stamp.md"
  fi
}

view_note() {
  local f="${1:-}"
  [[ -n $f ]] || exit 1
  cat "$f" 2>/dev/null || exit 1
}

delete_note() {
  local f="${1:-}"
  [[ -n $f ]] || exit 1
  local dir target
  dir=$(cd "$DIR" && pwd)
  target=$(cd "$(dirname "$f")" 2>/dev/null && pwd)/$(basename "$f")
  case "$target" in
    "$dir"/*.md) rm -f -- "$target" ;;
    *) echo "refusing to delete outside notes dir" >&2; exit 1 ;;
  esac
}

case "${1:-}" in
  save)   shift; save_note "$@" ;;
  list)   shift; list_notes "${1:-50}" ;;
  search) shift; search_notes "${1:-}" "${2:-50}" ;;
  view)   shift; view_note "$@" ;;
  delete) shift; delete_note "$@" ;;
  *)
    echo "usage: $(basename "$0") [--dir <notesDir>] {save|list|search|view|delete} ..." >&2
    exit 2
    ;;
esac
