#!/usr/bin/env bash
# git-confirm.sh <target> — one-off owner mark to bypass a guard.
#
# WHY A SEPARATE FILE AND NOT AN ENVIRONMENT VARIABLE. An agent will set a
# variable like MONITOREX_NO_LOCK=1 without a second thought — a one-line bypass.
# The mark lives for 15 minutes, is tied to a specific case and is CONSUMED after
# the first use, so setting it is a deliberate human action.
#
#   scripts/git-confirm.sh commit    — allow one regular git commit
#   scripts/git-confirm.sh status    — what is set right now
#   scripts/git-confirm.sh clear     — remove
#   scripts/git-confirm.sh commit --yes — answer "yes" via a flag (when run via `!`)
set -eu

# --yes is for the Claude Code input line (`!`): stdin there is not interactive.
# It gives the agent no bypass: the PreToolUse hook rejects setting a mark from
# the model's Bash tool. Details in git-allow-delete.sh.
YES=0; ARGS=()
for a in "$@"; do case "$a" in --yes) YES=1 ;; *) ARGS+=("$a") ;; esac; done
set -- ${ARGS[@]+"${ARGS[@]}"}
COMMON=$(git rev-parse --git-common-dir); case "$COMMON" in /*) ;; *) COMMON="$(cd "$COMMON" && pwd -P)";; esac
F="$COMMON/monitorex-locks/CONFIRM"
TTL=900
mkdir -p "$(dirname "$F")"

case "${1:-status}" in
  status)
    if [ -f "$F" ]; then
      age=$(( $(date +%s) - $(stat -f %m "$F") ))
      [ "$age" -lt "$TTL" ] && echo "mark: $(cat "$F"), age ${age}s (lives ${TTL}s)" \
                            || echo "mark expired (${age}s) — treated as absent"
    else echo "no mark"; fi ;;
  clear) rm -f "$F"; echo "removed" ;;
  *)
    TARGET="$1"
    echo "The mark will allow ONE guard bypass for '$TARGET' within the next $((TTL/60)) minutes."
    echo "It is consumed after the first use."
    printf 'Confirm? [yes/no] '
    if [ "$YES" = 1 ]; then echo "yes (--yes)"
    else
        read -r a || { echo; echo "🔴 no way to answer: input is not from a keyboard. Add --yes to the same command."; exit 1; }
        { [ "$a" = "yes" ] || [ "$a" = "да" ]; } || { echo "cancelled"; exit 1; }  # "да" kept for existing Russian-speaking users
    fi
    printf 'target=%s\nts=%s\n' "$TARGET" "$(date -u +%FT%TZ)" > "$F"
    echo "mark set: $TARGET" ;;
esac
