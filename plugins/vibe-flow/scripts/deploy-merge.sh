#!/usr/bin/env bash
# deploy-merge.sh — the merge half of one "yes" to "Deploy <sha>? (push <branch> + merge into
# <production branch>)". Run from the project tree AFTER the approved commit has been pushed to
# <branch>. Called by the vibe-flow:push-to-production agent; the checks live here, in code,
# because a list of steps in an agent's text is easy to skip.
#
#   cd <worktree> && bash deploy-merge.sh <branch> <approved full sha> [<production branch>]
#
# <production branch> defaults to origin/HEAD → main → master (the same base release-gate uses).
#   1. The PR: exactly one open PR of <branch> from this repository; it must target the production
#      branch and its head must be the approved commit. No open PR → one is created
#      (--base <production> --head <branch>).
#   2. CI on that commit: required checks first; when none are required, every check, none red.
#      When nothing is reported yet but the project has a pull_request workflow, wait up to
#      DEPLOY_MERGE_CI_START seconds for the checks to appear — then refuse ("CI did not start").
#   3. The PR is read again (the head may have moved while waiting) and merged with
#      --match-head-commit <approved sha>. A refusal "base branch policy prohibits the merge"
#      (a main-admin-only ruleset) goes to admin-only-merge.sh <N> <approved sha>.
#
# Exit codes: 0 merged · 3 checks still running at the deadline, nothing merged: run again with
# the same arguments · 1 refused or failed (one line saying why) · 2 usage.
# Waits (seconds) can only be shortened through the environment, which fails closed:
# DEPLOY_MERGE_DEADLINE (540, under the agent's 600 s Bash timeout), DEPLOY_MERGE_CI_START (60),
# DEPLOY_MERGE_HEAD_WAIT (30: GitHub updates a PR's head a few seconds after the push),
# DEPLOY_MERGE_POLL (15).
# Not awaited: CI that runs only on `push` (no pull_request trigger) and reports nothing yet —
# required checks still hold such a merge on GitHub's side.
set -u
ME="$(basename "$0")"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEADLINE="${DEPLOY_MERGE_DEADLINE:-540}"
CI_START="${DEPLOY_MERGE_CI_START:-60}"
HEAD_WAIT="${DEPLOY_MERGE_HEAD_WAIT:-30}"
POLL="${DEPLOY_MERGE_POLL:-15}"
for v in "$DEADLINE" "$CI_START" "$HEAD_WAIT" "$POLL"; do case "$v" in ''|*[!0-9]*) DEADLINE=0 ;; esac; done

usage() { printf 'usage: %s <branch> <approved full sha> [<production branch>]\n' "$ME" >&2; exit 2; }
refuse() { printf '%s: refused — %s\n' "$ME" "$1"; exit 1; }
oneline() { tr '\n' ' ' | sed 's/  */ /g; s/ $//' | cut -c1-300; }

[ $# -ge 2 ] && [ $# -le 3 ] || usage
branch="$1"; sha="$2"; base="${3:-}"
[ -n "$branch" ] || usage
case "$sha" in ''|*[!0-9a-f]*) usage ;; esac
[ "${#sha}" -eq 40 ] || usage

T="$(mktemp -d "${TMPDIR:-/tmp}/deploy-merge.XXXXXX")" || refuse "no temp directory"
trap 'rm -rf "$T"' EXIT

if [ -z "$base" ]; then
    base="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null)"; base="${base#origin/}"
    if [ -z "$base" ] || [ "$base" = HEAD ] || [ "$base" = origin/HEAD ]; then
        base=""
        for b in main master; do
            git ls-remote --exit-code --heads origin "$b" > /dev/null 2>&1 && { base="$b"; break; }
        done
    fi
    [ -n "$base" ] || refuse "production branch not found (origin/HEAD, main, master)"
fi
[ "$branch" != "$base" ] || refuse "the branch is the production branch $base — a deploy goes through a PR"

# 1. The one open PR of the branch: number, url; refuses on anything but the approved one.
pr() {
    gh pr list --head "$branch" --state open --json number,baseRefName,headRefName,headRefOid,url,isCrossRepository \
        > "$T/list" 2> "$T/err" || refuse "PRs of $branch not readable: $(oneline < "$T/err")"
    python3 -I - "$T/list" > "$T/list.out" 2> /dev/null <<'PY' || refuse "PRs of $branch not readable: unexpected response"
import json, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, list):
    raise SystemExit(2)
print(len(d))
for p in d[:1]:
    for k in ("number", "baseRefName", "headRefName", "headRefOid", "url"):
        print(p.get(k, ""))
    print("cross" if p.get("isCrossRepository") else "same")
