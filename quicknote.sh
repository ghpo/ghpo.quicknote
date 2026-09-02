#!/bin/bash
# Quick note storage helper. Ships inside the plugin; also usable standalone.
#
# Usage:
#   quicknote.sh [--dir <notesDir>] save [--file <path>] [--stdin-file <tmp>] [<text>]
#   quicknote.sh [--dir <notesDir>] list [<limit>]
#   quicknote.sh [--dir <notesDir>] search [--query-file <tmp>] [<query>] [<limit>]
#   quicknote.sh [--dir <notesDir>] view <path>
#   quicknote.sh [--dir <notesDir>] delete <path>
#
# Content is carried via temporary files (--stdin-file / --query-file) instead
# of argv so note bodies and queries never show up in /proc/<pid>/cmdline.
# All paths are confined to the notes dir, restricted to owned regular files,
# and every read/write is byte-bounded.

set -euo pipefail

DIR="${NOTES_DIR:-$HOME/Documents/QuickNotes}"

MAX_NOTE_BYTES=524288     # 512 KiB
MAX_QUERY_BYTES=512
MAX_FILES=500
MAX_FILE_BYTES=131072     # 128 KiB
MAX_OUTPUT_BYTES=4194304  # 4 MiB
UID_NOW="$(id -u)"

while [[ ${1:-} == "--dir" ]]; do
  DIR="${2:-}"
  shift 2
done

# Expand a leading tilde and validate the configured root before using it.
DIR="${DIR/#\~/$HOME}"
if [[ -z $DIR || ${#DIR} -gt 1024 ]]; then
  echo "invalid notes dir" >&2
  exit 2
fi
mkdir -p "$DIR" 2>/dev/null || exit 2
case "$(stat -Lc '%u' "$DIR" 2>/dev/null || echo -1)" in
  "$UID_NOW") ;;
  *) echo "notes dir not owned" >&2; exit 2 ;;
esac

# True if the file is a regular file, not a symlink, owned by the current user.
is_safe_file() {
  [[ -f $1 && ! -L $1 ]] || return 1
  [[ $(stat -c '%u' "$1" 2>/dev/null || echo -1) == "$UID_NOW" ]] || return 1
}

# Absolute path of a target inside the notes dir (expansion + containment).
resolve_target() {
  local base target
  base=$(cd "$DIR" && pwd) || return 1
  target=$(cd "$(dirname "$1")" 2>/dev/null && pwd)/$(basename "$1") || return 1
  case "$target" in
    "$base"/*.md) printf '%s' "$target" ;;
    *) return 1 ;;
  esac
}

emit_note() {
  # Emit one JSON object for a note file.
  local f="$1"
  is_safe_file "$f" || return 0
  local content title mtime stamp tags_json
  content=$(head -c "$MAX_FILE_BYTES" "$f" 2>/dev/null || true)
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
  [[ $limit =~ ^[0-9]+$ ]] || limit=50
  (( limit > MAX_FILES )) && limit=$MAX_FILES

  local -a files=()
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    files+=("$f")
  done < <(find -P "$DIR" -maxdepth 1 -name '*.md' -type f ! -type l -uid "$UID_NOW" -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2- | head -n "$limit")

  local i
  for i in "${files[@]}"; do
    emit_note "$i"
  done | jq -cs . 2>/dev/null | head -c "$MAX_OUTPUT_BYTES" || true
}

search_notes() {
  local query_file=""
  if [[ ${1:-} == "--query-file" ]]; then
    query_file="${2:-}"
    shift 2
  fi
  local q="${1:-}"
  local limit="${2:-50}"
  [[ $limit =~ ^[0-9]+$ ]] || limit=50
  (( limit > MAX_FILES )) && limit=$MAX_FILES

  if [[ -n $query_file ]]; then
    q=$(head -c "$MAX_QUERY_BYTES" "$query_file" 2>/dev/null || true)
    rm -f -- "$query_file"
  fi
  [[ ${#q} -gt $MAX_QUERY_BYTES ]] && q="${q:0:$MAX_QUERY_BYTES}"

  if [[ -z $q ]]; then
    list_notes "$limit"
    return
  fi

  local -a files=()
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    files+=("$f")
  done < <(find -P "$DIR" -maxdepth 1 -name '*.md' -type f ! -type l -uid "$UID_NOW" -printf '%p\n')

  local -a out=()
  local i
  for i in "${files[@]}"; do
    if head -c "$MAX_FILE_BYTES" "$i" 2>/dev/null | grep -qiF -- "$q"; then
      out+=("$i")
    fi
  done

  local j
  for j in "${out[@]}"; do
    printf '%s %s\n' "$(stat -c '%Y' "$j" 2>/dev/null || echo 0)" "$j"
  done | sort -rn | cut -d' ' -f2- | head -n "$limit" | while IFS= read -r k; do
    emit_note "$k"
  done | jq -cs . 2>/dev/null | head -c "$MAX_OUTPUT_BYTES" || true
}

save_note() {
  local target_file="" stdin_file=""
  while [[ ${1:-} == --* ]]; do
    case "$1" in
      --file) target_file="${2:-}"; shift 2 ;;
      --stdin-file) stdin_file="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  local note=""
  if [[ -n $stdin_file ]]; then
    note=$(head -c "$MAX_NOTE_BYTES" "$stdin_file" 2>/dev/null || true)
    rm -f -- "$stdin_file"
  else
    note="${1:-}"
    [[ ${#note} -le $MAX_NOTE_BYTES ]] || note="${note:0:$MAX_NOTE_BYTES}"
  fi
  if [[ -z $note ]] || [[ -z ${note//[[:space:]]/} ]]; then
    exit 0
  fi

  if [[ -n $target_file ]]; then
    local target
    target=$(resolve_target "$target_file") || { echo "refusing edit outside notes dir" >&2; exit 1; }
    is_safe_file "$target" || exit 1
    printf '%s\n' "$note" > "$target"
  else
    local stamp path
    stamp=$(date +%Y-%m-%d_%H-%M-%S)
    path="$DIR/$stamp-$$-$RANDOM.md"
    umask 077
    : > "$path" 2>/dev/null || exit 1
    printf '%s\n' "$note" > "$path"
    chmod 600 "$path" 2>/dev/null || true
  fi
}

view_note() {
  local f="${1:-}"
  [[ -n $f ]] || exit 1
  is_safe_file "$f" || exit 1
  head -c "$MAX_FILE_BYTES" "$f" 2>/dev/null || exit 1
}

delete_note() {
  local f="${1:-}"
  [[ -n $f ]] || exit 1
  local target
  target=$(resolve_target "$f") || { echo "refusing to delete outside notes dir" >&2; exit 1; }
  is_safe_file "$target" || exit 1
  rm -f -- "$target"
}

case "${1:-}" in
  save)   shift; save_note "$@" ;;
  list)   shift; list_notes "${1:-50}" ;;
  search) shift; search_notes "$@" ;;
  view)   shift; view_note "$@" ;;
  delete) shift; delete_note "$@" ;;
  *)
    echo "usage: $(basename "$0") [--dir <notesDir>] {save|list|search|view|delete} ..." >&2
    exit 2
    ;;
esac
