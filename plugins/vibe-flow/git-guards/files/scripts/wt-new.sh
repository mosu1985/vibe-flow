#!/usr/bin/env bash
# wt-new.sh — a session workspace: its own directory, branch, index,
# HEAD and dev server on a free port.
#
#   wt-new.sh <name> [base]                 new tree and branch from a fresh origin/main
#   wt-new.sh --issue N [name]              claim GitHub issue N, branch wt/N-<title-slug>
#   wt-new.sh --resume <branch> [name]      tree on an EXISTING branch
#   wt-new.sh --resume <branch> --merge-main   … and merge origin/<protected> into it
#   wt-new.sh <name> --new                  new, even though a similar one is in progress
#
# Everything stack-dependent (dev command, readiness marker, base port)
# comes from .gitguards.conf at the repository root.
#
# By default the new branch is based on the protected branch (GG_PROTECTED) in its
# freshest state: the script runs `git fetch` itself before creating it. An explicit
# [base] (branch, tag, commit) overrides this.
#
# --issue N claims the issue LOCALLY (nothing is written to GitHub): the claim is a
# directory $COMMON/monitorex-locks/claims/issue-N, taken atomically before the tree
# is created and released by wt-done.sh. A second session with the same N is refused.
set -eu
usage() { sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
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
GG_FETCH_TIMEOUT=20
GG_DEPS_INSTALL_CMD=""
GG_ISSUE_TIMEOUT=15
[ -f "$ROOT/.gitguards.conf" ] && . "$ROOT/.gitguards.conf"

RESUME=""; FORCE_NEW=0; NAME=""; BASE=""
ISSUE=""; ISSUE_SET=0; MERGE_MAIN=0; NPOS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --resume)     [ $# -ge 2 ] && [ -n "$2" ] || usage; RESUME="$2"; shift 2; continue ;;
        --issue)      [ $# -ge 2 ] || usage; ISSUE="$2"; ISSUE_SET=1; shift 2; continue ;;
        --issue=*)    ISSUE="${1#--issue=}"; ISSUE_SET=1 ;;
        --new)        FORCE_NEW=1 ;;
        --merge-main) MERGE_MAIN=1 ;;
        *)  NPOS=$((NPOS+1))
            # 1st positional = name; later ones = base (the last one wins, as before).
            # With --resume the base is meaningless and ignored, as before.
            if [ "$NPOS" -eq 1 ]; then NAME="$1"; else BASE="$1"; fi ;;
    esac
    shift
done
if [ -n "$RESUME" ] && [ "$ISSUE_SET" = "1" ]; then
    echo "🔴 --issue cannot be combined with --resume: an existing branch already has its claim"; exit 2
fi
if [ "$MERGE_MAIN" = "1" ] && [ -z "$RESUME" ]; then
    echo "🔴 --merge-main only works with --resume <branch>"; exit 2
fi
if [ "$ISSUE_SET" = "1" ]; then
    # 🔴 Strict: the number becomes a directory name and a gh argument. "07" vs "7"
    # would be two different claims of one issue; "../x" would escape claims/;
    # "-R=x" would become a gh option.
    if ! [[ "$ISSUE" =~ ^[1-9][0-9]{0,6}$ ]]; then
        echo "🔴 --issue expects an issue number (1-9999999), got: $(printf '%q' "$ISSUE")"; exit 2
    fi
elif [ -z "$RESUME" ] && [ -z "$NAME" ]; then
    usage
fi