PY
    { read -r count; read -r n; read -r pbase; read -r phead; read -r poid; read -r url; read -r cross; } < "$T/list.out"
    case "$count" in
        0) n=""; return 0 ;;
        1) ;;
        *) refuse "$count open PRs of $branch — a deploy needs exactly one" ;;
    esac
    case "$n" in ''|*[!0-9]*) refuse "PR of $branch: no number in the response" ;; esac
    [ "$cross" = same ] || refuse "PR #$n of $branch comes from a fork"
    [ "$phead" = "$branch" ] || refuse "PR #$n head branch is $phead, not $branch"
    [ "$pbase" = "$base" ] || refuse "open PR #$n of $branch targets $pbase, not $base — close it or retarget it first"
    [ "$poid" = "$sha" ] || head_moved=1
}
# The PR, waiting up to HEAD_WAIT seconds for its head to become the approved commit (right after a
# push GitHub may still show the previous head); anything else is refused at once by pr().
pr_at_sha() {
    local start=$SECONDS
    while :; do
        head_moved=0; pr
        [ -z "$n" ] || [ "$head_moved" = 0 ] && return 0
        [ $((SECONDS - start)) -lt "$HEAD_WAIT" ] \
            || refuse "PR #$n head is $poid, approved $sha — a new \"yes\" is needed for the new commit"
        sleep "$POLL"
    done
}

pr_at_sha
if [ -z "$n" ]; then
    gh pr create --fill --base "$base" --head "$branch" > "$T/create" 2> "$T/err" \
        || refuse "PR not created: $(oneline < "$T/err")"
    pr_at_sha
    [ -n "$n" ] || refuse "PR of $branch created but not found: $(oneline < "$T/create")"
fi

# 2. CI on the approved commit. gh pr checks: 0 green, 8 pending, 1 red or nothing reported
# (the message is on stderr, the table of check names on stdout).
not_green() {
    local names
    names=$(awk -F'\t' '$2=="fail"||$2=="cancel"||$2=="pending"{print $1}' "$T/c.out" | sort -u | paste -s -d, - | sed 's/,/, /g')
    refuse "checks not green on PR #$n: ${names:-$(oneline < "$T/c.err")}"
}
wait_checks() { # $@ extra flags → 0 green · 4 none required · 5 none reported; red → refuse; deadline → exit 3
    while :; do
        gh pr checks "$n" "$@" > "$T/c.out" 2> "$T/c.err"; crc=$?
        case "$crc" in
            0) return 0 ;;
            8) if [ "$SECONDS" -ge "$DEADLINE" ]; then
                   printf '%s: checks still running on PR #%s (%s) after %ss — nothing merged; run again with the same arguments\n' "$ME" "$n" "$sha" "$SECONDS"
                   exit 3
               fi
               sleep "$POLL" ;;
            *) grep -qi 'no required checks reported' "$T/c.err" && return 4
               grep -qi 'no checks reported' "$T/c.err" && return 5
               not_green ;;
        esac
    done
}
has_pr_ci() {
    local root; root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    grep -qs 'pull_request' "$root"/.github/workflows/*.yml "$root"/.github/workflows/*.yaml
}

wait_checks --required; r=$?
if [ "$r" != 0 ]; then
    start=$SECONDS
    while :; do
        wait_checks; r=$?
        [ "$r" = 0 ] && break
        has_pr_ci || break   # no CI in the project and nothing reported: nothing to wait for
        [ $((SECONDS - start)) -lt "$CI_START" ] \
            || refuse "CI did not start on PR #$n within ${CI_START}s, though .github/workflows has a pull_request trigger"
        sleep "$POLL"
    done
fi

# 3. Read the PR again (the head may have moved while waiting), then merge pinned to the commit.
pr_at_sha
[ -n "$n" ] || refuse "the PR of $branch is no longer open"
if gh pr merge "$n" --merge --match-head-commit "$sha" > "$T/m.out" 2> "$T/m.err"; then
    how=""
elif grep -q 'base branch policy prohibits the merge' "$T/m.err"; then
    out=$(bash "$HERE/admin-only-merge.sh" "$n" "$sha" 2>&1); arc=$?
    case "$arc" in
        0) how=" ($(printf '%s' "$out" | tail -1))" ;;
        3) refuse "merge of PR #$n refused: $(oneline < "$T/m.err")" ;;
        *) refuse "$(printf '%s' "$out" | tail -1)" ;;
    esac
else
    refuse "merge of PR #$n refused: $(oneline < "$T/m.err")"
fi
mc=$(gh pr view "$n" --json mergeCommit --jq .mergeCommit.oid 2>/dev/null)
printf '%s: merged — PR #%s %s → %s, commit %s, merge commit %s%s\n' "$ME" "$n" "$url" "$base" "$sha" "${mc:-?}" "$how"
