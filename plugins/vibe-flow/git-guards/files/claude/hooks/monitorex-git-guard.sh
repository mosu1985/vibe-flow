#!/usr/bin/env bash
# monitorex-git-guard.sh — PreToolUse (Bash): blocks `git add` and `git commit`
# in the SHARED working tree.
#
# WHY SEPARATE FROM GIT HOOKS. git has no hook for `git add` — that is exactly why
# the first version of the scheme did not work: a neighbor managed to stage a file
# while someone else's commit was in progress. A Claude Code hook sees the command
# BEFORE it runs and can reject it. Git hooks remain the backstop for a human in a
# terminal, Codex and IDEs, which never pass through this layer at all.
#
# Command segment parsing comes from a vendored library (shell_segments.py): it
# follows `cd` along the chain, `bash -c`, subshells, `||` and pipes. A homegrown
# parser would have been strictly worse.
#
# FAIL-OPEN on any infrastructure breakage (no Python, broken input, not a git
# directory): a safety catch must not break work when it is unsure itself. But a
# DENY always reaches Claude Code: the interpreter is chosen by gg_hook_exec (the
# Store alias and Pythons below 3.9 are skipped, not run), and the guard's stdout,
# stderr and exit code pass through unchanged — exit 2 is Claude Code's block.
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

# Built-ins only from here: under a trimmed PATH (GUI launch) dirname may be missing.
case "${BASH_SOURCE[0]}" in */*) DIR="${BASH_SOURCE[0]%/*}" ;; *) DIR=. ;; esac
DIR="$(cd "$DIR" 2>/dev/null && pwd -P)" || exit 0
[ -f "$DIR/monitorex_git_guard.py" ] || exit 0
gg_hook_exec "$DIR/monitorex_git_guard.py"   # PYTHONDONTWRITEBYTECODE: no __pycache__ in the project
