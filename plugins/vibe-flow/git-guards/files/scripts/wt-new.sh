#!/usr/bin/env bash
# wt-new.sh — a session workspace: its own directory, branch, index,
# HEAD and dev server on a free port.
#
#   wt-new.sh <name> [base]                 new tree and branch from a fresh origin/main
#   wt-new.sh --resume <branch> [name]      tree on an EXISTING branch
#   wt-new.sh <name> --new                  new, even though a similar one is in progress
#
# Everything stack-dependent (dev command, readiness marker, base port)
# comes from .gitguards.conf at the repository root.
#
# By default the new branch is based on the protected branch (GG_PROTECTED) in its
# freshest state: the script runs `git fetch` itself before creating it. An explicit
# [base] (branch, tag, commit) overrides this.
set -eu
usage() { sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GG_WT_DIR=""
GG_BRANCH_PREFIX="wt/"
GG_DEV_CMD=""
GG_DEV_PORT_BASE=3000
GG_DEV_PORT_ENV="PORT"
GG_DEV_READY_GLOBS=""
GG_DEV_READY_WAIT=80
GG_PROTECTED="main"
[ -f "$ROOT/.gitguards.conf" ] && . "$ROOT/.gitguards.conf"

RESUME=""; FORCE_NEW=0; NAME=""; BASE=""
if [ "$1" = "--resume" ]; then
    [ $# -ge 2 ] || usage
    RESUME="$2"; NAME="${3:-}"
else
    NAME="$1"; shift
    for a in "$@"; do
        case "$a" in --new) FORCE_NEW=1 ;; *) BASE="$a" ;; esac
    done
fi