# 🔴 The worktree directory is computed from the MAIN working tree, not from the
# script's location: otherwise running from a worktree creates a nested <base>/<base>/.
MAIN=$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')
WT_BASE="${GG_WT_DIR:-$(dirname "$MAIN")/$(basename "$MAIN")-wt}"
case "$WT_BASE" in /*) ;; *) WT_BASE="$(cd "$MAIN" && cd "$(dirname "$WT_BASE")" && pwd)/$(basename "$WT_BASE")" ;; esac

COMMON=$(git -C "$ROOT" rev-parse --git-common-dir)
case "$COMMON" in /*) ;; *) COMMON="$(cd "$ROOT/$COMMON" && pwd -P)" ;; esac
has_ref() { git -C "$ROOT" rev-parse --verify -q "$1^{commit}" >/dev/null 2>&1; }

# ── Watchdog ─────────────────────────────────────────────────────────────────
# 🔴 macOS has no `timeout`, and git has no connect timeout for HTTP: on a dead
# route fetch hung for the system TCP timeout (~75 s). Hence our own watchdog.
# The watcher kills its own `sleep` when the command finishes in time: otherwise
# every call left a sleeping process behind for the full timeout.
run_with_timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    (
        trap 'kill "$s" 2>/dev/null; exit 0' TERM
        sleep "$secs" & s=$!
        wait "$s"
        pkill -TERM -P "$pid" 2>/dev/null || true     # its children too (wrapper scripts)
        kill -TERM "$pid" 2>/dev/null || exit 0
        sleep 2 & s=$!
        wait "$s"
        kill -KILL "$pid" 2>/dev/null || true
    ) </dev/null >/dev/null 2>&1 &
    local watcher=$!
    local rc=0
    wait "$pid" || rc=$?
    kill -TERM "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true   # otherwise bash prints "Terminated: 15"
    return "$rc"
}

# ── Protected branch (the kit-wide rule) ─────────────────────────────────────
# origin/HEAD → origin/main → origin/master; without an origin remote — the MAIN
# working tree's .gitguards.conf, read as text (never sourced), or "main".
conf_value() {      # $1 = file, $2 = key → value with one pair of quotes removed
    [ -f "$1" ] || return 1
    local v
    v=$(sed -n "s/^$2=//p" "$1" | tail -1)
    [ -n "$v" ] || return 1
    case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; \'*\') v="${v#\'}"; v="${v%\'}" ;; esac
    printf '%s\n' "$v"
}
gg_protected() {
    local r b
    if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
        r=$(git -C "$ROOT" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)
        case "$r" in refs/remotes/origin/?*) printf '%s\n' "${r#refs/remotes/origin/}"; return ;; esac
        for b in main master; do
            if has_ref "refs/remotes/origin/$b"; then printf '%s\n' "$b"; return; fi
        done
    fi
    r=$(conf_value "$(dirname "$COMMON")/.gitguards.conf" GG_PROTECTED || true)
    case "$r" in ''|-*|*[!A-Za-z0-9._/-]*) r="main" ;; esac
    printf '%s\n' "$r"
}

# ── Issue lookup (--issue N) ─────────────────────────────────────────────────
# Read-only: `gh issue view`. Nothing is written to GitHub — the claim is local.
ISSUE_TITLE=""; ISSUE_SLUG=""; TMPFILES=""
if [ "$ISSUE_SET" = "1" ]; then
    # The repository is passed explicitly: with several remotes or a `gh repo
    # set-default` pointing at a fork, gh would otherwise read someone else's issue.
    OURL=$(git -C "$ROOT" remote get-url origin 2>/dev/null) \
        || { echo "🔴 no origin remote — cannot look up issue #$ISSUE"; exit 1; }
    OPATH=$(printf '%s' "$OURL" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://[^/]*/##; s#^[^@/]+@[^:/]+:##; s#/+$##; s#\.git$##')
    OOWNER=$(basename "$(dirname "$OPATH")"); OREPO=$(basename "$OPATH")
    case "$OOWNER$OREPO" in *[!A-Za-z0-9_.-]*|'') OOWNER="" ;; esac
    case "$OOWNER" in -*|.|'') echo "🔴 cannot derive owner/repo from origin ($OURL)"; exit 1 ;; esac
    ISSUE_REPO="$OOWNER/$OREPO"

    command -v gh >/dev/null 2>&1 || {
        echo "🔴 gh (GitHub CLI) not found — it is needed to check issue #$ISSUE."
        echo "   Install it (https://cli.github.com) and run: gh auth login"
        exit 1; }
    command -v python3 >/dev/null 2>&1 || { echo "🔴 python3 not found — needed to read the gh answer"; exit 1; }

    GH_OUT=$(mktemp); GH_ERR=$(mktemp); TMPFILES="$GH_OUT $GH_ERR"
    trap 'rm -f $TMPFILES' EXIT     # replaced by cleanup() below
    T0=$SECONDS; GHRC=0
    run_with_timeout "$GG_ISSUE_TIMEOUT" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
        gh issue view "$ISSUE" --repo "$ISSUE_REPO" --json number,title,state \
        < /dev/null > "$GH_OUT" 2> "$GH_ERR" || GHRC=$?
    if [ "$GHRC" != "0" ]; then
        # Only printable ASCII of gh's message reaches the terminal (and the model).
        GHMSG=$(LC_ALL=C tr -cd '\11\12\40-\176' < "$GH_ERR" | sed -n '1,3p')
        if [ $((SECONDS - T0)) -ge "$GG_ISSUE_TIMEOUT" ]; then
            echo "🔴 gh did not answer within ${GG_ISSUE_TIMEOUT}s — issue #$ISSUE not checked (network?)"
        elif printf '%s' "$GHMSG" | grep -qiE 'auth login|not logged|authenticat|bad credentials|HTTP 401'; then
            echo "🔴 gh is not authenticated — run: gh auth login"
        elif printf '%s' "$GHMSG" | grep -qiE 'could not resolve|not found|HTTP 404|no issue'; then
            echo "🔴 issue #$ISSUE not found in $ISSUE_REPO"
        else
            echo "🔴 gh failed (exit $GHRC) while reading issue #$ISSUE in $ISSUE_REPO:"
            printf '%s\n' "$GHMSG" | sed 's/^/     /'
        fi
        exit 1
    fi
    # Title → slug: [a-z0-9-] only, at most 40 characters. The title is written by
    # anyone who can open an issue: no "../", no leading "-", no newlines, no
    # invisible format characters (Cf) may reach the branch name, the path or the output.
    PARSED=$(python3 - "$ISSUE" "$GH_OUT" "$NAME" <<'PY' || true
import json, re, sys, unicodedata
n, path, name = int(sys.argv[1]), sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    print("ERR\tgh returned something that is not JSON"); sys.exit(0)
if not isinstance(d, dict) or d.get("number") != n:
    print("ERR\tgh returned a different issue"); sys.exit(0)
title = str(d.get("title") or "")
title = "".join(" " if c in "\t\r\n" else c for c in title
                if unicodedata.category(c) not in ("Cc", "Cf") or c in "\t\r\n")
title = re.sub(r"\s+", " ", title).strip()[:120]
def slug(s):
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:40].strip("-")
    return s or "issue"
