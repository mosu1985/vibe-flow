#!/usr/bin/env bash
# rollout-projects.sh — roll vibe-flow out to every project on this machine that has it.
#
#   rollout-projects.sh plugins   update the vibe-flow plugins in every install (no repo changes)
#   rollout-projects.sh list      pin origin/main of vibe-flow, show what would change:
#                                 git-guards files + the CLAUDE.md rules block, with its diff;
#                                 compared with each project's origin (what prepare starts from)
#   GG_ROLLOUT_SHA=<sha> rollout-projects.sh prepare
#                                 worktree wt/gg-update-<sha8> per project, files, commit;
#                                 Next route types for pre-push (typegen, or GG_DEV_CMD once)
#   (run vibe-flow:release-gate on every prepared worktree — pre-push requires it)
#   GG_ROLLOUT_SHA=<sha> rollout-projects.sh ship
#                                 push, PR, merge exactly the prepared commit (waits for the PR
#                                 checks if the first merge is refused), pull the main
#                                 folder, reinstall hooks, CLAUDE.md outside git, clean up
#
# One run = one reviewed commit of vibe-flow. `list` pins origin/main and writes the review
# (rules.diff); `prepare` and `ship` take that sha and use a snapshot of it (git archive) —
# never the working tree of vibe-flow, never a newer origin/main. The rules block is markdown,
# which release-gate skips (GG_RELEASE_GATE_SKIP="*.md"), so its review is the vibe-flow PR
# plus the diff a human reads after `list`.
#
# Environment:
#   GG_ROLLOUT_SHA     the sha printed by list (required by prepare and ship)
#   GG_ROLLOUT_ROOTS   where to look for projects (default: ~/dev ~/orca/projects)
#   GG_ROLLOUT_BRANCH  branch/worktree name prefix (default: gg-update → wt/gg-update-<sha8>)
#   GG_ROLLOUT_ONLY    space-separated project names to limit the run
#   GG_ROLLOUT_SESSION_URL  Claude session URL for commit and PR attribution (default: none)
#   GG_ROLLOUT_KNOWN   list of known file versions (default: the one in the snapshot)
#   GG_ROLLOUT_STATE   run records (default: ~/.cache/vibe-flow-rollout)
#   GG_ROLLOUT_REPO    the vibe-flow repository (default: the one this script lives in)
#   GG_ROLLOUT_CLAUDE, GG_ROLLOUT_PLUGINS_JSON  plugins: CLI and registry (tests)
#
# 🔴 A project file is replaced only if it equals SOME historical version of the
# canonical file (known-blobs list + git history of vibe-flow). A file that
# matches none was edited by the project — left alone and reported, never overwritten.
# 🔴 ship merges into the protected branch = a production deploy for projects with
# auto-deploy. Run it only after the user said "yes" to that.
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GG_ROLLOUT_REPO:-$(cd "$SELF_DIR/.." && pwd)}"
ROOTS="${GG_ROLLOUT_ROOTS:-$HOME/dev $HOME/orca/projects}"
STATE="${GG_ROLLOUT_STATE:-${XDG_CACHE_HOME:-$HOME/.cache}/vibe-flow-rollout}"
CMD="${1:-list}"
SESSION_URL="${GG_ROLLOUT_SESSION_URL:-}"
FAILED=0

say()  { printf '%s\n' "$*"; }
warn() { printf '  ⚠️  %s\n' "$*"; FAILED=1; }
die()  { printf '🔴 %s\n' "$*" >&2; exit 1; }

only_ok() { # project name passes GG_ROLLOUT_ONLY
    [ -z "${GG_ROLLOUT_ONLY:-}" ] && return 0
    case " $GG_ROLLOUT_ONLY " in *" $1 "*) return 0 ;; esac
    return 1
}

