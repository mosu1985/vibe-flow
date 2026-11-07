#!/usr/bin/env bash
# wt-done.sh <name> [--force] — close a workspace: stop dev, close the Orca
# tabs, remove the directory, delete the branch, release the GitHub issue claimed
# for this branch by `wt-new.sh --issue N`.
#
# WHY A SEPARATE SCRIPT. `wt-new.sh` starts dev, but `git worktree remove`
# knows nothing about it: the directory disappears while the process lives on as
# an orphan holding the port. Verified 10.09.2026 — hung servers piled up within days.
#
# 🔴 NOTHING IS DELETED SILENTLY. Uncommitted changes and unpushed commits mean
# a stop with an explanation, not "swallowed along with the directory": that is
# exactly the loss of work the whole kit was built to prevent.
set -eu

[ $# -ge 1 ] || { echo "usage: wt-done.sh <name> [--force]"; exit 2; }
NAME="$1"; FORCE="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Project configuration ────────────────────────────────────────────────────
GG_WT_DIR=""
GG_BRANCH_PREFIX="wt/"
GG_PROTECTED="main"
GG_DEV_PROC_MATCH=""      # part of the dev process name, for killing orphans
[ -f "$ROOT/.gitguards.conf" ] && . "$ROOT/.gitguards.conf"

MAIN=$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')
WT_BASE="${GG_WT_DIR:-$(dirname "$MAIN")/$(basename "$MAIN")-wt}"
case "$WT_BASE" in /*) ;; *) WT_BASE="$(cd "$MAIN" && cd "$(dirname "$WT_BASE")" && pwd)/$(basename "$WT_BASE")" ;; esac
DIR="$WT_BASE/$NAME"

[ -d "$DIR" ] || { echo "🔴 no directory $DIR"; exit 1; }

# 🔴 THE BRANCH IS READ FROM THE TREE ITSELF, NOT DERIVED FROM THE DIRECTORY NAME.
# The old `BRANCH="wt/$NAME"` is correct only while the names match. Since
# `wt-new.sh --resume <branch> <dir-name>` exists, they legitimately diverge, and
# deriving by name at best finds no branch, and at worst finds an UNRELATED one
# with that name and deletes it. Caught 10.09.2026 while reviewing --resume.
BRANCH=$(git -C "$DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
if [ -z "$BRANCH" ]; then
    echo "🔴 $DIR has a detached HEAD — no way to determine the branch, not deleting blindly."
    echo "   Remove manually:  git worktree remove $DIR"
    exit 1
fi

# ── 1. Checks that no work will be lost ──────────────────────────────────────
# 🔴 NO PIPES WHEN READING COUNTERS. The old form
#     UNPUSHED=$(git log "@{upstream}..HEAD" 2>/dev/null | wc -l || echo "?")
# returns the status of `wc`, not `git`: with no upstream (and every fresh branch
# that has never been pushed has none) git silently printed nothing, wc gave "0",
# the "?" branch was unreachable — and cleanup WIPED the branch together with its
# unpushed commits. Exactly the loss of work this script was written to prevent.
# Caught 10.09.2026 during acceptance.
if ! DIRTY_OUT=$(cd "$DIR" && git status --porcelain 2>&1); then
    echo "🔴 could not read the state of $DIR:"
    printf '%s\n' "$DIRTY_OUT" | sed 's/^/     /'
    exit 1
fi
DIRTY=$(printf '%s' "$DIRTY_OUT" | grep -c . || true)

# Commits that exist NOWHERE except this branch: not on any remote-tracking
# ref, not in the protected branch. These are what deletion would destroy.
ORPHANED=$(cd "$DIR" && git rev-list --count HEAD \
    --not --remotes "refs/heads/$GG_PROTECTED" 2>/dev/null || echo "")
if [ -z "$ORPHANED" ]; then
    echo "🔴 could not compare the history of $NAME with the remote and $GG_PROTECTED — not deleting."
    echo "   Remove deliberately:  wt-done.sh $NAME --force"
    exit 1
fi

if [ "$FORCE" != "--force" ]; then
    if [ "$DIRTY" != "0" ]; then
        echo "🔴 $NAME has uncommitted changes ($DIRTY files):"
        printf '%s\n' "$DIRTY_OUT" | head -8 | sed 's/^/     /'
        echo
        echo "   Commit them or remove deliberately:  wt-done.sh $NAME --force"
        exit 1
    fi
    if [ "$ORPHANED" != "0" ]; then
        echo "🔴 $NAME has $ORPHANED commit(s) that are not on any remote"
        echo "   and not in $GG_PROTECTED — deleting the branch will destroy them:"
        (cd "$DIR" && git log --oneline HEAD --not --remotes "refs/heads/$GG_PROTECTED" \
            2>/dev/null | head -5 | sed 's/^/     /')
        echo
        echo "   Push them or remove deliberately:  wt-done.sh $NAME --force"
        exit 1
    fi
fi

# ── 2. Stop dev ──────────────────────────────────────────────────────────────
if [ -f "$DIR/.wt-dev.pid" ]; then
    PID=$(cat "$DIR/.wt-dev.pid" 2>/dev/null || true)
    if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
        # Kill the whole process tree: a dev server often starts its worker process
        # separately, and killing only the parent leaves the port taken.
        pkill -P "$PID" 2>/dev/null || true
        kill "$PID" 2>/dev/null || true
        sleep 1
        kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true
        echo "  dev stopped (pid $PID)"
    else
        echo "  dev is no longer running"
    fi
fi

# Safety net: a process whose working directory is this directory but whose pid file is lost.
if [ -n "$GG_DEV_PROC_MATCH" ]; then
    for p in $(lsof -t +D "$DIR" 2>/dev/null | head -20); do
        cmd=$(ps -p "$p" -o command= 2>/dev/null || true)
        case "$cmd" in
            *"$GG_DEV_PROC_MATCH"*)
                kill "$p" 2>/dev/null && echo "  killed orphaned dev (pid $p)" || true;;
        esac
    done
fi

# ── 2b. Close this workspace's Orca tabs ─────────────────────────────────────
# Relevant on machines where the project is open in Orca; elsewhere the step is silent.
#
# 🔴 The order is mandatory: BEFORE `git worktree remove`. Orca identifies a workspace
# by path, and once the directory is gone its selector answers `selector_not_found` —
# there is no regular command left to close the tabs with.
#
# Without this step the directory is removed and the branch deleted, but the workspace
# stays in the Orca sidebar: its terminal tabs are alive, their shell holds the deleted
# directory as cwd (on macOS a folder lives while someone holds it open), and Orca
# considers the workspace active. Afterwards it can only be removed by hand. That is
# how one machine's registry accumulated seven dead paths.
#
# The call is useful even with zero tabs: the response has `retiredSurfaces: true` —
# Orca marks the workspace's surfaces as retired.
#
# All best-effort: no Orca, runtime not up, output format changed — the workspace
# must be removed regardless. So every call's failure is swallowed, and under
# `set -e` only `if` is used here: `[ ... ] && echo` would crash the script exactly
# where there is nothing to close.
if command -v orca >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    CLOSED=0

    # Main path: close all of the workspace's terminals with one command.
    WT_ID=$(orca worktree list --json 2>/dev/null \
        | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
for w in d.get('result', {}).get('worktrees', []):
    if w.get('path') == sys.argv[1]:
        print(w.get('id', ''))
        break
" "$DIR" 2>/dev/null || true)

    if [ -n "${WT_ID:-}" ]; then
        N=$(orca terminal close --worktree "$WT_ID" --all --json 2>/dev/null \
            | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
print(int(d.get('result', {}).get('closed', 0) or 0))
" 2>/dev/null || true)
        CLOSED=$(( CLOSED + ${N:-0} ))
    fi

    # Cleanup: tabs bound to the path but that lost their workspace in the Orca
    # registry (that is how orphaned tabs from earlier removals linger).
    # The selector no longer works for them — close them one by one, by handle.
    for h in $(orca terminal list --json 2>/dev/null \
        | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
for t in d.get('result', {}).get('terminals', []):
    if sys.argv[1] in str(t.get('worktreeId', '')):
        h = t.get('handle')
        if h:
            print(h)
" "$DIR" 2>/dev/null || true); do
        if orca terminal close --terminal "$h" --tab --json >/dev/null 2>&1; then
            CLOSED=$(( CLOSED + 1 ))
        fi
    done

    if [ "$CLOSED" -gt 0 ]; then
        echo "  Orca tabs closed: $CLOSED"
    fi
fi

# ── 3. Remove the directory and the branch ───────────────────────────────────
git -C "$ROOT" worktree remove --force "$DIR" && echo "  directory removed: $DIR"
git -C "$ROOT" branch -D "$BRANCH" 2>/dev/null | sed 's/^/  /' || echo "  no local branch $BRANCH"

# ── 3b. Release the issue claim of this branch (wt-new.sh --issue N) ─────────
# Only claims whose owner names THIS branch: someone else's claim is not touched.
# The script removes it itself — sessions are not allowed to write into
# monitorex-locks/ directly.
COMMON=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || true)
case "$COMMON" in /*|'') ;; *) COMMON="$(cd "$ROOT/$COMMON" 2>/dev/null && pwd -P || true)" ;; esac
if [ -n "$COMMON" ]; then
    for c in "$COMMON"/monitorex-locks/claims/issue-*; do
        [ -d "$c" ] || continue
        n="${c##*/issue-}"
        case "$n" in ''|*[!0-9]*) continue ;; esac
        if [ "$(sed -n 's/^branch=//p' "$c/owner" 2>/dev/null | head -1)" = "$BRANCH" ]; then
            rm -rf "$c" && echo "  issue #$n released"
        fi
    done
fi

# ── 4. Hint about the remote branch ──────────────────────────────────────────
# 🔴 `git push origin --delete` is blocked by pre-push: a deletion sends a zero
# ref, and the hook takes it for pushing a foreign commit. There is no code in it —
# nothing to check, so the regular path is via the API, not `--no-verify`.
if git -C "$ROOT" ls-remote --heads origin "$BRANCH" 2>/dev/null | grep -q .; then
    SLUG=$(git -C "$ROOT" remote get-url origin 2>/dev/null \
        | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')
    echo
    echo "  The branch still exists on origin. If it is merged, delete it like this:"
    if [ -n "$SLUG" ]; then
        echo "    gh api -X DELETE repos/$SLUG/git/refs/heads/$BRANCH"
    else
        echo "    gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/$BRANCH"
    fi
fi

echo
echo "Done: $NAME closed."