state = str(d.get("state") or "").upper()
print("%s\t%s\t%s" % (re.sub(r"[^A-Z_]", "", state) or "UNKNOWN", slug(name or title), title))
PY
)
    IFS="$(printf '\t')" read -r ISTATE ISSUE_SLUG ISSUE_TITLE <<EOF2
$PARSED
EOF2
    case "$ISTATE" in
        OPEN) ;;
        ERR)    echo "🔴 issue #$ISSUE: $ISSUE_SLUG"; exit 1 ;;
        CLOSED) echo "🔴 issue #$ISSUE is closed: $ISSUE_TITLE"
                echo "   Reopen it on GitHub first, or start without --issue."; exit 1 ;;
        *)      echo "🔴 issue #$ISSUE has state $ISTATE, expected OPEN"; exit 1 ;;
    esac
    echo "  issue #$ISSUE ($ISSUE_REPO): $ISSUE_TITLE"
    NAME="$ISSUE-$ISSUE_SLUG"
fi

# ── Refresh the protected branch from origin ─────────────────────────────────
# Done BEFORE the "already started" check below: that check compares branches with
# origin/<protected>, and against a stale ref, branches already merged on GitHub
# look unfinished and block the new task for nothing. --resume needs it too: the
# guards of an old branch are compared with the FRESH origin/<protected>.
if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
    # No interactive password prompt and no endless wait on a dead network:
    # on failure, warn and work with what is available locally.
    if ! run_with_timeout "$GG_FETCH_TIMEOUT" env GIT_TERMINAL_PROMPT=0 \
            git -C "$ROOT" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 \
            fetch -q origin "$GG_PROTECTED" 2>/dev/null; then
        echo "  ⚠️  could not update origin/$GG_PROTECTED within ${GG_FETCH_TIMEOUT}s (no network, no access, or no such branch on origin) — using what is available locally"
    fi
