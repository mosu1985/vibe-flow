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
# FAIL-OPEN: any infrastructure breakage (no Python, broken input, no repository)
# means exit 0 with no output. A convenience check must never block work.
set -u
# >>> gg-inline:pyenv >>>
# Python resolver (vibe-flow 1.3.0; source: scripts/git-guards/pyenv.sh — keep copies identical).
# Candidates: python3, python, py -3. "Not a real Python": exit 9009/49/127 or a path
# under WindowsApps (the Microsoft Store alias). Floor: Python 3.9.
gg_py_fake() {   # RC PATH → 0 when this is not a real Python
    case "${1-}" in 9009|49|127) return 0 ;; esac
    case "${2-}" in
        */[Ww][Ii][Nn][Dd][Oo][Ww][Ss][Aa][Pp][Pp][Ss]/*) return 0 ;;
        *\\[Ww][Ii][Nn][Dd][Oo][Ww][Ss][Aa][Pp][Pp][Ss]\\*) return 0 ;;
    esac
    return 1
}
_gg_py_probe() { # CMD [ARG] → 0 and _gg_exe = sys.executable when it runs and is >= 3.9
    _gg_exe=$("$@" -c 'import sys; sys.stdout.write(sys.executable if sys.version_info >= (3, 9) else "")' 2>/dev/null)
    _gg_prc=$?
    [ "$_gg_prc" = 0 ] && [ -n "$_gg_exe" ] || return 1
    if gg_py_fake 0 "$_gg_exe"; then return 1; fi
    return 0
}
# gg_python: export GG_PY (a verified interpreter path) or say why not; rc 0/1.
# An inherited GG_PY is never trusted: it is run and checked like any candidate.
gg_python() {
    PYTHONUTF8=1; PYTHONIOENCODING=utf-8; export PYTHONUTF8 PYTHONIOENCODING
    if [ -n "${GG_PY:-}" ] && _gg_py_probe "$GG_PY"; then GG_PY=$_gg_exe; export GG_PY; return 0; fi
    for _gg_c in python3 python py; do
        _gg_p=$(command -v "$_gg_c" 2>/dev/null) || continue
        if gg_py_fake 0 "$_gg_p"; then continue; fi
        if [ "$_gg_c" = py ]; then _gg_py_probe "$_gg_p" -3 || continue
        else _gg_py_probe "$_gg_p" || continue
        fi
        GG_PY=$_gg_exe; export GG_PY; return 0
    done
    GG_PY=""
    echo "🔴 no working Python 3.9+ found (tried python3, python, py -3) — install Python 3.9+ from python.org" >&2
    return 1
}
# gg_hook_exec SCRIPT [ARGS...]: the hook wrappers' loop. Reads stdin once, runs
# `<candidate> SCRIPT ARGS` with it; exits with the hook's own code. Skips (without
# running) a missing candidate or one under WindowsApps; moves on after rc 9009, 49,
# 127 ("not a real Python") or 86 (the hook's "interpreter below 3.9"). No candidate
# left: exit 0 (fail-open, the owner's decision; the installer self-test is loud).
# stdin goes to a mktemp file when mktemp and cat exist, else (a trimmed PATH) into
# a shell variable through bash's `read -d ''` — this function runs only in bash.
gg_hook_exec() {
    PYTHONUTF8=1; PYTHONIOENCODING=utf-8; PYTHONDONTWRITEBYTECODE=1
    export PYTHONUTF8 PYTHONIOENCODING PYTHONDONTWRITEBYTECODE
    _gg_buf=""; _gg_in=""
    if command -v mktemp >/dev/null 2>&1 && command -v cat >/dev/null 2>&1; then
        _gg_buf=$(mktemp "${TMPDIR:-/tmp}/gg-hook.XXXXXX" 2>/dev/null) || _gg_buf=""
    fi
    trap '[ -z "$_gg_buf" ] || rm -f "$_gg_buf"' EXIT
    trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
    if [ -n "$_gg_buf" ]; then
        cat > "$_gg_buf" || exit 0
    else
        IFS= read -r -d '' _gg_in || true
    fi
    for _gg_c in python3 python py; do
        _gg_p=$(command -v "$_gg_c" 2>/dev/null) || continue
        if gg_py_fake 0 "$_gg_p"; then continue; fi
        if [ -n "$_gg_buf" ]; then
            if [ "$_gg_c" = py ]; then "$_gg_p" -3 "$@" < "$_gg_buf"; else "$_gg_p" "$@" < "$_gg_buf"; fi
        else
            if [ "$_gg_c" = py ]; then printf '%s' "$_gg_in" | "$_gg_p" -3 "$@"; else printf '%s' "$_gg_in" | "$_gg_p" "$@"; fi
        fi
        _gg_rc=$?
        case "$_gg_rc" in 9009|49|127|86) continue ;; esac
        exit "$_gg_rc"
    done
    exit 0
}
# <<< gg-inline:pyenv <<<

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

DEFAULT_GLOBS="*.ts *.tsx *.mts *.cts *.js *.jsx *.mjs *.cjs *.vue *.svelte"

# ── 1. Path mask, pure bash ──────────────────────────────────────────────────
# JSON escapes are understood: Claude Code on Windows sends "C:\\Users\\x\\a.md", and a
# prefilter that could not read it started Python plus ~7 git processes on every
# edit. An escaped backslash becomes "/" (the masks use "/"); other escapes stay.
fp=""
re='"file_path"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)"'
if [[ $INPUT =~ $re ]]; then fp="${BASH_REMATCH[1]}"; fp="${fp//\\\\//}"; fi
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
case "${BASH_SOURCE[0]}" in */*) DIR="${BASH_SOURCE[0]%/*}" ;; *) DIR=. ;; esac
DIR="$(cd "$DIR" 2>/dev/null && pwd -P)" || exit 0
[ -f "$DIR/post-edit-tests.py" ] || exit 0
# gg_hook_exec exits; in a pipeline it runs in a subshell, so this hook still ends with 0.
printf '%s' "$INPUT" | gg_hook_exec "$DIR/post-edit-tests.py" 2>/dev/null
exit 0
