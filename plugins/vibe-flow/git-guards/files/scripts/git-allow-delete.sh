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

COMMON=$(git rev-parse --git-common-dir)
case "$COMMON" in /*) ;; *) COMMON="$(cd "$COMMON" && pwd -P)" ;; esac
ALLOW="$COMMON/monitorex-locks/delete-allow"
TTL=900
mkdir -p "$(dirname "$ALLOW")"

age_of() { echo $(( $(date +%s) - $(stat -f %m "$1" 2>/dev/null || echo 0) )); }

case "${1:-list}" in
  list)
    if [ -f "$ALLOW" ]; then
        AGE=$(age_of "$ALLOW")
        if [ "$AGE" -lt "$TTL" ]; then
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
    echo "These will disappear from the protected branch:"
    for p in "$@"; do
        # Show whether the file exists on the remote: a mistyped path protects
        # nothing and creates a false sense that the deletion was confirmed.
        if git cat-file -e "origin/main:$p" 2>/dev/null; then
            printf '  %s  (%s lines on origin/main)\n' "$p" \
                "$(git show "origin/main:$p" | wc -l | tr -d ' ')"
        else
            printf '  %s  ⚠️ no such path on origin/main — check for a typo\n' "$p"
        fi
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