fi
PROT=$(gg_protected)

# Guard files of a branch vs the protected branch on origin. An old branch brings
# old copies: its install-git-guards.sh (run by `npm install` → prepare) would put
# old hooks into the SHARED monitorex-hooks, and a session started in its tree
# would load an old PreToolUse guard. Prints the differing paths.
GUARD_FILES="scripts/install-git-guards.sh .claude/hooks/monitorex_git_guard.py"
outdated_guards() {     # $1 = revision of the branch
    local ref="refs/remotes/origin/$PROT" f a b out=""
    has_ref "$ref" || return 0          # nothing to compare with
    for f in $GUARD_FILES; do
        b=$(git -C "$ROOT" rev-parse -q --verify "$ref:$f" 2>/dev/null) || continue   # bootstrap
        a=$(git -C "$ROOT" rev-parse -q --verify "$1:$f" 2>/dev/null || echo none)
        [ "$a" = "$b" ] || out="$out $f"
    done
    printf '%s' "${out# }"
}

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
    OUTDATED=$(outdated_guards "refs/heads/$BRANCH")
    if [ -n "$OUTDATED" ] && [ "$MERGE_MAIN" = "0" ]; then
        echo "🔴 branch $BRANCH carries outdated guards (differ from origin/$PROT):"
        for f in $OUTDATED; do printf '     %s\n' "$f"; done
        echo "   Its tree would reinstall old hooks for the whole repository."
        echo "   Merge origin/$PROT into it:  scripts/wt-new.sh --resume $BRANCH${NAME:+ $NAME} --merge-main"
        exit 1
    fi
    # The default directory is named after the branch; it may be taken by ANOTHER
    # branch, so the name is given as the third argument rather than picked silently.
    [ -n "$NAME" ] || NAME=$(basename "$BRANCH")
else
    BRANCH="$GG_BRANCH_PREFIX$NAME"

    # ── Has this work already been started? ──────────────────────────────────
    # 🔴 git itself catches identical names. But a second session that named the
    # same task differently silently branched off main and wrote everything again.
    # With --issue the claim below is the authority (by number, not by words).
    if [ "$ISSUE_SET" = "0" ] && [ "$FORCE_NEW" = "0" ] && [ -x "$ROOT/scripts/wt-status.sh" ]; then
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

