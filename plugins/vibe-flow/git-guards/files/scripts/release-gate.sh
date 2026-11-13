#!/usr/bin/env bash
# release-gate.sh — the final gate before code ships: the verdict of an Opus reviewer.
#
# WHY. Reviewers look at the PLAN, but bugs live in the CODE and the data: a predicate
# on the wrong field of an external API passed nine rounds of plan review and reached
# production. And code written by Sonnet/Haiku subagents was looked at by nobody after
# implementation. The gate closes that hole: pre-push will not ship the branch until the
# `release-gate` agent (Opus) has read its whole diff and recorded a verdict.
#
# The verdict is tied to the commit's TREE (HEAD^{tree}), not to the SHA: rebuilding
# a commit with the same content (safe-commit, a changed message) keeps the verdict,
# while any content change loses it, and review is needed again.
#
#   scripts/release-gate.sh scope              — what to review: base, commits, files
#   scripts/release-gate.sh status             — whether HEAD has a verdict
#   scripts/release-gate.sh pass --head <sha> --report <f>
#                                              — record ✅ (release-gate agent only)
#   scripts/release-gate.sh override --yes     — one-off bypass by a human (via `!`)
set -eu

YES=0; REPORT=""; REVIEWED=""; ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
      --yes) YES=1 ;;
      --report) shift; REPORT="${1:-}" ;;
      --head) shift; REVIEWED="${1:-}" ;;
      *) ARGS+=("$1") ;;
    esac
    shift
done
set -- ${ARGS[@]+"${ARGS[@]}"}

