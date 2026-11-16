#!/usr/bin/env bash
# plan-approved.sh — PostToolUse (ExitPlanMode): writes the plan approval mark
# that githooks/plan-gate.sh requires before a [feat] / new migration is pushed.
#
# WHY A HOOK. The mark must prove that the USER approved the plan. The model
# cannot write it (the PreToolUse guard forbids any write into monitorex-locks/),
# and a reviewer subagent in Plan Mode cannot write at all. A Claude Code hook is
# part of the harness and runs outside the permission system.
# Live probe of 07.11.2026 (Claude Code 2.1.319): PostToolUse fires on an approved
# ExitPlanMode; a rejection (Esc) fires neither PostToolUse nor PostToolUseFailure;
# outside plan mode the tool fails ("not in plan mode"); subagents do not have the
# tool. tool_input arrives EMPTY; permission_mode already shows the mode AFTER
# approval, so it is not checked.
#
# TRUSTS ONLY tool_response (M8). tool_input.planFilePath is set by the model and
# is never read. All of the following must hold:
#   - no agent_id in the hook input and tool_response.isAgent === false (a
#     teammate's plan approved by a lead agent is not a human approval);
#   - realpath(tool_response.filePath) lies directly in one of the plans directories —
#     $GG_PLANS_DIR (if set), <project>/<plansDirectory>, <main tree>/<plansDirectory>,
#     ~/.claude/plans (a symlink pointing out does not count) — and is a bare <name>.md;
#     a plan naming other repositories is also copied into their plans directory;
#   - tool_response.plan — the text the user approved, with their edits — has the
#     `Гейт: ✅ пройден` / `Gate: ✅ passed` line and the external critic is settled:
#     a `## … Codex` section, OR the `| Codex …` gate row says `❌ unavailable —
#     user's decision`, OR it says `⚪️ not installed` and codex is really absent
#     (PATH and the standard locations). Without Codex the gate goes by the Claude
#     reviewers (vibe-flow 1.2.1); details and the pure, tested functions are in
#     plan-approved.py. The sha256 of exactly that text goes into the mark.
# The mark goes to the common dir of $CLAUDE_PROJECT_DIR, AND to the common dir of
# every repository the plan names in its header (above the first `## `), one per
# line: `Репозиторий: ~/dev/x (comment)` / `Repository: /abs/path` — only main working
# trees inside $HOME with the kit installed (monitorex-hooks/plan-gate.sh), at most 5;
# hidden header text (<!--, a code fence) → no foreign marks (vibe-flow 1.2.5):
#   monitorex-locks/plan-approved/<name>   ts=<epoch> sha256=<hex> session=<id> plan=<name> critic=<kind> source=<project>
# Where it was written / why a target was refused → ONE systemMessage to the user.
#
# A plan that was approved but does not qualify → the reason goes to the model
# ({"decision":"block","reason":…}), so the session knows a [feat] citing it will
# be rejected. Infrastructure trouble (no python3, broken input, not a repository)
# → no mark, exit 0: this hook must never break the turn.
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

# Built-ins only: under a trimmed PATH (GUI launch) dirname may be missing.
case "$0" in */*) PY="${0%/*}/plan-approved.py" ;; *) PY="./plan-approved.py" ;; esac
[ -f "$PY" ] || exit 0
gg_hook_exec "$PY"