# ── Claim the issue (--issue N) ──────────────────────────────────────────────
# $COMMON/monitorex-locks/claims/issue-N, created with mkdir (atomic: of two
# sessions exactly one succeeds) BEFORE `git worktree add`; the owner file is
# prepared next to it and renamed inside, so nobody ever reads a half-written one.
# A failed tree creation releases the claim (trap below).
#
# The claim is LIVE while its branch is checked out in some tree, or the branch has
# commits that are not in the protected branch (sessions commit late: a branch with
# no commits but a living tree is still taken), or the claiming wt-new.sh (owner
# pid) is still running, or the owner file is not written yet and the directory is
# younger than 60 s. Otherwise it is stale and may be taken
# over — under the mutex issue-N.takeover, re-checking that the claim is still the
# same one (owner nonce) before moving it away.
CLAIM_DIR=""; CLAIM_NONCE=""; CLAIM_KEEP=0; MUTEX_DIR=""; OWN_TMP=""
cleanup() {
    if [ -n "$MUTEX_DIR" ] && [ "$(cat "$MUTEX_DIR/pid" 2>/dev/null || true)" = "$$" ]; then
        rm -rf "$MUTEX_DIR"
    fi
    if [ -n "$CLAIM_DIR" ] && [ "$CLAIM_KEEP" = "0" ] \
       && [ "$(sed -n 's/^nonce=//p' "$CLAIM_DIR/owner" 2>/dev/null | head -1)" = "$CLAIM_NONCE" ]; then
        rm -rf "$CLAIM_DIR"
        echo "  claim of issue #$ISSUE released (the tree was not created)"
    fi
    [ -z "$OWN_TMP" ] || rm -f "$OWN_TMP"
    [ -z "$TMPFILES" ] || rm -f $TMPFILES
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

file_age() {        # seconds since mtime; huge when unknown
    local m
    m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true)
    case "$m" in ''|*[!0-9]*) echo 999999 ;; *) echo $(( $(date +%s) - m )) ;; esac
}
owner_get() { sed -n "s/^$2=//p" "$1/owner" 2>/dev/null | head -1; }
pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
worktree_of() {     # $1 = branch → path of the tree it is checked out in
    git -C "$ROOT" worktree list --porcelain \
        | awk -v b="refs/heads/$1" '/^worktree /{w=substr($0, 10)} /^branch /{if ($2==b) {print w; exit}}'
}
unmerged_count() {  # $1 = branch → number of its commits not in the protected branch, or "err"
    local r bases="" n
    for r in "refs/heads/$PROT" "refs/remotes/origin/$PROT"; do
        if has_ref "$r"; then bases="$bases $r"; fi
    done
    [ -n "$bases" ] || { echo err; return; }
    # shellcheck disable=SC2086
    n=$(git -C "$ROOT" rev-list --count "refs/heads/$1" --not $bases 2>/dev/null || true)
    case "$n" in ''|*[!0-9]*) echo err ;; *) echo "$n" ;; esac
}
claim_live() {      # $1 = claim dir; sets CL_*; 0 = live
    local d="$1" wt n p t
    CL_NONCE="-"; CL_BRANCH=""; CL_TREE=""; CL_REASON=""
    if [ ! -f "$d/owner" ]; then
        if [ -d "$d" ] && [ "$(file_age "$d")" -lt 60 ]; then
            CL_REASON="another session is claiming it right now"; return 0
        fi
        return 1
    fi
    CL_NONCE=$(owner_get "$d" nonce); [ -n "$CL_NONCE" ] || CL_NONCE="-"
    CL_BRANCH=$(owner_get "$d" branch); CL_TREE=$(owner_get "$d" tree)
    # The claiming wt-new.sh is still running: its tree and branch do not exist
    # yet (base, deps), and without this check a parallel session would see a
    # claim with no tree and no commits — "stale" — and take it over.
    p=$(owner_get "$d" pid); t=$(owner_get "$d" time)
    case "$t" in ''|*[!0-9]*) t=0 ;; esac
    if pid_alive "$p" && [ $(( $(date +%s) - t )) -lt 3600 ]; then
        CL_REASON="the session that claimed it (pid $p) is still creating its tree"; return 0
    fi
    [ -n "$CL_BRANCH" ] || return 1
    wt=$(worktree_of "$CL_BRANCH")
    if [ -n "$wt" ]; then CL_REASON="its branch is checked out in $wt"; return 0; fi
    git -C "$ROOT" rev-parse -q --verify "refs/heads/$CL_BRANCH" >/dev/null 2>&1 || return 1
    # Nothing to compare with, or git failed → treat as live (never steal on doubt).
    n=$(unmerged_count "$CL_BRANCH")
    case "$n" in
        0) return 1 ;;
        err) CL_REASON="its branch could not be compared with $PROT"; return 0 ;;
        *) CL_REASON="its branch has $n commit(s) not in $PROT"; return 0 ;;
    esac
}
claim_busy() {
    echo "🔴 issue #$ISSUE is already taken: $CL_REASON"
    [ -n "$CL_BRANCH" ] && echo "     branch: $CL_BRANCH"
    [ -n "$CL_TREE" ] && echo "     tree:   $CL_TREE"
    [ -n "$CL_BRANCH" ] && echo "   Continue it:  scripts/wt-new.sh --resume $CL_BRANCH"
    exit 1
}
take_mutex() {      # $1 = mutex dir; 0 = taken
    local m="$1" p dead
    if mkdir "$m" 2>/dev/null; then echo "$$" > "$m/pid"; MUTEX_DIR="$m"; return 0; fi
    # A mutex left by a crashed process would block the issue forever: older than
    # 60 s with a dead pid → removed. Moved away first and re-checked, so two
    # sessions cannot both remove it and both proceed.
    p=$(cat "$m/pid" 2>/dev/null || true)
    if [ "$(file_age "$m")" -ge 60 ] && ! pid_alive "$p"; then
        dead="$m.dead.$$"
        mv "$m" "$dead" 2>/dev/null || return 1
        if [ "$(cat "$dead/pid" 2>/dev/null || true)" != "$p" ]; then
            mv "$dead" "$m" 2>/dev/null || true; return 1
        fi
        rm -rf "$dead"
        echo "  ⚠️  removed an abandoned takeover lock of issue #$ISSUE (pid ${p:-?} is gone)"
        if mkdir "$m" 2>/dev/null; then echo "$$" > "$m/pid"; MUTEX_DIR="$m"; return 0; fi
    fi
    return 1
}
claim_put_owner() { mv "$OWN_TMP" "$1/owner"; OWN_TMP=""; CLAIM_DIR="$1"; CLAIM_NONCE="$NONCE"; }