COMMON=$(git rev-parse --git-common-dir)
case "$COMMON" in /*) ;; *) COMMON="$(cd "$COMMON" && pwd -P)" ;; esac
DIR="$COMMON/monitorex-locks/release-gate"
mkdir -p "$DIR"

TOP=$(git rev-parse --show-toplevel)
# 🔴 The policy is read as TEXT (scripts/git-guards/conf.sh), never sourced from
# the tree: a branch's own GG_PROTECTED used to move the review base, and so
# shrink the diff the reviewer sees. The protected branch follows the kit-wide
# rule (origin/HEAD → origin/main → origin/master).
GG_CONF_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-guards/conf.sh"
if [ ! -f "$GG_CONF_LIB" ]; then
    echo "🔴 scripts/git-guards/conf.sh missing — the kit in this tree is incomplete: merge the protected branch into it" >&2
    echo "   (scripts/wt-new.sh --resume <branch> --merge-main from the main folder) or reinstall the kit (/vibe-flow:init)" >&2
    exit 1
fi
. "$GG_CONF_LIB"
gg_conf_init "$TOP" || { echo "🔴 cannot read the repository at $TOP" >&2; exit 1; }
GG_PROTECTED=$GG_PROT

# origin if it exists: pre-push gets the remote explicitly, and with a second remote
# that sorts earlier alphabetically, scope/status would compute a different base.
if git remote | grep -qx origin; then REMOTE=origin; else REMOTE=$(git remote | head -1); fi
BASE_REF="refs/remotes/$REMOTE/$GG_PROTECTED"

# The "no review needed" masks are repository policy, as in pre-push: taken from
# the protected branch's config on the remote, or, if absent, from the main working
# tree. The branch's own config does not affect the mask, otherwise SKIP="*" in it
# would disable the gate.
if gpol=$(git show "$BASE_REF:.gitguards.conf" 2>/dev/null); then
    GG_POLICY=$gpol
elif [ -f "$GG_MAIN_CONF" ]; then
    GG_POLICY=$(cat "$GG_MAIN_CONF")
else
    GG_POLICY=""
fi
GG_RELEASE_GATE_SKIP=$(gg_get GG_RELEASE_GATE_SKIP "*.md")
HEAD_SHA=$(git rev-parse HEAD)
TREE=$(git rev-parse 'HEAD^{tree}')

base() {
    git rev-parse --verify -q "$BASE_REF" >/dev/null \
        || { echo "🔴 no $BASE_REF — run git fetch" >&2; exit 1; }
    git merge-base "$BASE_REF" HEAD
}

# Files that need review: everything except the GG_RELEASE_GATE_SKIP masks (docs).
# The logic matches pre-push — a mismatch would mean "no review needed" here
# and a rejection there.
review_files() {
    b=$(base)
    # --no-renames: otherwise renaming lib/x.ts → docs/x.md shows only the new
    # path and would pass as "docs only", although it deletes code.
    # quotePath=false: otherwise a non-ASCII name arrives quoted and misses the mask.
    git -c core.quotePath=false diff --no-renames --name-only "$b" HEAD | while IFS= read -r f; do
        [ -n "$f" ] || continue
        skip=0
        set -f
        for pat in $GG_RELEASE_GATE_SKIP; do
            case "$f" in ($pat) skip=1 ;; esac
        done
        set +f
        [ "$skip" = 1 ] || printf '%s\n' "$f"
    done
}

# A verdict is real only if it has verdict= and a head= whose tree matches HEAD.
# Same check as in pre-push: an empty file written bypassing the script is not a verdict.
verdict_valid() {
    f="$DIR/$TREE"
    [ -f "$f" ] && grep -qE '^verdict=(pass|override)$' "$f" || return 1
    h=$(sed -n 's/^head=//p' "$f" | head -1)
    [ -n "$h" ] && [ "$(git rev-parse -q --verify "$h^{tree}" 2>/dev/null)" = "$TREE" ]
}

clean_or_die() {
    # The reviewer reads what is committed. An uncommitted change in the tree would
    # mean they did not see what is going to ship.
    if ! git diff --quiet HEAD -- 2>/dev/null; then
        echo "🔴 the working tree has uncommitted changes — the verdict would not apply to HEAD:"
        git status --short | grep -v '^??' | sed 's/^/     /'
        exit 1
    fi
}

case "${1:-status}" in
  scope)
    b=$(base)
    echo "base:    $(git rev-parse --short "$b")  ($BASE_REF)"
    echo "HEAD:    $(git rev-parse --short HEAD)  tree $(git rev-parse --short "$TREE")"
    echo ""
    echo "commits:"
    git log --format='  %h  %s' "$b..HEAD"
    echo ""
    files=$(review_files)
    if [ -z "$files" ]; then
        echo "no files need review (only ${GG_RELEASE_GATE_SKIP}) — gate not needed"
    else
        echo "files for review:"
        git diff --stat "$b" HEAD -- $files | sed 's/^/  /'
        echo ""
        echo "full diff: git diff $(git rev-parse --short "$b") HEAD"
    fi ;;

  status)
    # base() outside command substitution: inside $(…) bash 3.2 swallows its failure,
    # and without origin/main the status would falsely say "gate not needed".
    base >/dev/null
    if verdict_valid; then
        echo "✅ verdict exists for HEAD $(git rev-parse --short HEAD):"
        sed 's/^/     /' "$DIR/$TREE"
    elif [ -z "$(review_files)" ]; then
        echo "⚪️ gate not needed: the diff has only ${GG_RELEASE_GATE_SKIP}"
    else
        echo "🔴 no verdict for HEAD $(git rev-parse --short HEAD) — the release-gate agent is needed"
        exit 1
    fi ;;

  pass)
    [ -n "$REPORT" ] && [ -s "$REPORT" ] \
        || { echo "🔴 a non-empty --report <file> with the review report is required"; exit 2; }
    # The verdict goes to the HEAD the reviewer READ, not the current one. While
    # review runs (xhigh — minutes), a new commit may land in the tree, and without
    # this check the verdict would cover content nobody has seen.
    [ -n "$REVIEWED" ] || { echo "🔴 --head <sha> where the review started is required"; exit 2; }
    # Full SHA only: `--head HEAD` would compare HEAD with itself and let
    # through a commit that landed during review.
    printf '%s' "$REVIEWED" | grep -qE '^[0-9a-f]{40}([0-9a-f]{24})?$' \
        || { echo "🔴 --head must be a full commit SHA (git rev-parse HEAD at the start of review), not \"$REVIEWED\""; exit 2; }
    reviewed_full=$(git rev-parse --verify -q "$REVIEWED^{commit}") \
        || { echo "🔴 --head $REVIEWED is not a commit"; exit 2; }
    if [ "$reviewed_full" != "$HEAD_SHA" ]; then
        echo "🔴 HEAD moved during review: reviewed $(git rev-parse --short "$reviewed_full"), now $(git rev-parse --short HEAD)."
        echo "   Verdict not recorded — a new review round on the current HEAD is needed."
        exit 1
    fi
    clean_or_die
    {
        printf 'verdict=pass\nhead=%s\nbase=%s\nts=%s\nsession=%s\n' \
            "$HEAD_SHA" "$(base)" "$(date -u +%FT%TZ)" "${CLAUDE_CODE_SESSION_ID:-}"
        echo "---"
        cat "$REPORT"
    } > "$DIR/$TREE.tmp.$$"
    mv "$DIR/$TREE.tmp.$$" "$DIR/$TREE"
    # Verdicts older than 30 days are useless: those trees are long since in main.
    find "$DIR" -type f -mtime +30 -delete 2>/dev/null || true
    echo "✅ verdict recorded for HEAD $(git rev-parse --short HEAD) (tree $(git rev-parse --short "$TREE"))" ;;

  override)
    clean_or_die
    echo "The bypass will allow pushing HEAD $(git rev-parse --short HEAD) WITHOUT release-gate review:"
    git log --format='  %h  %s' "$(base)..HEAD"
    printf '\nPush unreviewed code? [yes/no] '
    if [ "$YES" = 1 ]; then echo "yes (--yes)"
    else
        read -r a || { echo; echo "🔴 no way to answer: input is not from a keyboard. Add --yes to the same command."; exit 1; }
        { [ "$a" = "yes" ] || [ "$a" = "да" ]; } || { echo "cancelled"; exit 1; }  # "да" kept for existing Russian-speaking users
    fi
    printf 'verdict=override\nhead=%s\nts=%s\n' "$HEAD_SHA" "$(date -u +%FT%TZ)" > "$DIR/$TREE"
    echo "bypass recorded for this content; any change will revoke it" ;;

  *) echo "usage: release-gate.sh [scope|status|pass --head <sha> --report <f>|override]"; exit 2 ;;
esac
