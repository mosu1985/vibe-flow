#!/usr/bin/env bash
# sync-main-folder.sh — after a deploy merged a PR on GitHub, move the project's MAIN folder (the
# first entry of `git worktree list`, where the user and long-running processes such as a local
# daemon or a dev server live) forward to the merge commit. Called by the vibe-flow:push-to-production
# agent as a separate step after deploy-merge.sh; also the only way to retry it later — a plain
# `git pull` would silently overwrite ignored files (.env, data/) that the merge starts tracking.
#
#   cd <any tree of the project> && bash sync-main-folder.sh <base branch> <merge commit full sha>
#
# What it does, in order (every check failing means "skipped": nothing is changed):
#   1. the main folder is not bare and is on <base>;
#   2. fetches origin's <base> into its own ref refs/vibe-flow/sync/<base> (not refs/remotes/*, not the
#      shared FETCH_HEAD), non-interactively, under a watchdog (SYNC_MAIN_TIMEOUT seconds, 120);
#      the repository's own SSH settings (core.sshCommand) are used as they are;
#   3. the fetched <base> must contain the merge commit (a PR still in a merge queue is not synced);
#   4. HEAD must be an ancestor of it (local commits that are not on origin are never touched);
#   5. merge --ff-only --no-overwrite-ignore --no-autostash; afterwards the folder must still be on
#      <base> and exactly at the fetched commit.
# It NEVER stashes, resets, checks out, autostashes or overwrites ignored files: a tracked edit or an
# ignored file in the way makes git refuse, and the reason is reported. The project's own git hooks
# (for example a tracked post-merge hook of husky) run, as they would on the user's own `git pull`.
#
# Last line: "main folder: updated to <short> | already up to date | skipped: <reason>".
# Exit codes: 0 updated or already up to date · 1 skipped, nothing changed · 2 usage.
set -u
ME="$(basename "$0")"
TIMEOUT="${SYNC_MAIN_TIMEOUT:-120}"
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=120 ;; esac
[ "$TIMEOUT" -ge 1 ] || TIMEOUT=1

usage() { printf 'usage: %s <base branch> <merge commit full sha>\n' "$ME" >&2; exit 2; }
say()   { printf 'main folder: %s\n' "$1"; }
skip()  { say "skipped: $1"; exit 1; }
first_line() { tr -d '\r' | sed -n '1p' | cut -c1-200; }

[ $# -eq 2 ] || usage
base="$1"; sha="$2"
case "$sha" in ''|*[!0-9a-f]*) usage ;; esac
[ "${#sha}" -eq 40 ] || usage
case "$base" in ''|-*|*:*) usage ;; esac
git check-ref-format --branch "$base" >/dev/null 2>&1 || usage

# ── Watchdog (the same technique as git-guards wt-new.sh) ────────────────────
# macOS has no `timeout`, and git has no connect timeout for HTTP. On Windows (Git Bash) a native
# child (git.exe) does not get MSYS signals: its Windows process tree is killed with taskkill.
is_msys() { case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*) command -v cygpath >/dev/null 2>&1 ;; *) return 1 ;; esac; }
kill_tree() {   # $1 = pid, $2 = TERM | KILL; rc 1 when the process is already gone
    local w=""
    if is_msys; then
        w=$(cat "/proc/$1/winpid" 2>/dev/null || true)
        case "$w" in
            ''|*[!0-9]*) ;;
            *) taskkill //T //F //PID "$w" >/dev/null 2>&1 && return 0 ;;
        esac
    fi
    pkill -"$2" -P "$1" 2>/dev/null || true     # its children too (remote helpers, ssh)
    kill -"$2" "$1" 2>/dev/null
}
# rc 124 when the watcher cut the command off — from the watcher's mark, not from the killed
# process's status (a process killed with taskkill reports 0 to Git Bash's `wait`).
# The command's output goes to the file $1 — a cut-off child must not hold our stdout open.
run_with_timeout() {
    local secs="$1" outf="$2"; shift 2
    local fired; fired=$(mktemp "${TMPDIR:-/tmp}/sync-main-timeout.XXXXXX") || fired=""
    "$@" </dev/null >"$outf" 2>&1 &
    local pid=$!
    (
        trap 'kill "$s" 2>/dev/null; exit 0' TERM
        sleep "$secs" & s=$!
        wait "$s"
        [ -z "$fired" ] || echo timeout > "$fired"     # marked BEFORE the kill
        if ! kill_tree "$pid" TERM; then
            [ -z "$fired" ] || : > "$fired"            # it had already finished on its own
            exit 0
        fi
        sleep 2 & s=$!
        wait "$s"
        kill_tree "$pid" KILL || true
    ) </dev/null >/dev/null 2>&1 &
    local watcher=$!
    local rc=0
    wait "$pid" || rc=$?
    kill -TERM "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    if [ -n "$fired" ]; then
        [ -s "$fired" ] && rc=124
        rm -f "$fired"
    fi
    return "$rc"
}

# ── 1. The main folder ───────────────────────────────────────────────────────
block=$(git worktree list --porcelain 2>/dev/null | sed '/^$/q') || block=""
main=$(printf '%s\n' "$block" | sed -n '1s/^worktree //p')
[ -n "$main" ] || skip "not a git repository"
printf '%s\n' "$block" | grep -qx bare && skip "the main repository is bare"
G() { git -C "$main" -c gc.auto=0 -c maintenance.auto=false "$@"; }
on_base() { [ "$(G symbolic-ref -q HEAD 2>/dev/null)" = "refs/heads/$base" ]; }
on_base || skip "the main folder is not on $base"

# ── 2. Fetch origin's <base> into our own ref ────────────────────────────────
T=$(mktemp "${TMPDIR:-/tmp}/sync-main-folder.XXXXXX") || skip "no temp file"
trap 'rm -f "$T"' EXIT
ref="refs/vibe-flow/sync/$base"
export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
frc=0
run_with_timeout "$TIMEOUT" "$T" git -C "$main" -c gc.auto=0 -c maintenance.auto=false \
    fetch -q --no-tags origin "+refs/heads/$base:$ref" || frc=$?
[ "$frc" = 124 ] && skip "fetch timed out after ${TIMEOUT}s"
[ "$frc" = 0 ] || skip "fetch failed: $(first_line < "$T")"
target=$(G rev-parse --verify -q "$ref^{commit}") || skip "the fetched $base is not readable"

# ── 3–4. The merge commit is there, and only a fast-forward is possible ─────
G merge-base --is-ancestor "$sha" "$target" 2>/dev/null \
    || skip "$base on origin does not contain $(printf '%s' "$sha" | cut -c1-12) yet"
head=$(G rev-parse --verify -q HEAD) || skip "HEAD of the main folder is not readable"
if [ "$head" = "$target" ]; then say "already up to date"; exit 0; fi
G merge-base --is-ancestor "$head" "$target" 2>/dev/null \
    || skip "local $base has commits that are not on origin"

# ── 5. Fast-forward, then check where we are ─────────────────────────────────
on_base || skip "the main folder left $base during the fetch"
G merge --ff-only --no-overwrite-ignore --no-autostash -q "$target" > "$T" 2>&1 \
    || skip "$(first_line < "$T")"
on_base && [ "$(G rev-parse --verify -q HEAD)" = "$target" ] \
    || skip "the main folder is not at the fetched $base after the merge"
say "updated to $(G rev-parse --short HEAD)"