if [ "$ISSUE_SET" = "1" ]; then
    CLAIMS="$COMMON/monitorex-locks/claims"
    mkdir -p "$CLAIMS"
    C="$CLAIMS/issue-$ISSUE"
    NONCE=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)
    [ -n "$NONCE" ] || NONCE="$$-$RANDOM-$(date +%s)"
    OWN_TMP="$CLAIMS/.owner.$$"
    printf 'issue=%s\nbranch=%s\ntree=%s\ntime=%s\npid=%s\nnonce=%s\ntitle=%s\n' \
        "$ISSUE" "$BRANCH" "$DIR" "$(date +%s)" "$$" "$NONCE" "$ISSUE_TITLE" > "$OWN_TMP"

    if mkdir "$C" 2>/dev/null; then
        claim_put_owner "$C"
    else
        claim_live "$C" && claim_busy
        SEEN="$CL_NONCE"; OLD_BRANCH="$CL_BRANCH"; OLD_TREE="$CL_TREE"
        take_mutex "$C.takeover" || {
            echo "🔴 a takeover of issue #$ISSUE is already in progress in another session — try again in a minute"
            exit 1; }
        if [ ! -e "$C" ]; then
            # Released meanwhile (wt-done.sh) — an ordinary claim.
            mkdir "$C" 2>/dev/null || { echo "🔴 issue #$ISSUE was just claimed by another session"; exit 1; }
            claim_put_owner "$C"
        else
            claim_live "$C" && claim_busy
            if [ "$CL_NONCE" != "$SEEN" ]; then
                echo "🔴 the claim of issue #$ISSUE changed while it was being checked — run again"; exit 1
            fi
            STALE="$CLAIMS/.stale-issue-$ISSUE-$$"
            mv "$C" "$STALE" 2>/dev/null || { echo "🔴 issue #$ISSUE: lost a race for the stale claim — run again"; exit 1; }
            MOVED=$(owner_get "$STALE" nonce); [ -n "$MOVED" ] || MOVED="-"
            if [ "$MOVED" != "$SEEN" ]; then
                mv "$STALE" "$C" 2>/dev/null || echo "  ⚠️  could not put back the claim moved to $STALE"
                echo "🔴 issue #$ISSUE: the claim changed during takeover — run again"; exit 1
            fi
            if ! mkdir "$C" 2>/dev/null; then
                rm -rf "$STALE"
                echo "🔴 issue #$ISSUE was just claimed by another session"; exit 1
            fi
            claim_put_owner "$C"
            rm -rf "$STALE"
            echo "  ⚠️  stale claim of issue #$ISSUE taken over (was: branch ${OLD_BRANCH:-?}, tree ${OLD_TREE:-?})"
        fi
        rm -rf "$MUTEX_DIR"; MUTEX_DIR=""
    fi
    echo "  issue #$ISSUE claimed → $BRANCH"
