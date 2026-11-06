#!/usr/bin/env bash
# git-lock.sh — state and release of the kit's locks. There is deliberately no
# auto-release: a stale lock is reported to a human and waits for their decision.
#
#   status   — what is held, by whom, whether the process is alive, any unfinished transaction
#   release  — release after confirmation; in the post-cas phase it repairs the index first
#   take     — take the commit lock for a maintenance operation (merge/rebase/cherry-pick)
#              ONLY in a linked worktree: pre-commit requires it when MERGE_HEAD exists
#   drop     — release a lock taken by `take` in the same session
#
# take/drop are for the agent: in its own worktree the index is its own, and the
# lock is only needed so that a merge commit does not move refs at the same time as
# someone else's safe-commit. Hold the lock only for the commit: take → commit → drop.
set -eu
COMMON=$(git rev-parse --git-common-dir); case "$COMMON" in /*) ;; *) COMMON="$(cd "$COMMON" && pwd -P)";; esac
LOCKDIR="$COMMON/monitorex-locks"; LOCK="$LOCKDIR/commit"; JOURNAL="$LOCKDIR/journal"
IDXPATH=$(git rev-parse --git-path index); case "$IDXPATH" in /*) ;; *) IDXPATH="$(pwd -P)/$IDXPATH";; esac
IDXLOCK="$IDXPATH.lock"
field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null && echo "alive" || echo "DEAD"; }
age()   { [ -f "$1" ] && echo "$(( ($(date +%s) - $(stat -f %m "$1")) ))s" || echo "-"; }

show() {
  echo "=== Locks ==="
  if [ -d "$LOCK" ] && [ "$(field "$LOCK/owner" purpose)" = "take" ]; then
    echo "commit lock: held via take   actor=$(field "$LOCK/owner" actor)  tree=$(field "$LOCK/owner" worktree)  age $(age "$LOCK/owner")"
  elif [ -d "$LOCK" ]; then
    echo "commit lock: held   actor=$(field "$LOCK/owner" actor)  pid=$(field "$LOCK/owner" pid) ($(alive "$(field "$LOCK/owner" pid)"))  age $(age "$LOCK/owner")"
  else echo "commit lock: free"; fi
  if [ -f "$IDXLOCK" ]; then
    echo "index.lock: held   actor=$(field "$IDXLOCK" actor)  pid=$(field "$IDXLOCK" pid) ($(alive "$(field "$IDXLOCK" pid)"))  age $(age "$IDXLOCK")"
  else echo "index.lock: free"; fi
  if [ -f "$JOURNAL" ]; then
    echo
    echo "🔴 Unfinished transaction, phase: $(field "$JOURNAL" phase)"
    echo "   branch $(field "$JOURNAL" branch): $(field "$JOURNAL" old) → $(field "$JOURNAL" new)"
    [ "$(field "$JOURNAL" phase)" = "post-cas" ] && echo "   The branch has moved, the index is NOT in sync — run release (it will repair it)."
  fi
}

case "${1:-status}" in
  status) show ;;
  release)
    show; echo
    printf 'Release the locks? In the post-cas phase the index will be reset to the new HEAD. [yes/no] '
    read -r a; { [ "$a" = "yes" ] || [ "$a" = "да" ]; } || { echo "cancelled"; exit 1; }  # "да" kept for existing Russian-speaking users
    if [ -f "$JOURNAL" ] && [ "$(field "$JOURNAL" phase)" = "post-cas" ]; then
      NEW=$(field "$JOURNAL" new); TMP=$(mktemp -t monitorex-idxrepair)
      GIT_INDEX_FILE="$TMP" git read-tree "$NEW" && mv "$TMP" "$IDXPATH" && rm -f "$JOURNAL" \
        && echo "index reset to $NEW" || { rm -f "$TMP"; echo "🔴 repair failed"; exit 1; }
    fi
    rm -f "$IDXLOCK"; rm -rf "$LOCK"; echo "locks released" ;;
  take)
    GD=$(git rev-parse --git-dir); case "$GD" in /*) ;; *) GD="$(cd "$GD" && pwd -P)";; esac
    [ "$GD" != "$COMMON" ] || { echo "🔴 take works only in a linked worktree (scripts/wt-new.sh); in the main working tree use git-safe-commit.sh"; exit 1; }
    [ ! -f "$JOURNAL" ] || { echo "🔴 unfinished transaction — run status / release first"; exit 1; }
    mkdir -p "$LOCKDIR"
    mkdir "$LOCK" 2>/dev/null || { show; echo; echo "🔴 commit lock is held — wait and retry"; exit 1; }
    printf 'actor=%s\npid=\npurpose=take\nworktree=%s\n' "${CLAUDE_CODE_SESSION_ID:-${MONITOREX_ACTOR:-manual}}" "$(pwd -P)" > "$LOCK/owner"
    echo "commit lock taken — make the commit and right after: scripts/git-lock.sh drop" ;;
  drop)
    [ -d "$LOCK" ] || { echo "commit lock is free"; exit 0; }
    ME="${CLAUDE_CODE_SESSION_ID:-${MONITOREX_ACTOR:-manual}}"
    if [ "$(field "$LOCK/owner" purpose)" != "take" ] || [ "$(field "$LOCK/owner" actor)" != "$ME" ]; then
      show; echo; echo "🔴 the lock was not taken via take by this session — it cannot be released here (release is for a human)"; exit 1
    fi
    rm -rf "$LOCK"; echo "commit lock released" ;;
  *) echo "usage: git-lock.sh [status|release|take|drop]"; exit 2 ;;
esac