projects() { # $1=all → ignore GG_ROLLOUT_ONLY (plugins filters by itself)
    local scope="${1:-}"
    for r in $ROOTS; do
        find "$r" -maxdepth 3 -path '*/scripts/wt-new.sh' -not -path '*/node_modules/*' \
            -not -path '*-wt/*' 2>/dev/null
    done | while IFS= read -r f; do
        p=$(dirname "$(dirname "$f")")
        [ -f "$p/.gitguards.conf" ] || continue
        case "$p/" in "$REPO"/*) continue ;; esac
        [ "$scope" = all ] || only_ok "$(basename "$p")" || continue
        printf '%s\n' "$p"
    done | sort -u
}

# ── The pinned source: one sha of vibe-flow, as a snapshot ──────────────────
fetch_main() { git -C "$REPO" fetch -q origin main || die "cannot fetch origin main in $REPO"; }

pin_from_args() { # prepare/ship: the sha must come from list and be merged
    SHA="${GG_ROLLOUT_SHA:-}"
    [ -n "$SHA" ] || die "GG_ROLLOUT_SHA is required — take it from the output of: $0 list"
    printf '%s' "$SHA" | grep -Eqx '[0-9a-f]{40}' || die "GG_ROLLOUT_SHA must be a full 40-char sha"
    fetch_main
    git -C "$REPO" merge-base --is-ancestor "$SHA" origin/main 2>/dev/null \
        || die "$SHA is not in origin/main of vibe-flow — only merged code is rolled out"
    [ -f "$STATE/$SHA/listed" ] || die "no review for $SHA — run list first and read its rules.diff"
    # The review covers only the projects list showed: prepare/ship may not widen it
    local seen; seen="$(sed -n 's/^only=//p' "$STATE/$SHA/listed")"
    if [ -n "$seen" ]; then
        [ -n "${GG_ROLLOUT_ONLY:-}" ] || die "list for $SHA was limited to: $seen — run list without GG_ROLLOUT_ONLY or pass the same GG_ROLLOUT_ONLY"
        local x; for x in $GG_ROLLOUT_ONLY; do
            case " $seen " in *" $x "*) ;; *) die "$x was not in the reviewed list ($seen) — run list for it first" ;; esac
        done
    fi
}

snapshot() { # SHA → SNAP, GG, KNOWN, TPL, RB, VERSION
    RUN="$STATE/$SHA"; SNAP="$RUN/snap"
    if [ ! -f "$SNAP/.complete" ]; then
        rm -rf "$SNAP"; mkdir -p "$SNAP"
        git -C "$REPO" archive "$SHA" plugins tools/git-guards-known-blobs.txt .claude-plugin \
            | tar -x -C "$SNAP" || die "cannot unpack a snapshot of $SHA"
        : > "$SNAP/.complete"
    fi
    GG="$SNAP/plugins/vibe-flow/git-guards"
    KNOWN="${GG_ROLLOUT_KNOWN:-$SNAP/tools/git-guards-known-blobs.txt}"
    [ -f "$KNOWN" ] || die "known versions list not found: $KNOWN"
    TPL="$SNAP/plugins/vibe-flow/templates/CLAUDE.flow.md"
    RB="$SNAP/plugins/vibe-flow/scripts/rules-block.py"
    [ -f "$RB" ] || die "$SHA has no rules-block.py — merge the vibe-flow release that adds it first"
    VERSION=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' \
        "$SNAP/plugins/vibe-flow/.claude-plugin/plugin.json")
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

known_blob() {   # $1 = canonical rel path (files/…), $2 = blob hash
    grep -qxF "$2  $1" "$KNOWN" && return 0
    # History of the real repository — the snapshot has none (Codex C1).
    # -m: a version born in a merge commit (conflict resolution) has no other trace;
    # without it such a file looks "edited by the project" and never gets updated.
    git -C "$REPO" log --all -m --format= --raw --no-abbrev -- "plugins/vibe-flow/git-guards/$1" \
        | awk '{print $4}' | grep -qx "$2"
}

# Sync files into tree $1. Prints changed paths to stdout, reports custom files.
# Plans folder (Claude Code `plansDirectory`): settings-merge.py adds the key when absent,
# creates the folder and lists it in .gitignore and .git/info/exclude. Prints the files to
# commit. Uncommitted edits in those files → not touched (they would ride into our commit).
plans_opt_in() {   # $1 = tree
    local t="$1"
    if [ -n "$(git -C "$t" status --porcelain -- .claude/settings.json .gitignore 2>/dev/null)" ]; then
        printf '  ⚠️  %s\n' ".claude/settings.json or .gitignore has uncommitted edits — plans folder not switched on" >&2
        return 0
    fi
    python3 "$GG/settings-merge.py" "$t" >/dev/null 2>&1 \
        || { printf '  ⚠️  %s\n' "settings-merge.py failed — plans folder not switched on" >&2; return 0; }
    git -C "$t" status --porcelain -- .claude/settings.json .gitignore 2>/dev/null | sed 's/^...//'
}

sync_files() {
    local T="$1" rel dst
    pairs | while IFS="$(printf '\t')" read -r rel dst; do
        if [ -f "$T/$dst" ]; then
            cmp -s "$GG/$rel" "$T/$dst" && continue
            if ! known_blob "$rel" "$(git hash-object "$T/$dst")"; then
                printf '  ⚠️  %s was edited by the project — left alone\n' "$dst" >&2
                continue
            fi
        fi
        mkdir -p "$(dirname "$T/$dst")"
        cp "$GG/$rel" "$T/$dst"
        case "$dst" in *.sh|*/pre-commit|*/pre-push|*/prepare-commit-msg|*verify_staged.py) chmod +x "$T/$dst" ;; esac
        printf '%s\n' "$dst"
    done
}