fi

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
short() { git -C "$ROOT" rev-parse --short "$1"; }
if [ -z "$RESUME" ] && [ -z "$BASE" ]; then
    LOCAL="refs/heads/$GG_PROTECTED"; REMOTE="refs/remotes/origin/$GG_PROTECTED"
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
    NEWB="-b"
    # A stale claim leaves its branch behind. Without own commits (all of it is in
    # the protected branch) and not checked out anywhere, it holds nothing: recreate
    # it from the fresh base instead of failing on "branch already exists".
    if [ "$ISSUE_SET" = "1" ] && git -C "$ROOT" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null 2>&1 \
       && [ -z "$(worktree_of "$BRANCH")" ] && [ "$(unmerged_count "$BRANCH")" = "0" ]; then
        NEWB="-B"
        echo "  branch $BRANCH exists without own commits — recreated from the base"
    fi
    if ! git -C "$ROOT" worktree add --no-track "$NEWB" "$BRANCH" "$DIR" "$BASE"; then
        if [ "$ISSUE_SET" = "1" ] && git -C "$ROOT" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null 2>&1; then
            echo "🔴 branch $BRANCH already exists — continue it: scripts/wt-new.sh --resume $BRANCH"
        fi
        exit 1
    fi
fi
CLAIM_KEEP=1

# ── --merge-main: bring an old branch up to date ─────────────────────────────
if [ -n "$RESUME" ] && [ "$MERGE_MAIN" = "1" ] && has_ref "refs/remotes/origin/$PROT"; then
    echo "  merging origin/$PROT into ${BRANCH}…"
    if ! git -C "$DIR" merge --no-edit "refs/remotes/origin/$PROT"; then
        echo "🔴 merge of origin/$PROT into $BRANCH stopped on conflicts."
        echo "   Resolve them in $DIR and commit; then run: bash \"$DIR/scripts/install-git-guards.sh\""
        exit 1
    fi
    LEFT=$(outdated_guards "refs/heads/$BRANCH")
    [ -z "$LEFT" ] || echo "  ⚠️  after the merge these still differ from origin/$PROT (changed in the branch): $LEFT"
fi

# 🔴 Copied BEFORE the package install below: if a long install is interrupted
# (Ctrl-C, a tool timeout), the tree must not be left without its env files.
# .env.local is not tracked by git — a fresh tree lacks it, the API returns
# 500, and the cause looks like broken code.
for f in .env.local .env.development.local; do
    [ -f "$MAIN/$f" ] && [ ! -f "$DIR/$f" ] && cp "$MAIN/$f" "$DIR/$f" && echo "  $f copied"
done