# 🔴 The worktree directory is computed from the MAIN working tree, not from the
# script's location: otherwise running from a worktree creates a nested <base>/<base>/.
MAIN=$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')
WT_BASE="${GG_WT_DIR:-$(dirname "$MAIN")/$(basename "$MAIN")-wt}"
case "$WT_BASE" in /*) ;; *) WT_BASE="$(cd "$MAIN" && cd "$(dirname "$WT_BASE")" && pwd)/$(basename "$WT_BASE")" ;; esac

# ── Resuming work in progress ────────────────────────────────────────────────
# 🔴 Without this mode there was NO WAY back into an abandoned branch: the script
# could only create a new one (`worktree add -b`) and failed on an existing name with
# "branch already exists". What remained was a bare `git worktree add` — skipping
# dependency cloning, copying .env.local, installing the guards and starting dev.
if [ -n "$RESUME" ]; then
    BRANCH="$RESUME"
    git -C "$ROOT" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null \
        || { echo "🔴 no local branch $BRANCH"; exit 1; }
    EXIST=$(git -C "$ROOT" worktree list --porcelain \
        | awk -v b="refs/heads/$BRANCH" '/^worktree /{w=substr($0, 10)} /^branch /{if ($2==b) print w}')
    if [ -n "$EXIST" ]; then
        echo "🔴 branch $BRANCH is already checked out in a tree:"; echo "     $EXIST"
        echo "   Work there — git will not check out the same branch twice."; exit 1
    fi
    # The default directory is named after the branch; it may be taken by ANOTHER
    # branch, so the name is given as the third argument rather than picked silently.
    [ -n "$NAME" ] || NAME=$(basename "$BRANCH")
else
    BRANCH="$GG_BRANCH_PREFIX$NAME"

    # ── Has this work already been started? ──────────────────────────────────
    # 🔴 git itself catches identical names. But a second session that named the
    # same task differently silently branched off main and wrote everything again.
    if [ "$FORCE_NEW" = "0" ] && [ -x "$ROOT/scripts/wt-status.sh" ]; then
        UNFIN=$(bash "$ROOT/scripts/wt-status.sh" --names 2>/dev/null || true)
        if [ -n "$UNFIN" ]; then
            HITS=""
            # A shared word of 4+ letters signals "same topic". No shorter:
            # "fix", "api", "ui" would match everything, and people would stop
            # reading the warning exactly when it matters.
            for tok in $(printf '%s' "$NAME" | tr '\-_/' '   '); do
                [ ${#tok} -ge 4 ] || continue
                for b in $UNFIN; do
                    case "$b" in *"$tok"*)
                        case " $HITS " in *" $b "*) ;; *) HITS="$HITS$b ";; esac ;;
                    esac
                done
            done
            if [ -n "$HITS" ]; then
                echo "🔴 Looks like this work has already been started:"
                for b in $HITS; do printf '     %s\n' "$b"; done
                echo ""
                echo "   Continue it:            scripts/wt-new.sh --resume <branch>"
                echo "   It is a different task: scripts/wt-new.sh $NAME --new"
                exit 1
            fi
            echo "  ⚠️  there are unfinished branches (on other topics):"
            printf '%s\n' "$UNFIN" | sed 's/^/       /'
        fi
    fi
fi

DIR="$WT_BASE/$NAME"
if [ -e "$DIR" ]; then
    echo "🔴 directory already taken: $DIR"
    OCC=$(git -C "$ROOT" worktree list --porcelain | awk -v d="$DIR" '/^worktree /{w=substr($0, 10)} /^branch /{if (w==d) {sub("refs/heads/","",$2); print $2}}')
    [ -n "$OCC" ] && echo "   branch $OCC is checked out there"
    [ -n "$RESUME" ] && echo "   Give your own directory name:  scripts/wt-new.sh --resume $BRANCH <name>"
    exit 1
fi

# ── Base of the new branch ───────────────────────────────────────────────────
# 🔴 The base used to be the main working tree's HEAD. But merging happens on GitHub,
# and nobody pulls the local main branch after a merge: every new task started from
# OLD code — without the changes of neighboring branches that were already merged.
# Hence re-fixing what was already fixed, and merge conflicts. So by default the base
# is the fresh protected branch from origin, not whatever is on disk.
has_ref() { git -C "$ROOT" rev-parse --verify -q "$1^{commit}" >/dev/null 2>&1; }
short() { git -C "$ROOT" rev-parse --short "$1"; }
if [ -z "$RESUME" ] && [ -z "$BASE" ]; then
    LOCAL="refs/heads/$GG_PROTECTED"; REMOTE="refs/remotes/origin/$GG_PROTECTED"
    if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
        # No interactive password prompt and no endless wait on a dead network:
        # on failure, warn and work with what is available locally.
        GIT_TERMINAL_PROMPT=0 git -C "$ROOT" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 \
            fetch -q origin "$GG_PROTECTED" 2>/dev/null \
            || echo "  ⚠️  could not update origin/$GG_PROTECTED (no network, no access, or no such branch on origin) — using what is available locally"
    fi
    if has_ref "$REMOTE" && has_ref "$LOCAL"; then
        if git -C "$ROOT" merge-base --is-ancestor "$REMOTE" "$LOCAL"; then
            BASE="$LOCAL"       # the local branch is the same or ahead (unpushed commits)
        elif git -C "$ROOT" merge-base --is-ancestor "$LOCAL" "$REMOTE"; then
            BASE="$REMOTE"      # the usual case: local fell behind after merges on GitHub
        else
            BASE="$REMOTE"
            N=$(git -C "$ROOT" rev-list --count "$REMOTE..$LOCAL")
            echo "  ⚠️  local $GG_PROTECTED has diverged from origin/$GG_PROTECTED — base is origin/$GG_PROTECTED;"
            echo "      $N local $GG_PROTECTED commit(s) will NOT be in the new branch"
        fi
    elif has_ref "$REMOTE"; then
        BASE="$REMOTE"
    elif has_ref "$LOCAL"; then
        BASE="$LOCAL"           # repository without origin — local branch only
    else
        BASE="HEAD"             # no protected branch at all (new repository)
    fi
    case "$BASE" in
        refs/remotes/*) LABEL="${BASE#refs/remotes/}" ;;
        refs/heads/*)   LABEL="${BASE#refs/heads/}" ;;
        *)              LABEL="$BASE" ;;
    esac
    echo "  base: $LABEL ($(short "$BASE"))"

    # The main working tree is on the protected branch and behind — say so: the main
    # folder's dev server shows an old version, and that looks like breakage.
    if [ "$BASE" = "$REMOTE" ] && has_ref "$LOCAL" \
       && [ "$(git -C "$MAIN" symbolic-ref -q HEAD 2>/dev/null)" = "$LOCAL" ] \
       && git -C "$ROOT" merge-base --is-ancestor "$LOCAL" "$REMOTE"; then
        BEHIND=$(git -C "$ROOT" rev-list --count "$LOCAL..$REMOTE")
        if [ "$BEHIND" -gt 0 ]; then
            echo "  ℹ️  the main folder is behind origin/$GG_PROTECTED by $BEHIND commit(s): git -C \"$MAIN\" pull --ff-only"
        fi
    fi
fi

if [ -n "$RESUME" ]; then
    git -C "$ROOT" worktree add "$DIR" "$BRANCH"
else
    # --no-track: otherwise git would make origin/<branch> the new branch's upstream,
    # and `git status` would say "ahead of origin/main". The branch gets its own
    # upstream on the first `git push -u origin <branch>`.
    git -C "$ROOT" worktree add --no-track -b "$BRANCH" "$DIR" "$BASE"
fi

# ── Dependencies ─────────────────────────────────────────────────────────────
# node_modules: a CLONE via APFS clonefile (`cp -Rc`), NOT a symlink. Turbopack
# (Next 16) rejects a symlink pointing outside the project directory and fails
# immediately. A clone takes seconds and uses almost no space (copy-on-write).
if [ -d "$MAIN/node_modules" ]; then
    LOCK_SAME=1
    for f in package-lock.json pnpm-lock.yaml yarn.lock bun.lockb; do
        [ -f "$MAIN/$f" ] && { cmp -s "$MAIN/$f" "$DIR/$f" || LOCK_SAME=0; }
    done
    if [ "$LOCK_SAME" = "1" ]; then
        if cp -Rc "$MAIN/node_modules" "$DIR/node_modules" 2>/dev/null; then
            echo "  node_modules → APFS clone (copy-on-write)"
        else
            cp -R "$MAIN/node_modules" "$DIR/node_modules"
            echo "  node_modules → regular copy (clonefile unavailable)"
        fi
    else
        echo "  ⚠️  lockfile differs — a separate package install is needed in $DIR"
    fi
fi

# 🔴 .env.local is not tracked by git — a fresh tree lacks it, the API returns
# 500, and the cause looks like broken code.
for f in .env.local .env.development.local; do
    [ -f "$MAIN/$f" ] && [ ! -f "$DIR/$f" ] && cp "$MAIN/$f" "$DIR/$f" && echo "  $f copied"
done

bash "$ROOT/scripts/install-git-guards.sh" >/dev/null

# ── Own dev server on a free port ────────────────────────────────────────────
PORT=""
if [ -n "$GG_DEV_CMD" ]; then
    PORT="$GG_DEV_PORT_BASE"
    while lsof -i:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do PORT=$((PORT+1)); done
    printf '%s\n' ".wt-dev.pid" \
        >> "$(git -C "$DIR" rev-parse --git-path info/exclude)"

    # 🔴 THE LAUNCH FORM MATTERS, AND THE OBVIOUS ONE IS WRONG. `cd && nohup … &`
    # is backgrounded as a whole, the subshell does not exec and WAITS for the server,
    # holding the calling command's stdout; the pid file gets the wrapper's pid. Here
    # the redirects apply to the whole subshell, and exec replaces it with the server.
    # 🔴 The log goes into git's internal directory, NOT the tree: Turbopack watches the
    # tree, every log line is a "file change" to it → Fast Refresh → the browser reloads
    # → a new log line. An endless reload loop.
    DEVLOG="$(git -C "$DIR" rev-parse --absolute-git-dir)/wt-dev.log"
    ( cd "$DIR" && exec env "$GG_DEV_PORT_ENV=$PORT" nohup sh -c "$GG_DEV_CMD" ) \
        < /dev/null > "$DEVLOG" 2>&1 &
    echo $! > "$DIR/.wt-dev.pid"

    # Readiness marker: for Next it is the generated .next/types — without them
    # pre-push refuses, and the tree would be useless.
    if [ -n "$GG_DEV_READY_GLOBS" ]; then
        echo "  waiting for readiness ($GG_DEV_READY_GLOBS)…"
        WAITED=0; FOUND=0
        while [ "$WAITED" -lt "$GG_DEV_READY_WAIT" ]; do
            for g in $GG_DEV_READY_GLOBS; do [ -e "$DIR/$g" ] && FOUND=1; done
            [ "$FOUND" = "1" ] && break
            sleep 2; WAITED=$((WAITED+2))
        done
        [ "$FOUND" = "1" ] && echo "  ready ✅ — push from here will pass" \
            || echo "  ⚠️  marker did not appear within ${GG_DEV_READY_WAIT}s: $DEVLOG"
    fi
fi

echo
echo "Done: $DIR"
echo "  branch:     $BRANCH"
[ -n "$PORT" ] && echo "  dev:        http://localhost:$PORT  (pid $(cat "$DIR/.wt-dev.pid" 2>/dev/null))"
[ -n "$PORT" ] && echo "  dev log:    $DEVLOG"
echo
echo "Commit:  scripts/git-safe-commit.sh --message-file <file> -- <paths>"
echo "Push:    git push -u origin $BRANCH   (from here)"
echo "Remove:  scripts/wt-done.sh $NAME"
