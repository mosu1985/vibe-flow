#!/usr/bin/env bash
# wt-status.sh — what in the repository is NOT finished.
#
# WHY. The kit's guards were built to stop a session from grabbing OTHER sessions'
# changes, and they handle that. But there was the opposite gap: a session did not
# see ITS OWN earlier work. `CLAUDE.md` says to start with `wt-new.sh <task-name>`,
# and there was no "check whether this work has already started" step at all — so
# a second session on the same topic, naming the task slightly differently, would
# branch off main and write everything again. Verified 10.09.2026: a file made in
# the previous session is not visible in the new tree, and there is no warning.
#
#   scripts/wt-status.sh            — report for a human
#   scripts/wt-status.sh --hook     — for SessionStart: silent when everything is finished
#   scripts/wt-status.sh --names    — branch names only (for wt-new.sh)
set -eu

MODE="${1:-report}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

GG_BRANCH_PREFIX="wt/"
GG_PROTECTED="main"
[ -f "$ROOT/.gitguards.conf" ] && . "$ROOT/.gitguards.conf"

# Comparison base: both the local main branch and its remote snapshot. Work that
# reached main by any route counts as finished — including when it landed with a
# rewritten SHA and the branch itself looks behind.
BASES=""
git rev-parse --verify -q "refs/heads/$GG_PROTECTED" >/dev/null 2>&1 && BASES="$BASES refs/heads/$GG_PROTECTED"
git rev-parse --verify -q "refs/remotes/origin/$GG_PROTECTED" >/dev/null 2>&1 && BASES="$BASES refs/remotes/origin/$GG_PROTECTED"
[ -n "$BASES" ] || exit 0

# Map "branch → its worktree"
MAP=$(git worktree list --porcelain 2>/dev/null | awk '
    /^worktree /{w=substr($0, 10)} /^branch /{sub("refs/heads/","",$2); print $2"\t"w}')

LINES=""
COUNT=0
for ref in $(git for-each-ref --format='%(refname:short)' "refs/heads/$GG_BRANCH_PREFIX*" 2>/dev/null); do
    n=$(git rev-list --count "$ref" --not $BASES 2>/dev/null || echo 0)
    [ "$n" = "0" ] && continue
    COUNT=$((COUNT+1))
    # 🔴 "Did not reach main" and "exists nowhere else" are different alarms.
    # The first means "unfinished", the second "the only copy is on this disk".
    # Showing only the first would equate an abandoned branch sitting on origin
    # with work that a disk failure would destroy.
    nowhere=$(git rev-list --count "$ref" --not --remotes $BASES 2>/dev/null || echo 0)
    when=$(git log -1 --format='%ad' --date=format:'%d.%m' "$ref" 2>/dev/null)
    w=$(printf '%s\n' "$MAP" | awk -F'\t' -v b="$ref" '$1==b{print $2}')
    if [ -n "$w" ]; then
        d=$(git -C "$w" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        extra="tree: $(basename "$w")"
        [ "$d" != "0" ] && extra="$extra · uncommitted: $d"
    else
        extra="no tree → scripts/wt-new.sh --resume $ref"
    fi
    risk=""
    [ "$nowhere" != "0" ] && risk=" 🔴 $nowhere exist NOWHERE else"
    LINES="$LINES$(printf '   %-32s %2s not in %s · %s · %s%s' "$ref" "$n" "$GG_PROTECTED" "$when" "$extra" "$risk")
"
done

case "$MODE" in
  --names)
    for ref in $(git for-each-ref --format='%(refname:short)' "refs/heads/$GG_BRANCH_PREFIX*" 2>/dev/null); do
        n=$(git rev-list --count "$ref" --not $BASES 2>/dev/null || echo 0)
        [ "$n" != "0" ] && printf '%s\n' "$ref"
    done
    ;;
  --hook)
    # 🔴 Silent when everything is finished: the hook runs in EVERY session, and
    # constant noise would make it invisible exactly when it is needed.
    [ "$COUNT" = "0" ] && exit 0
    printf '🔶 The repository has unfinished work (%s branches):\n' "$COUNT"
    printf '%s' "$LINES"
    printf '   Before creating a new tree, check whether the task has already been started here.\n'
    ;;
  *)
    if [ "$COUNT" = "0" ]; then
        echo "No unfinished branches — all work is in $GG_PROTECTED."
    else
        printf '🔶 Unfinished work (%s branches):\n' "$COUNT"
        printf '%s' "$LINES"
    fi
    ;;
esac
