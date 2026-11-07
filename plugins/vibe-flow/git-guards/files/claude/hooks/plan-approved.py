"""plan-approved.py — logic of the plan approval mark (PostToolUse on ExitPlanMode).

Called by plan-approved.sh. See that file for WHY a hook writes the mark.

The mark is written when the text the user approved (tool_response.plan) has the
gate line and the external critic part is settled in ONE of three ways:
  1. a `## … Codex` section — the critic ran;
  2. the Codex row of the gate table says `❌ unavailable — user's decision`;
  3. the Codex row says `⚪️ (Critic) not installed` AND codex is really not
     installed (neither on PATH nor in the standard locations). If codex IS found,
     the critic was forgotten → no mark, the model is told to run codex-plan-critic.
Markers count ONLY inside the status cell of a single table line starting with
`| Codex`: prose, quotes and reviewer sections that cite the markers do not count.

Pure functions decide() / codex_found() / search_dirs() are tested directly by
test-git-guards.sh: the «no Codex» branch must be testable on a machine that has
Codex installed, so it is never tested through the machine's environment.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

GATE_LINE = re.compile(r"(?m)^(Гейт: ✅ пройден|Gate: ✅ passed)")
CODEX_SECTION = re.compile(r"(?m)^## .*Codex")
CODEX_ROW = re.compile(r"^[ \t]*\|[ \t]*Codex\b", re.I)
# ⚪ U+26AA, optional U+FE0F; ❌ U+274C. No \s: a marker never spans lines.
NOT_INSTALLED = re.compile(
    "⚪️?[ \t]*(?:\\(?(?:critic|codex|критик)\\)?[ \t]+)*(?:not installed|не установлен)",
    re.I)
USER_DECISION = re.compile(
    "❌[ \t]*(?:unavailable|недоступен)[ \t]*[—–-][ \t]*"
    "(?:user.?s decision|решение пользователя)",
    re.I)

STANDARD_DIRS = ("~/.local/bin", "~/.codex/packages/standalone/current/bin",
                 "/opt/homebrew/bin", "/usr/local/bin", "~/.npm-global/bin")


def search_dirs(extra=""):
    """Standard Codex locations — ALWAYS; GG_CODEX_SEARCH_PATHS may only ADD."""
    dirs = [os.path.expanduser(d) for d in STANDARD_DIRS]
    for d in (extra or "").split(":"):
        if d.strip():
            dirs.append(os.path.expanduser(d.strip()))
    return dirs


def codex_found(path_env, dirs):
    if shutil.which("codex", path=path_env or ""):
        return True
    for d in dirs:
        f = os.path.join(d, "codex")
        if os.path.isfile(f) and os.access(f, os.X_OK):
            return True
    return False


def _cells(line):
    """Split a table line on UNescaped `|`; `\\|` stays inside the cell."""
    cells, cur, i = [], "", 0
    while i < len(line):
        ch = line[i]
        if ch == "\\" and i + 1 < len(line) and line[i + 1] == "|":
            cur += "|"; i += 2; continue
        if ch == "|":
            cells.append(cur); cur = ""
        else:
            cur += ch
        i += 1
    cells.append(cur)
    return [c.strip() for c in cells]


def _status_cells(plan):
    """Status cell (last non-empty) of every `| Codex …` table line."""
    out = []
    for line in plan.splitlines():
        if CODEX_ROW.match(line):
            filled = [c for c in _cells(line) if c]
            if filled:
                out.append(filled[-1])
    return out


def decide(plan, found):
    """→ (ok, kind, reason). kind: section | user-decision | not-installed | refused."""
    if not GATE_LINE.search(plan or ""):
        return (False, "refused", "the approved text has no `Гейт: ✅ пройден` / "
                "`Gate: ✅ passed` line — the plan did not pass the gate.")
    if CODEX_SECTION.search(plan):
        return (True, "section", "")
    statuses = _status_cells(plan)
    if any(USER_DECISION.search(c) for c in statuses):
        return (True, "user-decision", "")
    if any(NOT_INSTALLED.search(c) for c in statuses):
        if found:
            return (False, "refused", "the gate table says the external critic is not "
                    "installed, but codex IS installed — run codex-plan-critic on the plan "
                    "and approve it again.")
        return (True, "not-installed", "")
    return (False, "refused", "the approved text has no `## … Codex` section and its "
            "`| Codex …` gate row says neither `⚪️ not installed` (codex absent) nor "
            "`❌ unavailable — user's decision`.")


def _tell(reason):
    print(json.dumps({"decision": "block",
                      "reason": "Plan approval mark NOT written: " + reason + " A [feat] "
                      "push citing this plan will be rejected by pre-push until the plan "
                      "passes the gate and is approved again."}, ensure_ascii=False))
    sys.exit(0)


def main():
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
        _tell("this plan was approved inside an agent, not by the user.")
    fp, plan = r.get("filePath"), r.get("plan")
    if not isinstance(fp, str) or not fp.strip() or not isinstance(plan, str) or not plan.strip():
        _tell("ExitPlanMode returned no plan file path or no plan text.")
    try:
        plans = os.path.realpath(os.path.expanduser(os.environ.get("GG_PLANS_DIR") or "~/.claude/plans"))
        real = os.path.realpath(os.path.expanduser(fp))
        name = os.path.basename(real)
        if (os.path.dirname(real) != plans or ".." in name
                or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._-]*\.md", name)):
            _tell("the plan file is not a <name>.md directly in " + plans + ".")
        found = codex_found(os.environ.get("PATH", ""),
                            search_dirs(os.environ.get("GG_CODEX_SEARCH_PATHS", "")))
        ok, kind, reason = decide(plan, found)
        if not ok:
            _tell("for " + name + ": " + reason)
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
        body = "ts=%d\nsha256=%s\nsession=%s\nplan=%s\ncritic=%s\n" % (
            int(time.time()), hashlib.sha256(plan.encode("utf-8")).hexdigest(), sid, name, kind)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
        with os.fdopen(fd, "w") as fh:
            fh.write(body)
        os.replace(tmp, os.path.join(d, name))
        if kind != "section":
            why = ("the user decided to go without it" if kind == "user-decision"
                   else "codex is not installed")
            print(json.dumps({"systemMessage":
                              "Plan approval mark for " + name + " was written WITHOUT the "
                              "external critic (" + why + "). If you did not decide that, "
                              "delete monitorex-locks/plan-approved/" + name + "."},
                             ensure_ascii=False))
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)


if __name__ == "__main__":
    main()