# The kit files and a tracked CLAUDE.md as they are on ref $2 of project $1, into dir $3.
# list compares with this view: prepare starts from origin, not from the main folder,
# which may lag behind (an earlier rollout merged, the folder not pulled) or carry edits.
view_ref() {
    local P="$1" ref="$2" V="$3" rel dst
    pairs | while IFS="$(printf '\t')" read -r rel dst; do
        git -C "$P" cat-file -e "$ref:$dst" 2>/dev/null || continue
        mkdir -p "$V/$(dirname "$dst")"; git -C "$P" show "$ref:$dst" > "$V/$dst"
    done
    case "$(git -C "$P" ls-tree "$ref" -- CLAUDE.md | cut -c1-6)" in
        100644|100755) git -C "$P" show "$ref:CLAUDE.md" > "$V/CLAUDE.md" ;;
    esac
}

rb() { python3 "$RB" "$1" "$TPL" "$VERSION" "${@:2}"; }
claude_in_git() { git -C "$1" ls-files --error-unmatch CLAUDE.md >/dev/null 2>&1; }

conf() { (GG_PROTECTED=main; . "$1/.gitguards.conf" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\""); }

wt_dir() {   # worktree directory of project $1, the same rule as wt-new.sh
    local P="$1" base; base="$(conf "$P" GG_WT_DIR)"
    [ -n "$base" ] || base="$(dirname "$P")/$(basename "$P")-wt"
    case "$base" in /*) mkdir -p "$base" ;; *) base="$(cd "$P" && mkdir -p "$base" && cd "$base" && pwd)" ;; esac
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
        local g dir; g="${globs%% *}"; dir="${g%%/.next*}"; [ "$dir" = "$g" ] && dir=.
        if ! types_found "$T" "$globs"; then
            if (cd "$T/$dir" && npx --no-install next typegen >/dev/null 2>&1); then
                say "  next typegen ($dir)"
            elif dev_types "$P" "$T" "$globs"; then
                say "  route types via dev (GG_DEV_CMD, once)"
            else
                warn "no Next route types in $dir — run the project's dev once before ship"
            fi
        fi
    fi
}

types_found() { # $1 tree, $2 globs
    local g; for g in $2; do [ -n "$(find "$1/$g" -name '*.ts' 2>/dev/null | head -1)" ] && return 0; done; return 1
}

# Next before `next typegen` (14 and older) writes route types only on the first page
# compile in dev: start the project's GG_DEV_CMD in tree $2 on a free port, request
# the root page until the types appear (about 3–10 minutes at most), then stop the whole group.
dev_types() {
    local P="$1" T="$2" globs="$3" cmd var port pid i log
    cmd="$(conf "$P" GG_DEV_CMD)"; [ -n "$cmd" ] || return 1
    var="$(conf "$P" GG_DEV_PORT_ENV)"; var="${var:-PORT}"
    case "$var" in *[!A-Za-z0-9_]*|[0-9]*) return 1 ;; esac
    port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])') || return 1
    log="$(mktemp)"
    set -m   # its own process group, so the dev server's children stop with it
    (cd "$T" && export "$var=$port" && exec bash -c "$cmd") >"$log" 2>&1 </dev/null &
    pid=$!
    set +m
    disown "$pid" 2>/dev/null   # no "Terminated" job line in the output
    # Ctrl-C reaches only our group — stop the dev server too, then leave
    trap 'kill -TERM -- "-$pid" 2>/dev/null; exit 130' INT TERM
    for i in $(seq 1 90); do
        types_found "$T" "$globs" && { sleep 2; break; }   # let Next finish writing
        kill -0 "$pid" 2>/dev/null || break
        curl -s -o /dev/null --max-time 5 "http://localhost:$port/" 2>/dev/null; sleep 2
    done
    kill -TERM -- "-$pid" 2>/dev/null
    for i in 1 2 3 4 5; do kill -0 -- "-$pid" 2>/dev/null || break; sleep 1; done
    kill -KILL -- "-$pid" 2>/dev/null
    trap - INT TERM
    if types_found "$T" "$globs"; then rm -f "$log"; return 0; fi
    say "  dev log: $log"
    return 1
}

message() {
    cat <<EOF
[chore]: vibe-flow v$VERSION — git-guards $(git -C "$REPO" log -1 --format=%h "$SHA" -- plugins/vibe-flow/git-guards/files) + rules block

$(git -C "$REPO" log -5 --format='- %s' "$SHA" -- plugins/vibe-flow)

Updated to vibe-flow $SHA (tools/rollout-projects.sh): the canonical git-guards kit
and the CLAUDE.md rules block. Files the project edited itself were left alone.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
${SESSION_URL:+Claude-Session: $SESSION_URL}
EOF
}

manifest_get() { sed -n "s/^$2=//p" "$1" | head -1; }

# Merge PR $2 from worktree $1, pinned to commit $3. A refusal right after the PR is
# created is usually required checks still running: wait for them (15 minutes at most),
# then retry once. A check that never finishes leaves the PR open instead of hanging ship.
merge_pr() {
    local W="$1" n="$2" c="$3" err rc i none=0
    err=$(cd "$W" && gh pr merge "$n" --merge --match-head-commit "$c" 2>&1) && return 0
    say "  merge refused ($(printf '%s' "$err" | tail -1)) — waiting for the required PR checks…"
    for i in $(seq 1 60); do
        err=$(cd "$W" && gh pr checks "$n" --required 2>&1); rc=$?
        [ "$rc" = 0 ] && break
        if [ "$rc" = 8 ]; then sleep 15; continue; fi                       # pending
        if printf '%s' "$err" | grep -qi 'no .*checks reported'; then      # not registered yet
            none=$((none + 1)); [ "$none" -ge 6 ] && break; sleep 15; continue
        fi
        warn "PR #$n: required checks failed — not merged"; return 1
    done
    [ "$rc" = 8 ] && { warn "PR #$n: required checks still pending after 15 minutes — not merged; re-run ship later"; return 1; }
    err=$(cd "$W" && gh pr merge "$n" --merge --match-head-commit "$c" 2>&1) && return 0
    warn "PR #$n: merge refused — $(printf '%s' "$err" | tail -1)"
    return 1
}

remove_worktree() { # $1 project, $2 worktree, $3 branch — only a clean one (Codex C4)
    # A tracked *.tsbuildinfo is a compiler cache the pre-push typecheck of this run rewrote,
    # not work: restore it. Anything else that is dirty keeps the worktree.
    git -C "$2" diff --name-only -z -- '*.tsbuildinfo' 2>/dev/null \
        | xargs -0 -I{} git -C "$2" checkout -q -- {} 2>/dev/null
    if [ -n "$(git -C "$2" status --porcelain --untracked-files=all 2>/dev/null)" ]; then
        warn "$(basename "$1"): worktree has uncommitted/untracked files — left in place: $2"
        return 1
    fi
    git -C "$1" worktree remove "$2" && git -C "$1" branch -D "$3" >/dev/null 2>&1 && return 0
    warn "$(basename "$1"): could not remove worktree $2 — remove it by hand"
    return 1
}

case "$CMD" in
list)
    fetch_main
    SHA=$(git -C "$REPO" rev-parse origin/main)
    snapshot
    rm -rf "$RUN/diffs"; mkdir -p "$RUN/diffs"
    while IFS= read -r P; do
        T=$(mktemp -d)
        S="$P"; CM="$P/CLAUDE.md"; extra=""
        if has_origin "$P"; then
            PROT=$(conf "$P" GG_PROTECTED)
            if git -C "$P" fetch -q origin "$PROT" 2>/dev/null; then
                S="$T/view"; mkdir -p "$S"; view_ref "$P" "origin/$PROT" "$S"
                [ -f "$S/CLAUDE.md" ] && CM="$S/CLAUDE.md"
                if [ "$(git -C "$P" branch --show-current)" = "$PROT" ]; then
                    b=$(git -C "$P" rev-list --count "HEAD..origin/$PROT" 2>/dev/null)
                    [ "${b:-0}" -gt 0 ] && extra=" · main folder $b commit(s) behind origin"
                fi
            else
                extra=" · origin unreachable — compared with the main folder"
            fi
        fi
        pairs | while IFS="$(printf '\t')" read -r rel dst; do
            [ -f "$S/$dst" ] || { say "    + $dst"; continue; }
            cmp -s "$GG/$rel" "$S/$dst" && continue
            known_blob "$rel" "$(git hash-object "$S/$dst")" && say "    ~ $dst" || say "    ! $dst (edited by the project)"
        done > "$T/out"
        : > "$T/notes"
        st="$(rb "$CM" --check)"
        case "$st" in
            same) ;;
            update*) say "    ~ CLAUDE.md (rules block ${st#update })" >> "$T/out" ;;
            edited*) say "    ~ CLAUDE.md (rules block edited in project, ${st#edited })" >> "$T/out" ;;
            no-block) say "    ? CLAUDE.md (no vibe-flow block — run /vibe-flow:init)" >> "$T/notes" ;;
            missing)  say "    ? CLAUDE.md (missing)" >> "$T/notes" ;;
            *)        say "    ? CLAUDE.md ($st — skipped)" >> "$T/notes" ;;
        esac
        case "$st" in update*|edited*)
            d="$(rb "$CM" --diff)"
            h="$(printf '%s' "$d" | cksum | tr -d ' \t')"
            [ -f "$RUN/diffs/$h.diff" ] || printf '%s\n' "$d" > "$RUN/diffs/$h.diff"
            printf '%s\n' "$(basename "$P")" >> "$RUN/diffs/$h.projects" ;;
        esac
        n=$(grep -c . "$T/out")
        has_origin "$P" || extra=" · no origin"
        [ -e "$P/CLAUDE.md" ] && ! claude_in_git "$P" && extra="$extra · CLAUDE.md not in git"
        say "$(basename "$P"): $n change(s)$extra"
        cat "$T/out" "$T/notes"; rm -rf "$T"
    done < <(projects)
    : > "$RUN/rules.diff"
    for f in "$RUN"/diffs/*.diff; do
        [ -f "$f" ] || continue
        { printf '### rules block for: %s\n' "$(tr '\n' ' ' < "${f%.diff}.projects")"; cat "$f"; echo; } >> "$RUN/rules.diff"
    done
    { date '+%Y-%m-%d %H:%M:%S'; printf 'only=%s\n' "${GG_ROLLOUT_ONLY:-}"; } > "$RUN/listed"
    say ""
    if [ -s "$RUN/rules.diff" ]; then
        say "── rules block changes (read before prepare) ──"
        cat "$RUN/rules.diff"
        say "Review: $RUN/rules.diff"
    else
        say "Rules block: no changes."
    fi
    say "Pinned vibe-flow $SHA (v$VERSION)."
    say "Next: GG_ROLLOUT_SHA=$SHA $0 prepare"
    ;;
prepare)
    pin_from_args; snapshot
    NAME="${GG_ROLLOUT_BRANCH:-gg-update}-${SHA:0:8}"; BRANCH="wt/$NAME"
    MSG=$(mktemp); message > "$MSG"
    mkdir -p "$RUN/projects"
    while IFS= read -r P; do
        name=$(basename "$P")
        say "== $name"
        if ! has_origin "$P"; then
            # No remote: nothing to push and no PR — commit straight to the main folder
            changed=$(sync_files "$P"; plans_opt_in "$P")
            st="$(rb "$P/CLAUDE.md" --check)"
            case "$st" in update*|edited*)
                if claude_in_git "$P"; then
                    if [ -n "$(git -C "$P" status --porcelain -- CLAUDE.md)" ]; then
                        warn "CLAUDE.md has uncommitted edits — rules block not updated (commit them first)"
                    else
                        rb "$P/CLAUDE.md" >/dev/null && changed=$(printf '%s\nCLAUDE.md' "$changed")
                    fi
                else
                    mkdir -p "$RUN/backup"; bak="$RUN/backup/$name-CLAUDE-$(date +%Y%m%d-%H%M%S).md"
                    cp -n "$P/CLAUDE.md" "$bak" && rb "$P/CLAUDE.md" >/dev/null \
                        && say "  CLAUDE.md (not in git): $st · backup $bak" || warn "CLAUDE.md not updated"
                fi ;;
            esac
            changed=$(printf '%s\n' "$changed" | grep .)
            [ -n "$changed" ] || { say "  already up to date"; continue; }
            # shellcheck disable=SC2086
            (cd "$P" && bash scripts/git-safe-commit.sh --message-file "$MSG" -- $changed 2>&1 | tail -1)
            (cd "$P" && bash scripts/install-git-guards.sh >/dev/null 2>&1) && say "  hooks reinstalled (no origin — done)"
            continue
        fi
        W=$(wt_dir "$P"); M="$RUN/projects/$name"
        if [ -e "$W" ]; then
            if [ -f "$M" ] && [ "$(manifest_get "$M" worktree)" = "$W" ]; then
                say "  already prepared in this run: $W"
            else
                warn "$W exists but is not from this run — skipped"
            fi
            continue
        fi
        PROT=$(conf "$P" GG_PROTECTED)
        git -C "$P" fetch -q origin "$PROT" || { warn "fetch failed — skipped"; continue; }
        git -C "$P" worktree add -q --no-track -b "$BRANCH" "$W" "origin/$PROT" || { warn "worktree add failed — skipped"; continue; }
        changed=$(sync_files "$W"; plans_opt_in "$W")
        ignored=no
        if claude_in_git "$W"; then
            st="$(rb "$W/CLAUDE.md" --check)"
            case "$st" in update*|edited*)
                rb "$W/CLAUDE.md" >/dev/null && changed=$(printf '%s\nCLAUDE.md' "$changed") ;;
            esac
        else
            st="$(rb "$P/CLAUDE.md" --check)"
            case "$st" in update*|edited*)
                ignored=yes; say "  CLAUDE.md (not in git): would update — $st (applied on ship)" ;;
            esac
        fi
        changed=$(printf '%s\n' "$changed" | grep .)
        if [ -z "$changed" ]; then
            git -C "$P" worktree remove "$W"; git -C "$P" branch -D "$BRANCH" >/dev/null
            if [ "$ignored" = yes ]; then
                printf 'project=%s\nworktree=\nbranch=\ncommit=\nignored_claude=yes\n' "$P" > "$M"
            else
                rm -f "$M"; say "  already up to date"
            fi
            continue
        fi
        # pre-push checks types / dev readiness even for a markdown-only change
        deps "$P" "$W"
        if printf '%s\n' "$changed" | grep -qvx 'CLAUDE.md'; then
            (cd "$W" && bash scripts/test-git-guards.sh >/dev/null 2>&1) && say "  test-git-guards ✅" \
                || warn "test-git-guards FAILED in $W"
        fi
        base=$(git -C "$W" rev-parse HEAD)
        # shellcheck disable=SC2086
        (cd "$W" && bash scripts/git-safe-commit.sh --message-file "$MSG" -- $changed 2>&1 | tail -1)
        commit=$(git -C "$W" rev-parse HEAD)
        if [ "$commit" = "$base" ]; then
            warn "commit failed in $W — not recorded for ship"; continue
        fi
        printf 'project=%s\nworktree=%s\nbranch=%s\ncommit=%s\nignored_claude=%s\n' \
            "$P" "$W" "$BRANCH" "$commit" "$ignored" > "$M"
        say "  worktree: $W ($commit)"
    done < <(projects)
    rm -f "$MSG"
    say ""
    say "Next: vibe-flow:release-gate on each worktree above, then: GG_ROLLOUT_SHA=$SHA $0 ship"
    exit "$FAILED"
    ;;
ship)
    pin_from_args; snapshot
    [ -d "$RUN/projects" ] || die "nothing prepared for $SHA — run prepare first"
    mkdir -p "$RUN/done" "$RUN/backup"
    for M in "$RUN"/projects/*; do
        [ -f "$M" ] || continue
        P=$(manifest_get "$M" project); W=$(manifest_get "$M" worktree)
        BRANCH=$(manifest_get "$M" branch); COMMIT=$(manifest_get "$M" commit)
        IGN=$(manifest_get "$M" ignored_claude); name=$(basename "$P")
        only_ok "$name" || continue
        [ -d "$P" ] || { warn "$P is gone — skipped"; continue; }
        say "== $name"
        if [ -n "$W" ]; then
            PROT=$(conf "$P" GG_PROTECTED)
            [ -d "$W" ] || { warn "worktree $W is gone — skipped"; continue; }
            [ "$(git -C "$W" rev-parse HEAD)" = "$COMMIT" ] \
                || { warn "HEAD of $W is not the prepared commit $COMMIT — skipped"; continue; }
            # Exactly the manifest commit must reach the remote and be merged (Codex C3)
            if ! (cd "$W" && git push -q -u origin "$BRANCH"); then
                warn "push refused — nothing merged; fix and re-run ship"; continue
            fi
            remote=$(git -C "$W" ls-remote origin "refs/heads/$BRANCH" | cut -f1)
            [ "$remote" = "$COMMIT" ] || { warn "remote $BRANCH is $remote, not $COMMIT — nothing merged"; continue; }
            n=$(cd "$W" && gh pr view "$BRANCH" --json number -q .number 2>/dev/null)
            if [ -z "$n" ]; then
                title=$(git -C "$W" log -1 --format=%s)
                body="$(git -C "$W" log -1 --format=%b | sed '/^Co-Authored-By:/,$d')
🤖 Generated with [Claude Code](https://claude.com/claude-code)

$SESSION_URL"
                url=$(cd "$W" && gh pr create --base "$PROT" --head "$BRANCH" --title "$title" --body "$body" 2>&1 | tail -1)
                n="${url##*/}"
            fi
            head=$(cd "$W" && gh pr view "$n" --json headRefOid -q .headRefOid 2>/dev/null)
            [ "$head" = "$COMMIT" ] || { warn "PR #$n head is $head, not $COMMIT — not merged"; continue; }
            merge_pr "$W" "$n" "$COMMIT"
            state=$(cd "$W" && gh pr view "$n" --json state -q .state 2>/dev/null)
            say "  PR #$n → $state"
            [ "$state" = "MERGED" ] || { warn "PR #$n not merged"; continue; }
            # The main folder runs these scripts — without a pull it keeps the old kit
            git -C "$P" fetch -q origin "$PROT"
            if [ "$(git -C "$P" branch --show-current)" = "$PROT" ] \
               && git -C "$P" merge -q --ff-only "origin/$PROT" 2>/dev/null; then
                (cd "$P" && bash scripts/install-git-guards.sh >/dev/null 2>&1) && say "  main folder pulled, hooks reinstalled"
                # the plans folder is git-ignored: create it in the main folder (and info/exclude)
                python3 "$GG/settings-merge.py" "$P" >/dev/null 2>&1 || warn "plans folder not set up in the main folder"
            else
                warn "main folder not fast-forwarded (other branch, divergence or conflicting local edits) — pull it by hand"
            fi
        fi
        if [ "$IGN" = yes ]; then
            # CLAUDE.md outside git: only after the "yes" to ship, from the same snapshot
            bak="$RUN/backup/$name-CLAUDE-$(date +%Y%m%d-%H%M%S).md"
            cp -n "$P/CLAUDE.md" "$bak" || { warn "cannot back up $P/CLAUDE.md — not written"; continue; }
            st="$(rb "$P/CLAUDE.md")" || st=error
            case "$st" in
                update*|edited*|same) say "  CLAUDE.md (not in git): $st · backup $bak" ;;
                *) warn "rules block not written to $P/CLAUDE.md ($st)"; continue ;;
            esac
        fi
        if [ -n "$W" ]; then
            slug=$(cd "$P" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
            if remove_worktree "$P" "$W" "$BRANCH"; then
                [ -n "$slug" ] && gh api -X DELETE "repos/$slug/git/refs/heads/$BRANCH" >/dev/null 2>&1
                say "  worktree and branch removed"
            fi
        fi
        mv "$M" "$RUN/done/$name"
    done
    exit "$FAILED"
    ;;
plugins)
    CLI="${GG_ROLLOUT_CLAUDE:-claude}"
    REG="${GG_ROLLOUT_PLUGINS_JSON:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json}"
    [ -f "$REG" ] || die "plugin registry not found: $REG"
    fetch_main
    SHA=$(git -C "$REPO" rev-parse origin/main)
    MP=$(git -C "$REPO" show "$SHA:.claude-plugin/marketplace.json" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])') || die "cannot read the marketplace name"
    say "marketplace $MP · reference: vibe-flow origin/main $SHA"
    if ! out=$("$CLI" plugin marketplace update "$MP" </dev/null 2>&1); then
        warn "marketplace update failed: $(printf '%s' "$out" | tail -1)"
    fi
    TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
    projects all | tr '\n' '\0' > "$TMPD/projects"
    # Validated records, NUL-terminated: scope<TAB>plugin<TAB>expected<TAB>path (path last)
    python3 - "$REG" "$MP" "$REPO" "$SHA" "$TMPD/projects" "${GG_ROLLOUT_ONLY:-}" "$ROOTS" \
        > "$TMPD/records" 2> "$TMPD/skipped" <<'PY'
