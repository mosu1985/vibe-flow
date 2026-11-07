#!/usr/bin/env bash
# post-edit-tests.sh — PostToolUse (Edit|Write|MultiEdit): runs the tests related
# to the file the model has just edited, and hands a red result back to the model
# right away ({"decision":"block","reason":…}) instead of at commit time.
#
# The real work is in post-edit-tests.py. This wrapper exists for the cheap part:
# the hook fires on EVERY edit in every session (plans, translations, markdown), so
# the path mask is checked first, in plain bash — before any git or python process.
# The mask here is only a prefilter (the project's .gitguards.conf or the default);
# the authoritative policy is read by the python part from origin.
#
# FAIL-OPEN: any infrastructure breakage (no python3, broken input, no repository)
# means exit 0 with no output. A convenience check must never block work.
set -u

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

DEFAULT_GLOBS="*.ts *.tsx *.mts *.cts *.js *.jsx *.mjs *.cjs *.vue *.svelte"

# ── 1. Path mask, pure bash ──────────────────────────────────────────────────
# A path with JSON escapes inside is not decoded here — it goes on to python.
fp=""
re='"file_path"[[:space:]]*:[[:space:]]*"([^"\\]*)"'
if [[ $INPUT =~ $re ]]; then fp="${BASH_REMATCH[1]}"; fi
if [ -n "$fp" ]; then
    case "$fp" in */node_modules/*|*/.git/*|.git/*) exit 0 ;; esac
    globs=""
    conf="${CLAUDE_PROJECT_DIR:-}/.gitguards.conf"
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$conf" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in GG_POST_EDIT_GLOBS=*) globs="${line#GG_POST_EDIT_GLOBS=}" ;; esac
        done < "$conf"
        case "$globs" in \"*\") globs="${globs#\"}"; globs="${globs%\"}" ;; \'*\') globs="${globs#\'}"; globs="${globs%\'}" ;; esac
    fi
    [ -n "$globs" ] || globs="$DEFAULT_GLOBS"
    match=0
    set -f                          # the masks must not expand against the disk
    for g in $globs; do
        # shellcheck disable=SC2053
        if [[ $fp == $g || $fp == */$g ]]; then match=1; break; fi
    done
    set +f
    [ "$match" = "1" ] || exit 0
fi

# ── 2. The rest: python ──────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || exit 0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || exit 0
[ -f "$DIR/post-edit-tests.py" ] || exit 0
printf '%s' "$INPUT" | python3 -B "$DIR/post-edit-tests.py" 2>/dev/null
exit 0
