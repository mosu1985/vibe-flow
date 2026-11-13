#!/usr/bin/env bash
# wt-status.sh — what in the repository is NOT finished.
#
# WHY. The kit's guards were built to stop a session from grabbing OTHER sessions'
# changes, and they handle that. But there was the opposite gap: a session did not
# see ITS OWN earlier work. `CLAUDE.md` says to start with `wt-new.sh <task-name>`,
# and there was no "check whether this work has already started" step at all — so
# a second session on the same topic, naming the task slightly differently, would
# branch off main and write everything again. Verified 10.09.2026: a file made in
# the previous session is not visible in the new tree, and there is no warning.
#
#   scripts/wt-status.sh            — report for a human
#   scripts/wt-status.sh --hook     — for SessionStart: silent when everything is finished
#   scripts/wt-status.sh --names    — branch names only (for wt-new.sh)
#
# Also shows issues claimed with `wt-new.sh --issue N`, and warns (🔴) when the
# installed git hooks differ from origin/<protected>:githooks/. 🔴 NO NETWORK here:
# this runs at the start of EVERY session — local git and files only.
set -eu

MODE="${1:-report}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Project configuration: read as TEXT from the protected branch (conf.sh), never
# sourced. SessionStart must stay quiet: a missing library or a broken config
# leaves the defaults.
GG_BRANCH_PREFIX="wt/"
GG_PROTECTED="main"
GG_CONF_LIB="$ROOT/scripts/git-guards/conf.sh"
if [ -f "$GG_CONF_LIB" ] && . "$GG_CONF_LIB" 2>/dev/null && gg_conf_init "$ROOT" 2>/dev/null; then
    GG_PROTECTED=$GG_PROT
    GG_BRANCH_PREFIX=$(gg_get GG_BRANCH_PREFIX "wt/" 2>/dev/null)
fi

# Comparison base: both the local main branch and its remote snapshot. Work that
# reached main by any route counts as finished — including when it landed with a
# rewritten SHA and the branch itself looks behind.
BASES=""
git rev-parse --verify -q "refs/heads/$GG_PROTECTED" >/dev/null 2>&1 && BASES="$BASES refs/heads/$GG_PROTECTED"
git rev-parse --verify -q "refs/remotes/origin/$GG_PROTECTED" >/dev/null 2>&1 && BASES="$BASES refs/remotes/origin/$GG_PROTECTED"
if [ -z "$BASES" ] && [ "$MODE" = "--names" ]; then exit 0; fi

COMMON=$(git rev-parse --git-common-dir 2>/dev/null || true)
case "$COMMON" in /*|'') ;; *) COMMON="$(cd "$COMMON" 2>/dev/null && pwd -P || true)" ;; esac

# Map "branch → its worktree"
MAP=$(git worktree list --porcelain 2>/dev/null | awk '
    /^worktree /{w=substr($0, 10)} /^branch /{sub("refs/heads/","",$2); print $2"\t"w}')
tree_of() { printf '%s\n' "$MAP" | awk -F'\t' -v b="$1" '$1==b{print $2; exit}'; }

# ── Installed hooks vs origin (the kit-wide protected-branch rule) ───────────
# origin/HEAD → origin/main → origin/master. A hook missing from origin is not
# compared (the project is only adopting the kit). An old tree's installer — run
# by `npm install` → prepare — silently puts OLD hooks into the shared directory;
# this is where a session learns about it.
HOOK_WARN=""
if [ -n "$COMMON" ] && git remote get-url origin >/dev/null 2>&1; then
    PROT=""
    r=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)
    case "$r" in refs/remotes/origin/?*) PROT="${r#refs/remotes/origin/}" ;; esac
    if [ -z "$PROT" ]; then
        for b in main master; do
            if git rev-parse --verify -q "refs/remotes/origin/$b" >/dev/null 2>&1; then PROT="$b"; break; fi
        done
    fi
    if [ -n "$PROT" ]; then
        DEST="$COMMON/monitorex-hooks"; DRIFT=""; ANY=0
        for h in pre-commit pre-push plan-gate.sh prepare-commit-msg; do
            want=$(git rev-parse -q --verify "refs/remotes/origin/$PROT:githooks/$h" 2>/dev/null) || continue
            ANY=1
            have=$(git hash-object "$DEST/$h" 2>/dev/null || echo missing)
            [ "$want" = "$have" ] || DRIFT="$DRIFT $h"
        done
        if [ "$ANY" = "1" ]; then
            HP=$(git config core.hooksPath 2>/dev/null || true)
            HPR=$(cd "$HP" 2>/dev/null && pwd -P || echo "$HP")
            DR=$(cd "$DEST" 2>/dev/null && pwd -P || echo "$DEST")
            if [ -n "$DRIFT" ]; then
                HOOK_WARN="🔴 Installed git hooks differ from origin/$PROT:${DRIFT}
   Barriers may be outdated or off. Reinstall: bash scripts/install-git-guards.sh
"
            elif [ "$HPR" != "$DR" ]; then
                HOOK_WARN="🔴 core.hooksPath is not $DEST — the installed git hooks are not active.
   Reinstall: bash scripts/install-git-guards.sh
"
            fi
        fi
    fi
fi

# ── Claimed issues (wt-new.sh --issue N) ─────────────────────────────────────
CLAIM_LINES=""
if [ -n "$COMMON" ]; then
    for c in "$COMMON"/monitorex-locks/claims/issue-*; do
        [ -d "$c" ] || continue
        n="${c##*/issue-}"
        case "$n" in ''|*[!0-9]*) continue ;; esac      # skip *.takeover and the like
        br=$(sed -n 's/^branch=//p' "$c/owner" 2>/dev/null | head -1)
        title=$(sed -n 's/^title=//p' "$c/owner" 2>/dev/null | head -1 | tr -d '\000-\037\177')
        if [ -z "$br" ]; then
            st="being claimed (no owner yet)"
        elif w=$(tree_of "$br") && [ -n "$w" ]; then
            st="tree: $(basename "$w")"
        elif git rev-parse --verify -q "refs/heads/$br" >/dev/null 2>&1 \
             && [ -n "$BASES" ] && [ "$(git rev-list --count "refs/heads/$br" --not $BASES 2>/dev/null || echo 0)" != "0" ]; then
            st="no tree → scripts/wt-new.sh --resume $br"
        else
            st="stale — the next wt-new.sh --issue $n takes it over"
        fi
        CLAIM_LINES="$CLAIM_LINES$(printf '   #%-7s %-32s %s' "$n" "${br:-?}" "$st")${title:+ · $title}
