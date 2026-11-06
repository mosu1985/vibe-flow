#!/usr/bin/env bash
# git-safe-commit.sh — the only allowed way to commit in the shared working tree.
#
# WHY. Several Claude sessions, a Codex agent and a human all work in the
# repository at once — in the same working directory. The git index is SHARED:
# a careful `git add <paths>` does not protect against the race (verified 2026-08-06 —
# 7 staged files ended up in someone else's commit within seconds).
#
# HOW. The commit is built in an ISOLATED index (GIT_INDEX_FILE); the shared one is
# not read for the build at all. The branch moves via `update-ref <ref> <new>
# <old>` — an atomic compare-and-swap: if a neighbor moved the branch, our update
# is rejected (rc=128), and the commit object stays reachable.
#
# LOCK ORDER (invariant, do not change): monitorex-locks/commit first,
# then index.lock. That way two safe-commits never compete for index.lock —
# the first lock already serializes them.
#
# Format: git-safe-commit.sh --message-file <file> -- <path…>
#
# Plan and analysis of six review rounds: docs/plans/2026-09-01-parallel-session-guardrails.md

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

die() { printf '\n🔴 %s\n\n' "$*" >&2; exit 1; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
info() { printf '   %s\n' "$*" >&2; }

# ─── 0. Parse the CLI BEFORE anything else ──────────────────────────────────
# Otherwise `--message-file` ends up in the pathspec and MSGFILE stays unset.
MSGFILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --message-file) [ $# -ge 2 ] || die "--message-file has no value"; MSGFILE="$2"; shift 2 ;;
        --) shift; break ;;
        -*) die "unknown flag: $1 (format: --message-file <file> -- <paths>)" ;;
        *) die "path before --: $1 (format: --message-file <file> -- <paths>)" ;;
    esac