import json, os, re, subprocess, sys
reg, mp, repo, sha, plist, only, roots = sys.argv[1:8]
projects = {os.path.realpath(p) for p in open(plist, encoding="utf-8").read().split("\0") if p}
roots = [os.path.realpath(r) for r in roots.split() if r]
only = set(only.split())
key_re = re.compile(r"^[A-Za-z0-9._-]+@" + re.escape(mp) + r"$")
def warn(msg): print(f"  ⚠️  {msg}", file=sys.stderr)
expected = {}
def expected_version(plugin):
    if plugin not in expected:
        try:
            m = json.loads(subprocess.run(["git", "-C", repo, "show", f"{sha}:.claude-plugin/marketplace.json"],
                                          capture_output=True, check=True).stdout)
            src = next(p["source"] for p in m["plugins"] if p["name"] == plugin)
            pj = subprocess.run(["git", "-C", repo, "show", f"{sha}:{os.path.normpath(src)}/.claude-plugin/plugin.json"],
                                capture_output=True, check=True).stdout
            expected[plugin] = json.loads(pj)["version"]
        except Exception:
            expected[plugin] = ""
    return expected[plugin]
data = json.load(open(reg, encoding="utf-8"))
for key, entries in sorted(data.get("plugins", {}).items()):
    if not key.endswith("@" + mp):
        continue
    if not key_re.match(key):
        warn(f"{key!r}: unexpected plugin name — skipped"); continue
    plugin = key.split("@", 1)[0]
    for e in entries:
        scope, path = e.get("scope"), e.get("projectPath", "")
        if scope not in ("project", "local", "user"):
            warn(f"{key} scope {scope!r} — skipped"); continue
        if scope == "user":
            if only:
                continue
            path = os.path.expanduser("~")
        else:
            if only and os.path.basename(os.path.normpath(path)) not in only:
                continue   # outside GG_ROLLOUT_ONLY: not checked, not reported
            shown = path.encode("unicode_escape").decode()
            if any(c in path for c in "\t\n\0") or not os.path.isabs(path):
                warn(f"{shown}: invalid path — skipped"); continue
            if not os.path.isdir(path):
                warn(f"{shown}: project folder not found — skipped"); continue
            real = os.path.realpath(path)
            if not any(os.path.commonpath([real, r]) == r for r in roots):
                warn(f"{shown}: outside GG_ROLLOUT_ROOTS — skipped"); continue
            if real not in projects:
                warn(f"{shown}: not a vibe-flow project (no git-guards) — skipped"); continue
        sys.stdout.write(f"{scope}\t{key}\t{expected_version(plugin) or '-'}\t{path}\0")