"
    done
fi

LINES=""
COUNT=0
for ref in $(git for-each-ref --format='%(refname:short)' "refs/heads/$GG_BRANCH_PREFIX*" 2>/dev/null); do
    [ -n "$BASES" ] || break        # no protected branch → nothing to compare with
    n=$(git rev-list --count "$ref" --not $BASES 2>/dev/null || echo 0)
    [ "$n" = "0" ] && continue
    COUNT=$((COUNT+1))
    # 🔴 "Did not reach main" and "exists nowhere else" are different alarms.
    # The first means "unfinished", the second "the only copy is on this disk".
    # Showing only the first would equate an abandoned branch sitting on origin
    # with work that a disk failure would destroy.
    nowhere=$(git rev-list --count "$ref" --not --remotes $BASES 2>/dev/null || echo 0)
    when=$(git log -1 --format='%ad' --date=format:'%d.%m' "$ref" 2>/dev/null)
    w=$(tree_of "$ref")
    if [ -n "$w" ]; then
        d=$(git -C "$w" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        extra="tree: $(basename "$w")"
        [ "$d" != "0" ] && extra="$extra · uncommitted: $d"
    else
        extra="no tree → scripts/wt-new.sh --resume $ref"
    fi
    risk=""
    [ "$nowhere" != "0" ] && risk=" 🔴 $nowhere exist NOWHERE else"
    LINES="$LINES$(printf '   %-32s %2s not in %s · %s · %s%s' "$ref" "$n" "$GG_PROTECTED" "$when" "$extra" "$risk")
"
done

case "$MODE" in
  --names)
    for ref in $(git for-each-ref --format='%(refname:short)' "refs/heads/$GG_BRANCH_PREFIX*" 2>/dev/null); do
        n=$(git rev-list --count "$ref" --not $BASES 2>/dev/null || echo 0)
        [ "$n" != "0" ] && printf '%s\n' "$ref"
    done
    ;;
  --hook)
    # 🔴 Silent when everything is finished: the hook runs in EVERY session, and
    # constant noise would make it invisible exactly when it is needed.
    printf '%s' "$HOOK_WARN"
    if [ -n "$CLAIM_LINES" ]; then
        printf '🔷 Claimed issues:\n%s' "$CLAIM_LINES"
    fi
    [ "$COUNT" = "0" ] && exit 0
    printf '🔶 The repository has unfinished work (%s branches):\n' "$COUNT"
    printf '%s' "$LINES"
    printf '   Before creating a new tree, check whether the task has already been started here.\n'
    ;;
  *)
    printf '%s' "$HOOK_WARN"
    if [ "$COUNT" = "0" ]; then
        echo "No unfinished branches — all work is in $GG_PROTECTED."
    else
        printf '🔶 Unfinished work (%s branches):\n' "$COUNT"
        printf '%s' "$LINES"
    fi
    if [ -n "$CLAIM_LINES" ]; then
        printf '🔷 Claimed issues:\n%s' "$CLAIM_LINES"
    fi
    ;;
esac