done
[ -n "$MSGFILE" ] || die "--message-file <file> is required"
[ -f "$MSGFILE" ] || die "message file not found: $MSGFILE"
[ $# -gt 0 ] || die "at least one path after -- is required"
# from here on "$@" holds ONLY the pathspec

# ─── 0. Project configuration ───────────────────────────────────────────────
# The test runner depends on the stack, so it comes from .gitguards.conf. Empty
# means tests are not run, and that is said out loud: a silent skip is
# indistinguishable from a green run.
GG_TEST_CMD=""
GG_PLAN_GATE=""
GG_TOP=$(git rev-parse --show-toplevel 2>/dev/null || echo .)
if [ -f "$GG_TOP/.gitguards.conf" ]; then . "$GG_TOP/.gitguards.conf"; fi

# ─── 0b. Project gate — checked BEFORE tests and locks ──────────────────────
# A script from .gitguards.conf decides whether this message and these paths may
# be committed (for example: a feature only with an approved plan). It receives
# the message file and the paths; a non-zero exit code means rejection. Empty — no gate.
if [ -n "$GG_PLAN_GATE" ]; then
    [ -f "$GG_TOP/$GG_PLAN_GATE" ] || die "GG_PLAN_GATE points to a nonexistent file: $GG_PLAN_GATE"
    bash "$GG_TOP/$GG_PLAN_GATE" "$MSGFILE" "$@" || exit 1
fi

# ─── 1. Tests — BEFORE any locks ────────────────────────────────────────────
# Holding a lock for minutes is not an option: while tests run, neighbors wait.
if [ "${MONITOREX_SKIP_TESTS:-0}" = "1" ]; then
    warn "tests skipped (MONITOREX_SKIP_TESTS=1)"
elif [ -z "$GG_TEST_CMD" ]; then
    warn "test runner not configured (GG_TEST_CMD in .gitguards.conf) — tests were NOT run"
else
    info "tests for the changed paths…"
    # Paths are passed positionally, not substituted into the string: otherwise a
    # file name with a space breaks the command, and a name with ; runs something else.
    if ! sh -c "$GG_TEST_CMD \"\$@\"" gg-test "$@" >/dev/null 2>&1; then
        die "tests failed. Run manually: $GG_TEST_CMD $*
   Skip deliberately: MONITOREX_SKIP_TESTS=1"
    fi
fi

# ─── 2. Identity ────────────────────────────────────────────────────────────
# An empty ACTOR would make the owner check fail-open (an empty substring
# matches any owner), so it is a rejection.
ACTOR="${CLAUDE_CODE_SESSION_ID:-${MONITOREX_ACTOR:-}}"
[ -n "$ACTOR" ] || die "no identity: set MONITOREX_ACTOR=<who you are>"

COMMON=$(git rev-parse --git-common-dir)
case "$COMMON" in /*) ;; *) COMMON="$(cd "$COMMON" && pwd -P)" ;; esac
LOCKDIR="$COMMON/monitorex-locks"
LOCK="$LOCKDIR/commit"
JOURNAL="$LOCKDIR/journal"
IDXPATH=$(git rev-parse --git-path index)          # per-worktree, NOT $COMMON/index
case "$IDXPATH" in /*) ;; *) IDXPATH="$(pwd -P)/$IDXPATH" ;; esac
IDXLOCK="$IDXPATH.lock"
TOKEN=$(uuidgen)
mkdir -p "$LOCKDIR"

IDX=""; T=""; OWN_IDXLOCK=0; OWN_COMMIT_LOCK=0; PHASE=""; NEW=""

sync_index_to() {   # $1 = commit-ish whose tree goes into the shared index
    local tmp
    tmp=$(mktemp -t monitorex-idxcopy) || return 1
    if GIT_INDEX_FILE="$tmp" git read-tree "$1" 2>/dev/null && mv "$tmp" "$IDXPATH"; then
        return 0
    fi
    rm -f "$tmp"; return 1
}

# ─── A SINGLE exit handler ──────────────────────────────────────────────────
# A second `trap ... EXIT` in POSIX shell REPLACES the first, so everything is
# here at once. A forgotten index.lock paralyzes the repository — always remove it.
cleanup() {
    local rc=$?
    [ -n "$IDX" ] && rm -f "$IDX"
    [ -n "$T" ] && rm -f "$T"

    # post-cas phase: the branch is already at NEW, but the shared index is still on
    # the old tree. Releasing the lock like this = leaving a diverged state in which
    # `git checkout` carries files away and `git stash` silently takes the difference.
    if [ "$PHASE" = "post-cas" ]; then
        if sync_index_to "$NEW"; then
            rm -f "$JOURNAL"
        else
            warn "index NOT in sync. Lock and journal LEFT in place for repair:"
            warn "    scripts/git-lock.sh release   (will see the post-cas phase and offer repair)"
            exit "$rc"          # index.lock is deliberately NOT removed
        fi
    fi

    [ "$OWN_IDXLOCK" = 1 ] && rm -f "$IDXLOCK"
    if [ "$OWN_COMMIT_LOCK" = 1 ] &&
       [ "$(sed -n 's/^token=//p' "$LOCK/owner" 2>/dev/null)" = "$TOKEN" ]; then
        rm -rf "$LOCK"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ─── 3. Serialization lock ──────────────────────────────────────────────────
if ! mkdir "$LOCK" 2>/dev/null; then
    die "a commit is already in progress: $(cat "$LOCK/owner" 2>/dev/null | tr '\n' ' ')
   View/release: scripts/git-lock.sh status"
fi
OWN_COMMIT_LOCK=1
printf 'actor=%s\ntoken=%s\npid=%s\nts=%s\n' \
    "$ACTOR" "$TOKEN" "$$" "$(date -u +%FT%TZ)" > "$LOCK/owner"

# ─── 4. index.lock — BEFORE building the commit, with the owner inside ──────
# Verified: holding index.lock does not interfere with our operations on the isolated
# index, commit-tree and update-ref, but a neighbor's `git add` fails loudly.
attempts=0
until ( set -C; printf 'actor=%s\ntoken=%s\npid=%s\nts=%s\n' \
        "$ACTOR" "$TOKEN" "$$" "$(date -u +%FT%TZ)" > "$IDXLOCK" ) 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -ge 30 ] && die "index.lock held for 30s: $(cat "$IDXLOCK" 2>/dev/null | tr '\n' ' ')
   If the holder is dead: scripts/git-lock.sh status"
    sleep 1
done
OWN_IDXLOCK=1

BR=$(git symbolic-ref --quiet HEAD) || die "detached HEAD — cannot commit"
HEAD_START=$(git rev-parse HEAD)

# ─── 5. PREcondition: the shared index is clean relative to HEAD_START ──────
# A precondition, not a postcondition: the rejection must happen BEFORE we move
# the branch, otherwise HEAD and the index diverge.
if ! git diff-index --quiet --cached "$HEAD_START"; then
    die "the shared index has staged changes — cannot commit:
$(git diff --cached --name-only | sed 's/^/     /')
   This is an anomaly: committing from the shared index is forbidden (see the pre-commit hook).
   Clear: git reset   (files on disk are not affected)"
fi

# ─── 6. Build the commit in OUR OWN index ───────────────────────────────────
# 🔴 A file that ALREADY exists in the commit's tree is added with --force: .gitignore
# decides what gets into the repository for the first time; it does not forbid editing
# tracked files. Without this, a change to a tracked file inside an ignored directory
# could not be committed at all (that is how .claude/agents/ is laid out in one project —
# on 16.09.2026 an agent fix got stuck on exactly this).
# --force is targeted: only an individual file from HEAD_START; new ignored files and
# directories are still rejected. The comparison uses -z — otherwise git quotes
# non-ASCII paths and the file would not be recognized.
stage_paths() {      # IDX/HEAD_START are variables; $@ — paths
    local p
    for p in "$@"; do
        if [ ! -d "$p" ] && \
           [ "$(git ls-tree -z --name-only "$HEAD_START" -- "$p" | tr -d '\0')" = "$p" ]; then
            GIT_INDEX_FILE="$IDX" git add --force -- "$p"
        else
            GIT_INDEX_FILE="$IDX" git add -- "$p"
        fi
    done
}

IDX=$(mktemp -t monitorex-idx)
GIT_INDEX_FILE="$IDX" git read-tree "$HEAD_START"
stage_paths "$@"

# ─── 7. Verify contents: the commit has exactly what was requested ──────────
if ! GIT_INDEX_FILE="$IDX" git -c core.quotePath=false diff --cached -z --name-only "$HEAD_START" \
     | python3 -B "$SCRIPT_DIR/git-guards/verify_staged.py" --expect "$@"; then
    die "commit contents do not match the requested paths (see above)"
fi

if GIT_INDEX_FILE="$IDX" git diff-index --quiet --cached "$HEAD_START"; then
    die "nothing to commit: the given paths do not differ from HEAD"
fi

info "commit contents:"
GIT_INDEX_FILE="$IDX" git diff --cached --stat "$HEAD_START" | sed 's/^/     /' >&2

# ─── 8. Commit + transaction journal ────────────────────────────────────────
TREE=$(GIT_INDEX_FILE="$IDX" git write-tree)
NEW=$(git interpret-trailers --trailer "Session-Id: $ACTOR" < "$MSGFILE" \
      | git commit-tree "$TREE" -p "$HEAD_START")

# The commit-tree object is unreachable — pin it with a ref BEFORE the CAS, otherwise
# a neighbor's `git gc --prune=now` would erase it.
git update-ref "refs/monitorex/recovery/$TOKEN" "$NEW"

write_journal() {
    printf 'branch=%s\nold=%s\nnew=%s\ntoken=%s\nactor=%s\nphase=%s\n' \
        "$BR" "$HEAD_START" "$NEW" "$TOKEN" "$ACTOR" "$1" > "$JOURNAL"
}
write_journal pre-cas

# ─── 9. CAS ─────────────────────────────────────────────────────────────────
retry_or_die() {      # $@ — pathspec; NEW/HEAD_START/BR/TREE are variables
    local attempt=1 new_head changed
    while [ "$attempt" -le 3 ]; do
        new_head=$(git rev-parse "$BR")

        # Overlapping paths mean REJECTION, not a rebuild: otherwise we would rebuild
        # on top of someone else's commit and overwrite their change with our disk content.
        changed=$(git diff --name-only -z "$HEAD_START" "$new_head" || true)
        if printf '%s' "$changed" \
           | python3 -B "$SCRIPT_DIR/git-guards/verify_staged.py" --intersects "$@"; then
            die "a neighbor changed the same files (attempt $attempt).
   Your commit is saved: refs/monitorex/recovery/$TOKEN
   View: scripts/git-recovery.sh show $TOKEN"
        fi

        HEAD_START="$new_head"
        GIT_INDEX_FILE="$IDX" git read-tree "$HEAD_START"
        stage_paths "$@"
        TREE=$(GIT_INDEX_FILE="$IDX" git write-tree)
        NEW=$(git interpret-trailers --trailer "Session-Id: $ACTOR" < "$MSGFILE" \
              | git commit-tree "$TREE" -p "$HEAD_START")
        git update-ref "refs/monitorex/recovery/$TOKEN" "$NEW"
        write_journal pre-cas

        if git update-ref "$BR" "$NEW" "$HEAD_START" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
    done
    die "3 CAS attempts exhausted. Commit saved: refs/monitorex/recovery/$TOKEN
   Restore: git cherry-pick $NEW"
}

if ! git update-ref "$BR" "$NEW" "$HEAD_START" 2>/dev/null; then
    warn "a neighbor moved the branch — rebuilding the commit"
    retry_or_die "$@"
fi

PHASE=post-cas
write_journal post-cas

# ─── 10. Sync the shared index under the lock we already hold ───────────────
sync_index_to "$NEW" || die "index not in sync — see scripts/git-lock.sh release"

# ─── 11. Transaction complete ───────────────────────────────────────────────
git update-ref -d "refs/monitorex/recovery/$TOKEN"
rm -f "$JOURNAL"
PHASE=done

# ─── 12. Warning about new code without consumers (non-blocking) ────────────
bash "$SCRIPT_DIR/git-guards/consumer-warn.sh" "$NEW" "$@" || true

printf '\n✅ %s  %s\n\n' "$(git rev-parse --short "$NEW")" "$(git log -1 --format=%s "$NEW")" >&2
