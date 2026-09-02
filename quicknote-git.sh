#!/bin/bash
# Git sync for Quick Notes with verbose, human-readable output.
#
# Everything is printed to stdout (git's stderr is folded in) so the app's
# sync window can show exactly what is happening: steps, git output, failures.
# Exit code stays meaningful: 0 = success, 1 = error, 2 = usage.
#
# Usage: quicknote-git.sh <dir> [remote] [sync|pull|push]
set -u

DIR="${1:-}"
REMOTE="${2:-}"
ACT="${3:-sync}"

say()  { printf 'quicknote: %s\n' "$*"; }
run()  { printf '$'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; "$@" 2>&1; }
fail() { say "ERROR: $*"; exit 1; }

# Expand a leading ~ (the app passes the literal "~/..." setting).
DIR="${DIR/#\~/$HOME}"

if [[ -z $DIR ]]; then
  say "usage: quicknote-git.sh <dir> [remote] [sync|pull|push]"
  exit 2
fi
[[ -d $DIR ]] || fail "notes dir does not exist: $DIR"
cd "$DIR" || fail "cannot enter $DIR"

# Create the repo on first use.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  say "no git repo here yet — initializing..."
  run git init -q || fail "git init failed"
fi

BR=$(git symbolic-ref --short HEAD 2>/dev/null)
if [[ -z $BR ]]; then
  BR=master
  run git checkout -q -b master 2>/dev/null || run git branch -q -M master || true
fi

# Keep the encryption seal and any stray export copies out of the repo.
if [[ ! -f .gitignore ]]; then
  say "creating .gitignore"
  printf '.quicknote-seal\nquicknote-seal\n' > .gitignore
else
  if ! grep -q '^\.quicknote-seal$' .gitignore; then
    say "adding .quicknote-seal to .gitignore"
    printf '\n.quicknote-seal\n' >> .gitignore
  fi
  if ! grep -q '^quicknote-seal$' .gitignore; then
    say "adding quicknote-seal to .gitignore"
    printf '\nquicknote-seal\n' >> .gitignore
  fi
fi

# Attach / refresh the remote.
if [[ -n $REMOTE ]]; then
  if ! git remote get-url origin >/dev/null 2>&1; then
    say "adding remote origin: $REMOTE"
    run git remote add origin "$REMOTE" || fail "could not add remote origin"
  else
    CUR=$(git remote get-url origin)
    if [[ "$CUR" != "$REMOTE" ]]; then
      say "updating remote origin: $CUR -> $REMOTE"
      run git remote set-url origin "$REMOTE" || fail "could not update remote origin"
    fi
  fi
fi
if ! git remote get-url origin >/dev/null 2>&1; then
  say "no remote configured — notes will only be committed locally."
fi

upstream_exists() { git rev-parse -q --verify "refs/remotes/origin/$BR" >/dev/null 2>&1; }

do_pull() {
  if ! git remote get-url origin >/dev/null 2>&1; then
    say "no remote — skipping pull."
    return 0
  fi
  say "fetching origin/$BR..."
  if git fetch -q origin "$BR" 2>/dev/null; then
    :
  elif git ls-remote origin >/dev/null 2>&1; then
    # Remote reachable but has no such branch (fresh repo) — nothing to pull.
    say "remote has no $BR branch yet — nothing to pull."
    return 0
  else
    say "ERROR: could not reach the remote."
    say "        check the SSH key (ssh -T git@github.com) and the repo URL."
    return 1
  fi
  if ! upstream_exists; then
    say "no local copy of origin/$BR yet — nothing to merge."
    return 0
  fi
  say "merging origin/$BR (fast-forward only)..."
  if ! git merge -q --ff-only "origin/$BR" 2>&1; then
    say "ERROR: pull/merge failed."
    say "        resolve any conflict manually in ~/Documents/QuickNotes and sync again."
    return 1
  fi
  say "local branch is up to date with origin/$BR."
  return 0
}

do_push() {
  git add -A
  local staged
  staged=$(git diff --cached --name-only 2>/dev/null | wc -l)
  if (( staged > 0 )); then
    say "committing $staged file(s)..."
    if ! git commit -q -m "notes $(date +%F_%T)" 2>&1; then
      say "ERROR: commit failed."
      return 1
    fi
  else
    say "nothing new to commit."
  fi

  if ! git remote get-url origin >/dev/null 2>&1; then
    say "no remote — changes were saved locally only."
    return 0
  fi
  if ! git rev-parse -q --verify HEAD >/dev/null 2>&1; then
    say "no local commits yet — nothing to push."
    return 0
  fi

  say "pushing to origin/$BR..."
  if upstream_exists; then
    if ! git push -q origin "$BR" 2>&1; then
      say "ERROR: push failed."
      say "        check the SSH key (ssh -T git@github.com), the repo URL and that"
      say "        the repo exists / you have write access."
      return 1
    fi
  else
    if ! git push -q -u origin "$BR" 2>&1; then
      say "ERROR: first push failed."
      say "        check the SSH key (ssh -T git@github.com), the repo URL and that"
      say "        the repo exists / you have write access."
      return 1
    fi
  fi
  say "push OK — notes are synced."
  return 0
}

rc=0
case "$ACT" in
  pull) do_pull || rc=1 ;;
  push) do_push || rc=1 ;;
  sync) do_pull || rc=1; if (( rc == 0 )); then do_push || rc=1; fi ;;
  *) say "usage: quicknote-git.sh <dir> [remote] [sync|pull|push]"; rc=2 ;;
esac

if (( rc == 0 )); then say "OK"; else say "FAILED"; fi
exit "$rc"
