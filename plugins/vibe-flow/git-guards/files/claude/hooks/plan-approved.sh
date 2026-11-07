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
#   - tool_response.plan — the text the user approved, with their edits — has a
#     `## … Codex` section and a `Гейт: ✅ пройден` / `Gate: ✅ passed` line;
#     the sha256 of exactly that text goes into the mark.
# The mark goes to the common dir of $CLAUDE_PROJECT_DIR:
#   monitorex-locks/plan-approved/<name>   ts=<epoch> sha256=<hex> session=<id> plan=<name>
#
# A plan that was approved but does not qualify → the reason goes to the model
# ({"decision":"block","reason":…}), so the session knows a [feat] citing it will
# be rejected. Infrastructure trouble (no python3, broken input, not a repository)
# → no mark, exit 0: this hook must never break the turn.
set -u
command -v python3 >/dev/null 2>&1 || exit 0
exec python3 -B -c '
import hashlib, json, os, re, subprocess, sys, tempfile, time

def tell(reason):
    print(json.dumps({"decision": "block", "reason": "Plan approval mark NOT written: " + reason},
                     ensure_ascii=False))
    sys.exit(0)

try:
    p = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
if not isinstance(p, dict) or p.get("tool_name") != "ExitPlanMode":
    sys.exit(0)
r = p.get("tool_response")
if not isinstance(r, dict):
    sys.exit(0)
if p.get("agent_id") or r.get("isAgent") is not False:
    tell("this plan was approved inside an agent, not by the user.")
fp, plan = r.get("filePath"), r.get("plan")
if not isinstance(fp, str) or not fp.strip() or not isinstance(plan, str) or not plan.strip():
    tell("ExitPlanMode returned no plan file path or no plan text.")
try:
    plans = os.path.realpath(os.path.expanduser(os.environ.get("GG_PLANS_DIR") or "~/.claude/plans"))
    real = os.path.realpath(os.path.expanduser(fp))
    name = os.path.basename(real)
    if (os.path.dirname(real) != plans or ".." in name
            or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._-]*\.md", name)):
        tell("the plan file is not a <name>.md directly in " + plans + ".")
    if not re.search(r"(?m)^## .*Codex", plan) \
            or not re.search(r"(?m)^(Гейт: ✅ пройден|Gate: ✅ passed)", plan):
        tell("the approved text of " + name + " has no `## … Codex` section or no "
             "`Гейт: ✅ пройден` / `Gate: ✅ passed` line. A [feat] push citing this plan "
             "will be rejected by pre-push until the plan passes the gate and is approved again.")
    proj = os.environ.get("CLAUDE_PROJECT_DIR") or ""
    if not proj or not os.path.isdir(proj):
        sys.exit(0)
    common = subprocess.run(["git", "-C", proj, "rev-parse", "--git-common-dir"],
                            capture_output=True, text=True, timeout=5).stdout.strip()
    if not common:
        sys.exit(0)
    if not os.path.isabs(common):
        common = os.path.join(proj, common)
    d = os.path.join(os.path.realpath(common), "monitorex-locks", "plan-approved")
    os.makedirs(d, exist_ok=True)
    sid = str(p.get("session_id") or "").replace("\n", " ")
    body = "ts=%d\nsha256=%s\nsession=%s\nplan=%s\n" % (
        int(time.time()), hashlib.sha256(plan.encode("utf-8")).hexdigest(), sid, name)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    with os.fdopen(fd, "w") as fh:
        fh.write(body)
    os.replace(tmp, os.path.join(d, name))
except SystemExit:
    raise
except Exception:
    sys.exit(0)
'
