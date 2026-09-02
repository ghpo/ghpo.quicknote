#!/bin/bash
# Git sync for Quick Notes. The notes directory is the git working tree; the
# encrypted note files (and the .quicknote-seal salt) are committed. Auth is
# handled by the user's SSH agent/key for git@... remotes.
#
# Usage: quicknote-git.sh <dir> [remote] [sync|pull|push]
set -uo pipefail

DIR="${1:?dir}"; REMOTE="${2:-}"; ACT="${3:-sync}"
cd "$DIR" || exit 1

# Create the repo on first use.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init -q
fi
BR=$(git symbolic-ref --short HEAD 2>/dev/null || echo master)
if [[ -z $(git symbolic-ref -q HEAD 2>/dev/null) ]]; then
  git checkout -q -b "$BR" 2>/dev/null || git branch -q -M "$BR"
fi

if [[ -n $REMOTE ]]; then
  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "$REMOTE" 2>/dev/null || true
  else
    git remote set-url origin "$REMOTE" 2>/dev/null || true
  fi
fi

err=""
pull_remote() {
  if git remote get-url origin >/dev/null 2>&1; then
    if git fetch -q origin "$BR" 2>/dev/null; then
      if git rev-parse --verify -q "origin/$BR" >/dev/null 2>&1; then
        git merge -q --ff-only "origin/$BR" 2>/dev/null || err="pull failed (resolve conflicts manually)"
      fi
    fi
  fi
}
push_local() {
  git add -A
  local changed=0
  git diff --cached --quiet 2>/dev/null || changed=1
  if (( changed )); then
    git commit -q -m "notes $(date +%F_%T)" 2>/dev/null || { err="commit failed"; return; }
  fi
  if git remote get-url origin >/dev/null 2>&1; then
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
      # First push of a fresh branch needs an explicit upstream.
      local upstream=0
      git rev-parse -q --verify "refs/remotes/origin/$BR" >/dev/null 2>&1 && upstream=1
      if (( upstream )); then
        git push -q origin "$BR" 2>/dev/null || err="push failed (SSH/auth?)"
      else
        git push -q -u origin "$BR" 2>/dev/null || err="push failed (SSH/auth?)"
      fi
    else
      # No commits at all (nothing to push) — not an error.
      err="nothing to sync yet (no notes/seal)"
    fi
  fi
}

case "$ACT" in
  pull) pull_remote ;;
  push) push_local ;;
  sync) pull_remote; push_local ;;
  *) echo "usage: quicknote-git.sh <dir> [remote] [sync|pull|push]" >&2; exit 2 ;;
esac

if [[ -n $err ]]; then echo "$err" >&2; exit 1; fi
echo "OK"