PY
    rc=$?
    cat "$TMPD/skipped"
    [ "$rc" = 0 ] || die "cannot read the plugin registry $REG"
    [ -s "$TMPD/skipped" ] && FAILED=1
    regver() { # key scope path → version in the registry now
        python3 - "$REG" "$1" "$2" "$3" <<'PY'
import json,sys
reg,key,scope,path=sys.argv[1:5]
for e in json.load(open(reg)).get("plugins",{}).get(key,[]):
    if e.get("scope")==scope and (scope=="user" or e.get("projectPath")==path):
        print(e.get("version","")); break
PY
    }
    while IFS="$(printf '\t')" read -r -d '' scope key want path; do
        [ "$want" = - ] && want=""
        [ -n "$path" ] && [ -d "$path" ] || { warn "$key: malformed record — skipped"; continue; }
        label="$(basename "$path")"; [ "$scope" = user ] && label="(user)"
        before=$(regver "$key" "$scope" "$path")
        if (cd -- "$path" && "$CLI" plugin update "$key" --scope "$scope" </dev/null >"$TMPD/out" 2>&1); then rc=0; else rc=$?; fi
        after=$(regver "$key" "$scope" "$path")
        short="${key%@*}"
        if [ "$rc" != 0 ] || { [ -n "$want" ] && [ "$after" != "$want" ]; }; then
            warn "$label $short: $before → ${after:-?} (expected ${want:-?}): $(tail -1 "$TMPD/out")"
        elif [ "$before" = "$after" ]; then
            say "  $label $short: already $after"
        else
            say "  $label $short: $before → $after"
        fi
    done < "$TMPD/records"
    say "Restart Claude sessions in these projects to load the new version."
    exit "$FAILED"
    ;;
*) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
