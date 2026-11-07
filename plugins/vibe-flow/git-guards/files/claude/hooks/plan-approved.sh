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
#   - realpath(tool_response.filePath) lies directly in ${GG_PLANS_DIR:-~/.claude/plans}
#     (a symlink pointing out of it does not count) and is a bare <name>.md;
#   - tool_response.plan — the text the user approved, with their edits — has the
#     `Гейт: ✅ пройден` / `Gate: ✅ passed` line and the external critic is settled:
#     a `## … Codex` section, OR the `| Codex …` gate row says `❌ unavailable —
#     user's decision`, OR it says `⚪️ not installed` and codex is really absent
#     (PATH and the standard locations). Without Codex the gate goes by the Claude
#     reviewers (vibe-flow 1.2.1); details and the pure, tested functions are in
#     plan-approved.py. The sha256 of exactly that text goes into the mark.
# The mark goes to the common dir of $CLAUDE_PROJECT_DIR:
#   monitorex-locks/plan-approved/<name>   ts=<epoch> sha256=<hex> session=<id> plan=<name>
#
# A plan that was approved but does not qualify → the reason goes to the model
# ({"decision":"block","reason":…}), so the session knows a [feat] citing it will
# be rejected. Infrastructure trouble (no python3, broken input, not a repository)
# → no mark, exit 0: this hook must never break the turn.
set -u
command -v python3 >/dev/null 2>&1 || exit 0
# Built-ins only: under a trimmed PATH (GUI launch) dirname may be missing.
case "$0" in */*) PY="${0%/*}/plan-approved.py" ;; *) PY="./plan-approved.py" ;; esac
[ -f "$PY" ] || exit 0
exec python3 -B "$PY"