# ── Dependencies ─────────────────────────────────────────────────────────────
# node_modules: a CLONE via APFS clonefile (`cp -Rc`), NOT a symlink. Turbopack
# (Next 16) rejects a symlink pointing outside the project directory and fails
# immediately. A clone takes seconds and uses almost no space (copy-on-write).
# 🔴 A clone is only correct when the main folder's packages match the tree's
# lockfile. Since the tree is based on fresh origin/main and the main folder may
# lag behind, two traps appear: the lockfile changed on GitHub (the tree got no
# node_modules at all and the dev server started for nothing), or the main folder
# was pulled without reinstalling (an up-to-date lockfile over outdated packages).
# In both cases packages are installed in the tree instead of cloned.
DEPS_OK=1
if [ -d "$MAIN/node_modules" ] && [ -f "$DIR/package.json" ]; then
    LOCK=""; MARKER=""; STALE_MAIN=0
    for pair in package-lock.json:.package-lock.json pnpm-lock.yaml:.modules.yaml \
                yarn.lock:.yarn-integrity bun.lock: bun.lockb:; do
        f="${pair%%:*}"
        [ -f "$DIR/$f" ] || [ -f "$MAIN/$f" ] || continue
        LOCK="$f"
        if [ -n "${pair#*:}" ]; then MARKER="node_modules/${pair#*:}"; fi
        break
    done
    WHY=""
    if [ -n "$LOCK" ] && ! cmp -s "$MAIN/$LOCK" "$DIR/$LOCK"; then
        WHY="$LOCK differs between the main folder and the tree"
    elif [ -n "$MARKER" ] && [ -f "$MAIN/$MARKER" ] && [ "$MAIN/$LOCK" -nt "$MAIN/$MARKER" ]; then
        WHY="the main folder's node_modules is older than its $LOCK"
        STALE_MAIN=1
    fi
    if [ -z "$WHY" ]; then
        if cp -Rc "$MAIN/node_modules" "$DIR/node_modules" 2>/dev/null; then
            echo "  node_modules → APFS clone (copy-on-write)"
        else
            cp -R "$MAIN/node_modules" "$DIR/node_modules"
            echo "  node_modules → regular copy (clonefile unavailable)"
        fi
    else
        INSTALL="$GG_DEPS_INSTALL_CMD"
        if [ -z "$INSTALL" ]; then
            case "$LOCK" in
                package-lock.json)  INSTALL="npm ci" ;;
                pnpm-lock.yaml)     INSTALL="pnpm install --frozen-lockfile" ;;
                yarn.lock)          INSTALL="yarn install --frozen-lockfile" ;;
                bun.lock|bun.lockb) INSTALL="bun install --frozen-lockfile" ;;
                *)                  INSTALL="npm install" ;;
            esac
        fi
        DEPSLOG="$(git -C "$DIR" rev-parse --absolute-git-dir)/wt-deps.log"
        echo "  ⚠️  $WHY — installing packages in the tree: $INSTALL"
        echo "     ⏳ this can take a few minutes (log: $DEPSLOG)"
        if ( cd "$DIR" && sh -c "$INSTALL" ) < /dev/null > "$DEPSLOG" 2>&1; then
            echo "  node_modules → fresh install"
        else
            DEPS_OK=0
            echo "  🔴 package install failed (log: $DEPSLOG)"
            echo "     install manually: cd \"$DIR\" && $INSTALL"
        fi
        if [ "$STALE_MAIN" = "1" ]; then
            echo "  ℹ️  the main folder's packages are outdated too: (cd \"$MAIN\" && $INSTALL)"
        fi
    fi
fi

bash "$ROOT/scripts/install-git-guards.sh" >/dev/null

# ── Own dev server on a free port ────────────────────────────────────────────
PORT=""
if [ -n "$GG_DEV_CMD" ] && [ "$DEPS_OK" = "0" ]; then
    echo "  ⚠️  dev server not started: packages are not installed (see above)"
elif [ -n "$GG_DEV_CMD" ]; then
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
[ "$ISSUE_SET" = "1" ] && echo "  issue:      #$ISSUE claimed (released by wt-done.sh)"
[ -n "$PORT" ] && echo "  dev:        http://localhost:$PORT  (pid $(cat "$DIR/.wt-dev.pid" 2>/dev/null))"
[ -n "$PORT" ] && echo "  dev log:    $DEVLOG"
echo
echo "Commit:  scripts/git-safe-commit.sh --message-file <file> -- <paths>"
echo "Push:    git push -u origin $BRANCH   (from here)"
echo "Remove:  scripts/wt-done.sh $NAME"
