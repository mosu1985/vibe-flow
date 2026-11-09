#!/usr/bin/env bash
# rollout-projects.sh — roll the current git-guards kit out to every project on
# this machine that already has it. Two phases with a human/agent review between:
#
#   rollout-projects.sh list               projects found and what would change
#   rollout-projects.sh prepare            worktree wt/<branch> per project, files, commit
#   (run vibe-flow:release-gate on every prepared worktree — pre-push requires it)
#   rollout-projects.sh ship               push, PR, merge, pull the main folder,
#                                          reinstall hooks, remove the worktree
#
# Environment:
#   GG_ROLLOUT_ROOTS   where to look for projects (default: ~/dev ~/orca/projects)
#   GG_ROLLOUT_BRANCH  branch/worktree name (default: gg-update)
#   GG_ROLLOUT_ONLY    space-separated project names to limit the run
#   GG_ROLLOUT_SESSION_URL  Claude session URL for commit and PR attribution (default: none)
#   GG_ROLLOUT_KNOWN   list of known file versions (default: tools/git-guards-known-blobs.txt)
#
# 🔴 A project file is replaced only if it equals SOME historical version of the
# canonical file (git-guards-known-blobs.txt + git history of this repo). A file that
# matches none was edited by the project — left alone and reported, never overwritten.
# 🔴 ship merges into the protected branch = a production deploy for projects with
# auto-deploy. Run it only after the user said "yes" to that.
set -u
GG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../plugins/vibe-flow/git-guards" && pwd)"
# Versions from before git-guards moved into this repository: their history stayed behind.
KNOWN="${GG_ROLLOUT_KNOWN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-guards-known-blobs.txt}"
[ -f "$KNOWN" ] || { printf 'known versions list not found: %s\n' "$KNOWN" >&2; exit 1; }
ROOTS="${GG_ROLLOUT_ROOTS:-$HOME/dev $HOME/orca/projects}"
NAME="${GG_ROLLOUT_BRANCH:-gg-update}"
BRANCH="wt/$NAME"
CMD="${1:-list}"
SESSION_URL="${GG_ROLLOUT_SESSION_URL:-}"

say()  { printf '%s\n' "$*"; }
warn() { printf '  ⚠️  %s\n' "$*"; }

projects() {
    for r in $ROOTS; do
        find "$r" -maxdepth 3 -path '*/scripts/wt-new.sh' -not -path '*/node_modules/*' \
            -not -path '*-wt/*' 2>/dev/null
    done | while read -r f; do
        p=$(dirname "$(dirname "$f")")
        [ -f "$p/.gitguards.conf" ] || continue
        [ "$p" = "$GG" ] && continue
        if [ -n "${GG_ROLLOUT_ONLY:-}" ]; then
            case " $GG_ROLLOUT_ONLY " in *" $(basename "$p") "*) ;; *) continue ;; esac
        fi
        printf '%s\n' "$p"
    done | sort -u
}

# canonical source → path inside a project
pairs() {
    for src in "$GG"/files/scripts/* "$GG"/files/scripts/git-guards/* \
               "$GG"/files/githooks/* "$GG"/files/claude/hooks/*; do
        [ -f "$src" ] || continue
        rel="${src#"$GG"/}"
        case "$rel" in
            files/scripts/git-guards/*) dst="scripts/git-guards/${rel##*/}" ;;
            files/scripts/*)            dst="scripts/${rel##*/}" ;;
            files/githooks/*)           dst="githooks/${rel##*/}" ;;
            files/claude/hooks/*)       dst=".claude/hooks/${rel##*/}" ;;
        esac
        printf '%s\t%s\n' "$rel" "$dst"
    done
}

known_blob() {   # $1 = canonical rel path, $2 = blob hash
    grep -qxF "$2  $1" "$KNOWN" && return 0
    # -m: a version born in a merge commit (conflict resolution) has no other trace;
    # without it such a file looks "edited by the project" and never gets updated.
    git -C "$GG" log --all -m --format= --raw --no-abbrev -- "$1" | awk '{print $4}' | grep -qx "$2"
}

