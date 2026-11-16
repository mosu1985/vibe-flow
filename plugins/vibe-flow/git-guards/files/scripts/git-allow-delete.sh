#!/usr/bin/env bash
# git-allow-delete.sh — allow a push that deletes files from the protected branch.
#
# WHY. pre-push refuses if the push deletes even one file from main.
# The reason is sound: a branch that fell behind its base wipes out other people's
# work SILENTLY — the fast-forward goes through normally, and the loss does not
# stand out in the diff.
#
# But a deletion can be intentional (a dead directory removed, a module dropped),
# and the advice "rebase" is not enough then: the base is already fresh, yet the
# guard still refuses. Until 10.09.2026 there was no bypass at all — the only way
# out was --no-verify, which ALSO turns off type checking and the commit-authorship
# check. A bypass that drops every barrier at once is an invitation to use it for
# any reason.
#
# So this uses the same trick as git-allow-push.sh: not a flag but a list BY NAME.
# The human sees exactly what will disappear and confirms; the mark lives for
# 15 minutes and is consumed by the hook after the first use.
#
#   scripts/git-allow-delete.sh add <path…>   — allow (with confirmation)
#   scripts/git-allow-delete.sh add --yes <path…> — same, answer "yes" via a flag
#   scripts/git-allow-delete.sh list          — what is allowed right now
#   scripts/git-allow-delete.sh clear         — remove
set -eu

# --yes answers "yes" when run via `!` in the Claude Code input line: stdin there
# is not interactive, `read` got EOF, and the script silently exited without
# allowing anything. The flag opens no bypass for the agent: the PreToolUse hook
# rejects add mode from the model's Bash tool, and only a human types `!` commands.
YES=0; ARGS=()
for a in "$@"; do case "$a" in --yes) YES=1 ;; *) ARGS+=("$a") ;; esac; done
set -- ${ARGS[@]+"${ARGS[@]}"}

# Path and policy-blob helpers (gg_is_abs, gg_path, gg_blob — scripts/git-guards/paths.sh).
GG_PATHS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/git-guards/paths.sh"
[ -f "$GG_PATHS_LIB" ] || { echo "🔴 scripts/git-guards/paths.sh missing — reinstall the kit (/vibe-flow:init)"; exit 1; }
. "$GG_PATHS_LIB"
COMMON=$(git rev-parse --git-common-dir)
gg_is_abs "$COMMON" || COMMON=$(gg_path "$COMMON")
ALLOW="$COMMON/monitorex-locks/delete-allow"
TTL=900
mkdir -p "$(dirname "$ALLOW")"

age_of() {   # seconds since mtime, empty when unknown. GNU stat first, then BSD:
    # GNU `stat -f %m` prints filesystem info instead of failing.
    local m; m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true)
    case "$m" in ''|*[!0-9]*) echo "" ;; *) echo $(( $(date +%s) - m )) ;; esac
}

case "${1:-list}" in
  list)
    if [ -f "$ALLOW" ]; then
        AGE=$(age_of "$ALLOW")
        if [ -z "$AGE" ]; then
            echo "mark age unknown — treated as absent"
        elif [ "$AGE" -lt -300 ]; then
            echo "mark time is in the future (${AGE}s) — treated as absent"
        elif [ "$AGE" -lt "$TTL" ]; then
            echo "allowed for deletion (age ${AGE}s, lives ${TTL}s):"
            sed 's/^/  /' "$ALLOW"
        else
            echo "mark expired (${AGE}s) — treated as absent"
        fi
    else
        echo "no mark"
    fi ;;

  clear) rm -f "$ALLOW"; echo "removed" ;;

  add)
    shift
    [ $# -gt 0 ] || { echo "at least one path is required"; exit 2; }
    # The protected branch by the kit-wide rule (origin/HEAD → origin/main → origin/master),
    # not a hardcoded origin/main: a project on master was shown "no such path" for everything.
    PROT_REF=""
    h=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || h=""
    for b in "${h#refs/remotes/origin/}" main master; do
        [ -n "$b" ] || continue
        if git rev-parse -q --verify "refs/remotes/origin/$b^{commit}" >/dev/null 2>&1; then
            PROT_REF="refs/remotes/origin/$b"; break
        fi
    done
    PLABEL=${PROT_REF#refs/remotes/}
    echo "These will disappear from the protected branch${PLABEL:+ ($PLABEL)}:"
    for p in "$@"; do
        # Show whether the file exists on the remote: a mistyped path protects
        # nothing and creates a false sense that the deletion was confirmed.
        # gg_blob, not `git show <rev>:<path>` (MSYS rewrote that into a false "no such path").
        brc=1; [ -z "$PROT_REF" ] || { brc=0; blob=$(gg_blob "$PROT_REF" "$p") || brc=$?; }
        case "$brc" in
            0) printf '  %s  (%s lines on %s)\n' "$p" "$(printf '%s\n' "$blob" | wc -l | tr -d ' ')" "$PLABEL" ;;
            1) if [ -n "$PROT_REF" ]; then
                   printf '  %s  ⚠️ no such path on %s — check for a typo\n' "$p" "$PLABEL"
               else
                   printf '  %s  ⚠️ no origin/<protected branch> fetched — cannot check the path\n' "$p"
               fi ;;
            *) printf '  %s  ⚠️ could not read it from %s (git fetch origin?)\n' "$p" "$PLABEL" ;;
        esac
    done
    printf '\nIs this deletion intentional? [yes/no] '
    if [ "$YES" = 1 ]; then echo "yes (--yes)"
    else
        read -r a || { echo; echo "🔴 no way to answer: input is not from a keyboard. Add --yes to the same command."; exit 1; }
        { [ "$a" = "yes" ] || [ "$a" = "да" ]; } || { echo "cancelled"; exit 1; }  # "да" kept for existing Russian-speaking users
    fi
    : > "$ALLOW"
    for p in "$@"; do printf '%s\n' "$p" >> "$ALLOW"; done
    echo "allowed; the mark is single-use and lives $((TTL/60)) minutes"
    echo "🔴 EXACTLY these paths are allowed: the hook will still reject deleting any other file." ;;

  *) echo "usage: git-allow-delete.sh [add <path…>|list|clear]"; exit 2 ;;
esac
