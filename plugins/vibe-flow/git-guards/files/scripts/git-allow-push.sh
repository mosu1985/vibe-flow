#!/usr/bin/env bash
# git-allow-push.sh — allow pushing commits made by someone else.
#
# WHY. pre-push refuses if the pushed set contains a commit this session did not
# create. The reason is the incident of 02.09.2026: a push carried a neighboring
# session's commit to the remote, and nobody had asked for permission. The same
# had happened earlier with `2a2280f1`, which was waiting for deploy approval.
#
# Someone else's commit can be legitimate too: made in a worktree and pushed by the
# main session. So it is not a ban but an explicit list: the human looks at what is
# about to ship and confirms.
#
#   scripts/git-allow-push.sh add <sha…>   — allow (with confirmation)
#   scripts/git-allow-push.sh add --yes <sha…> — same, answer "yes" via a flag
#   scripts/git-allow-push.sh list         — what is allowed right now
#   scripts/git-allow-push.sh clear        — clear the list
set -eu

# --yes answers "yes" when run via `!` in the Claude Code input line (stdin there
# is not interactive). It gives the agent no bypass: the PreToolUse hook rejects
# add mode from the model's Bash tool. Details in git-allow-delete.sh.
YES=0; ARGS=()
for a in "$@"; do case "$a" in --yes) YES=1 ;; *) ARGS+=("$a") ;; esac; done
set -- ${ARGS[@]+"${ARGS[@]}"}

COMMON=$(git rev-parse --git-common-dir)
case "$COMMON" in /*) ;; *) COMMON="$(cd "$COMMON" && pwd -P)" ;; esac
ALLOW="$COMMON/monitorex-locks/push-allow"
mkdir -p "$(dirname "$ALLOW")"
touch "$ALLOW"

# Drop what has already shipped: the permission is single-use by design,
# otherwise the list piles up and one day allows something nobody looked at.
prune() {
    tmp="$ALLOW.tmp.$$"
    : > "$tmp"
    while read -r sha; do
        [ -n "$sha" ] || continue
        if ! git merge-base --is-ancestor "$sha" \
             "$(git for-each-ref --format='%(objectname)' refs/remotes | tr '\n' ' ' | awk '{print $1}')" 2>/dev/null; then
            echo "$sha" >> "$tmp"
        fi
    done < "$ALLOW"
    mv "$tmp" "$ALLOW"
}

case "${1:-list}" in
  list)
    prune 2>/dev/null || true
    if [ -s "$ALLOW" ]; then
        while read -r sha; do
            [ -n "$sha" ] || continue
            printf '  %s  %s\n' "$(git rev-parse --short "$sha" 2>/dev/null || echo "$sha")" \
                                "$(git log -1 --format=%s "$sha" 2>/dev/null || echo '(object not found)')"
        done < "$ALLOW"
    else
        echo "  (list is empty)"
    fi ;;

  clear) : > "$ALLOW"; echo "list cleared" ;;

  add)
    shift
    [ $# -gt 0 ] || { echo "at least one SHA is required"; exit 2; }
    echo "These will be allowed to push:"
    for s in "$@"; do
        full=$(git rev-parse --verify "$s^{commit}" 2>/dev/null) || { echo "🔴 not a commit: $s"; exit 1; }
        printf '  %s  %s\n     author: %s   Session-Id: %s\n' \
            "$(git rev-parse --short "$full")" "$(git log -1 --format=%s "$full")" \
            "$(git log -1 --format='%an' "$full")" \
            "$(git log -1 --format='%(trailers:key=Session-Id,valueonly)' "$full" | tr -d '\n')"
    done
    printf '\nThis is work by another session. Push it under your name? [yes/no] '
    if [ "$YES" = 1 ]; then echo "yes (--yes)"
    else
        read -r a || { echo; echo "🔴 no way to answer: input is not from a keyboard. Add --yes to the same command."; exit 1; }
        { [ "$a" = "yes" ] || [ "$a" = "да" ]; } || { echo "cancelled"; exit 1; }  # "да" kept for existing Russian-speaking users
    fi
    for s in "$@"; do git rev-parse --verify "$s^{commit}" >> "$ALLOW"; done
    echo "allowed; the list is single-use — shipped commits are pruned automatically" ;;

  *) echo "usage: git-allow-push.sh [add <sha…>|list|clear]"; exit 2 ;;
esac