# Sync files into tree $1. Prints changed paths to stdout, reports custom files.
sync_files() {
    local T="$1" rel dst
    pairs | while IFS="$(printf '\t')" read -r rel dst; do
        if [ -f "$T/$dst" ]; then
            cmp -s "$GG/$rel" "$T/$dst" && continue
            if ! known_blob "$rel" "$(git hash-object "$T/$dst")"; then
                warn "$dst was edited by the project — left alone" >&2
                continue
            fi
        fi
        mkdir -p "$(dirname "$T/$dst")"
        cp "$GG/$rel" "$T/$dst"
        case "$dst" in *.sh|*/pre-commit|*/pre-push|*verify_staged.py) chmod +x "$T/$dst" ;; esac
        printf '%s\n' "$dst"
    done
}

conf() { (GG_PROTECTED=main; . "$1/.gitguards.conf" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\""); }

wt_dir() {   # worktree directory of project $1, the same rule as wt-new.sh
    local P="$1" base; base="$(conf "$P" GG_WT_DIR)"
    [ -n "$base" ] || base="$(dirname "$P")/$(basename "$P")-wt"
    case "$base" in /*) ;; *) base="$(cd "$P" && mkdir -p "$base" && cd "$base" && pwd)" ;; esac
    printf '%s/%s' "$base" "$NAME"
}

has_origin() { git -C "$1" remote get-url origin >/dev/null 2>&1; }

# Dependencies for pre-push typecheck: clone when safe, otherwise install.
deps() {
    local P="$1" T="$2" d lock
    for d in . frontend web; do
        [ -f "$T/$d/package.json" ] || continue
        [ -e "$T/$d/node_modules" ] && continue
        lock=package-lock.json
        if [ -d "$P/$d/node_modules" ] && cmp -s "$P/$d/$lock" "$T/$d/$lock" \
           && ! [ "$P/$d/$lock" -nt "$P/$d/node_modules/.package-lock.json" ]; then
            cp -Rc "$P/$d/node_modules" "$T/$d/node_modules" 2>/dev/null \
                || cp -R "$P/$d/node_modules" "$T/$d/node_modules"
            say "  node_modules ($d) → clone"
        elif [ -f "$T/$d/$lock" ]; then
            say "  node_modules ($d) → npm ci"
            (cd "$T/$d" && npm ci --silent >/dev/null 2>&1) || warn "npm ci failed in $d"
        fi
    done
    for f in .env.local .env.development.local web/.env.local; do
        [ -f "$P/$f" ] && [ ! -f "$T/$f" ] && cp "$P/$f" "$T/$f"
    done
    # Next route types: pre-push refuses without them (GG_REQUIRE_DEV_READY)
    local globs; globs="$(conf "$P" GG_DEV_READY_GLOBS)"
    if [ -n "$globs" ] && [ "$(conf "$P" GG_REQUIRE_DEV_READY)" = "1" ]; then
        local g dir found=""; g="${globs%% *}"; dir="${g%%/.next*}"; [ "$dir" = "$g" ] && dir=.
        for g in $globs; do
            [ -n "$(find "$T/$g" -name '*.ts' 2>/dev/null | head -1)" ] && found=1
        done
        if [ -z "$found" ]; then
            (cd "$T/$dir" && npx --no-install next typegen >/dev/null 2>&1) \
                && say "  next typegen ($dir)" \
                || warn "no Next route types in $dir — run the project's dev once before ship"
        fi
    fi
}

message() {
    cat <<EOF
[chore]: git-guards $(git -C "$GG" log -1 --format=%h -- files) — kit update

$(git -C "$GG" log -3 --format='- %s' -- files)

Updated to the canonical git-guards kit (tools/rollout-projects.sh in vibe-flow).
Files the project edited itself were left alone.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
${SESSION_URL:+Claude-Session: $SESSION_URL}
EOF
}

case "$CMD" in
list)
    projects | while read -r P; do
        T=$(mktemp -d)
        pairs | while IFS="$(printf '\t')" read -r rel dst; do
            [ -f "$P/$dst" ] || { say "    + $dst"; continue; }
            cmp -s "$GG/$rel" "$P/$dst" && continue
            known_blob "$rel" "$(git hash-object "$P/$dst")" && say "    ~ $dst" || say "    ! $dst (edited by the project)"
        done > "$T/out"
        n=$(grep -c . "$T/out"); say "$(basename "$P"): $n change(s)$(has_origin "$P" || printf ' · no origin')"
        cat "$T/out"; rm -rf "$T"
    done
    ;;
prepare)
    MSG=$(mktemp); message > "$MSG"
    projects | while read -r P; do
        say "== $(basename "$P")"
        if ! has_origin "$P"; then
            # No remote: nothing to push and no PR — commit straight to the main folder
            changed=$(sync_files "$P")
            [ -n "$changed" ] || { say "  already up to date"; continue; }
            (cd "$P" && bash scripts/git-safe-commit.sh --message-file "$MSG" -- $changed 2>&1 | tail -1)
            (cd "$P" && bash scripts/install-git-guards.sh >/dev/null) && say "  hooks reinstalled (no origin — done)"
            continue
        fi
        W=$(wt_dir "$P")
        [ -e "$W" ] && { warn "$W already exists — skipped"; continue; }
        git -C "$P" fetch -q origin "$(conf "$P" GG_PROTECTED)" || { warn "fetch failed — skipped"; continue; }
        git -C "$P" worktree add -q --no-track -b "$BRANCH" "$W" "origin/$(conf "$P" GG_PROTECTED)" || continue
        changed=$(sync_files "$W")
        if [ -z "$changed" ]; then
            say "  already up to date"; git -C "$P" worktree remove "$W"; git -C "$P" branch -D "$BRANCH" >/dev/null
            continue
        fi
        deps "$P" "$W"
        (cd "$W" && bash scripts/test-git-guards.sh >/dev/null 2>&1) && say "  test-git-guards ✅" \
            || warn "test-git-guards FAILED in $W"
        (cd "$W" && bash scripts/git-safe-commit.sh --message-file "$MSG" -- $changed 2>&1 | tail -1)
        say "  worktree: $W"
    done
    rm -f "$MSG"
    say ""
    say "Next: vibe-flow:release-gate on each worktree above, then: $0 ship"
    ;;
ship)
    projects | while read -r P; do
        has_origin "$P" || continue
        W=$(wt_dir "$P"); [ -d "$W" ] || continue
        PROT=$(conf "$P" GG_PROTECTED)
        say "== $(basename "$P")"
        if ! (cd "$W" && git push -q -u origin "$BRANCH" 2>&1 | tail -5); then :; fi
        git -C "$W" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1 \
            || { warn "push refused — see above; fix and re-run ship"; continue; }
        title=$(git -C "$W" log -1 --format=%s)
        body="$(git -C "$W" log -1 --format=%b | sed '/^Co-Authored-By:/,$d')
🤖 Generated with [Claude Code](https://claude.com/claude-code)

$SESSION_URL"
        url=$(cd "$W" && gh pr create --base "$PROT" --head "$BRANCH" --title "$title" --body "$body" 2>&1 | tail -1)
        n="${url##*/}"
        (cd "$W" && gh pr merge "$n" --merge >/dev/null 2>&1)
        state=$(cd "$W" && gh pr view "$n" --json state -q .state 2>/dev/null)
        say "  PR $url → $state"
        [ "$state" = "MERGED" ] || continue
        # The main folder runs these scripts — without a pull it keeps the old kit
        git -C "$P" fetch -q origin "$PROT"
        if [ "$(git -C "$P" branch --show-current)" = "$PROT" ] \
           && git -C "$P" merge -q --ff-only "origin/$PROT" 2>/dev/null; then
            (cd "$P" && bash scripts/install-git-guards.sh >/dev/null) && say "  main folder pulled, hooks reinstalled"
        else
            warn "main folder not fast-forwarded (other branch, divergence or conflicting local edits) — pull it by hand"
        fi
        slug=$(cd "$P" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
        git -C "$P" worktree remove --force "$W" && git -C "$P" branch -D "$BRANCH" >/dev/null 2>&1
        [ -n "$slug" ] && gh api -X DELETE "repos/$slug/git/refs/heads/$BRANCH" >/dev/null 2>&1
        say "  worktree and branch removed"
    done
    ;;
*) sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
