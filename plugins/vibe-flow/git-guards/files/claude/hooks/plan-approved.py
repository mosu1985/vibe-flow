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

Where the mark goes: the common dir of the session's project ($CLAUDE_PROJECT_DIR),
as before, AND the common dir of every repository the plan names in its HEADER (the
text above the first `## `), one per line from the start of the line:
    Репозиторий: ~/dev/tg-assistant (any comment)      Repository: /abs/path
The path is the first token (whole if in backticks), the rest is a comment. That
list is part of the text the user approved. A named repository is accepted only if
(accept_repo): absolute or `~`, no symlinks in the path, inside realpath($HOME) by
commonpath, a MAIN working tree (P/.git is a directory and is the common dir — a
worktree or a `gitdir:` file is refused), and the kit is installed there
(<common>/monitorex-hooks/plan-gate.sh — a place the model cannot write, unlike
.gitguards.conf). At most 5. Hidden text in the header (`<!--`, a code fence) —
no foreign marks at all. The mark stays inside .git, where the model may not write in
any version of the guard, so an old copy of this hook elsewhere is harmless.

Pure functions decide() / codex_found() / search_dirs() / target_repos() /
header_hidden() / accept_repo() are tested directly by test-git-guards.sh: the «no
Codex» branch must be testable on a machine that has Codex installed, so it is never
tested through the machine's environment.
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
# ⚪ U+26AA, optional U+FE0F; ❌ U+274C (written as escapes: an editor may drop
# U+FE0F). No \s: a marker never spans lines. The marker must END the status cell:
# «… решение пользователя не получено» is not a decision.
NOT_INSTALLED = re.compile(
    "⚪️?[ \t]*(?:\\(?(?:critic|codex|критик)\\)?[ \t]+)*"
    "(?:not installed|не установлен)[ \t.]*$",
    re.I)
USER_DECISION = re.compile(
    "❌[ \t]*(?:unavailable|недоступен)[ \t]*[—–-][ \t]*"
    "(?:user.?s decision|решение пользователя)[ \t.]*$",
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


TARGET_LINE = re.compile(r"^(?:Репозиторий|Repository):[ \t]*(.*)$")
TARGET_PATH = re.compile(r"^[~/][^\s`]*$")
MAX_TARGETS = 5
TARGETS_DEADLINE = 15.0
_CTRL = re.compile(r"[\x00-\x1f\x7f]")


def _header_lines(plan):
    """Lines of the plan header: everything above the first `## ` (CRLF tolerated)."""
    out = []
    for line in (plan or "").split("\n"):
        if line.lstrip().startswith("## "):
            break
        out.append(line[:-1] if line.endswith("\r") else line)
    return out


def header_hidden(plan):
    """Text the approval window may not show (HTML comment, code fence) in the header."""
    return any("<!--" in l or "<details" in l.lower() or _CTRL.search(l.replace("\t", ""))
               or l.lstrip().startswith(("```", "~~~")) for l in _header_lines(plan))


def target_repos(plan):
    """Raw paths the header names, one per `Репозиторий:` / `Repository:` line, in order."""
    out = []
    for line in _header_lines(plan):
        m = TARGET_LINE.match(line)
        if not m:
            continue
        rest = m.group(1).strip()
        if rest.startswith("`"):
            end = rest.find("`", 1)
            token = rest[1:end] if end > 0 else ""
        else:
            token = re.split(r"[\s(]", rest, maxsplit=1)[0].rstrip(",;")
        if token and TARGET_PATH.match(token) and token not in out:
            out.append(token)
        elif token and not TARGET_PATH.match(token) and token.strip(",;"):
            out.append(token)   # accept_repo refuses it with a reason (relative path)
    return out


def _git_common(path):
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_OPTIONAL_LOCKS="0")
    r = subprocess.run(["git", "-c", "core.fsmonitor=", "-C", path, "rev-parse", "--git-common-dir"],
                       capture_output=True, text=True, timeout=5, env=env)
    out = r.stdout.strip()
    if r.returncode != 0 or not out:
        return None
    return os.path.realpath(out if os.path.isabs(out) else os.path.join(path, out))


def expand_target(raw, home):
    """`~` / `~/…` against the given home (not the process HOME); `~user` → None."""
    if raw == "~" or raw.startswith("~/"):
        return os.path.abspath(os.path.join(home, raw[2:]))
    if raw.startswith("~"):
        return None
    return os.path.abspath(raw)


def accept_repo(raw, home):
    """→ (common dir, "") for a target the mark may go to, else (None, reason)."""
    if not home:
        return None, "HOME is not set — no target is accepted"
    if not TARGET_PATH.match(raw or ""):
        return None, "relative path — write an absolute path or ~/…"
    home_r = os.path.realpath(home)
    p = expand_target(raw, home)
    if p is None:
        return None, "~user paths are not supported — write ~/… or an absolute path"
    if os.path.commonpath([p, home_r]) != home_r:
        return None, "outside HOME (" + home_r + ")"
    if not os.path.isdir(p):
        return None, "does not exist or is not a directory"
    if os.path.realpath(p) != p:
        return None, "the path goes through a symlink — name the real directory"
    g = os.path.join(p, ".git")
    if not os.path.lexists(g):
        return None, "not a git repository"
    if os.path.islink(g) or not os.path.isdir(g):
        return None, "not the main working tree (a worktree or a gitdir: file) — name the main tree"
    common = _git_common(p)
    if common is None:
        return None, "not a git repository"
    if common != os.path.realpath(g):
        return None, "not the main working tree — name the main tree"
    if not os.path.isfile(os.path.join(common, "monitorex-hooks", "plan-gate.sh")):
        return None, "the git-guards kit is not installed there (no monitorex-hooks/plan-gate.sh)"
    return common, ""


def write_mark(common, name, body):
    """Atomic write of <common>/monitorex-locks/plan-approved/<name>; refuses symlinked dirs."""
    common = os.path.realpath(common)
    locks = os.path.join(common, "monitorex-locks")
    d = os.path.join(locks, "plan-approved")
    for x in (locks, d):
        if os.path.islink(x):
            raise OSError("symlink " + x)
    os.makedirs(d, exist_ok=True)
    if os.path.realpath(d) != d:
        raise OSError("symlink in " + d)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(body)
        os.replace(tmp, os.path.join(d, name))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


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
        sid = _CTRL.sub(" ", str(p.get("session_id") or ""))
        body = "ts=%d\nsha256=%s\nsession=%s\nplan=%s\ncritic=%s\nsource=%s\n" % (
            int(time.time()), hashlib.sha256(plan.encode("utf-8")).hexdigest(), sid, name, kind,
            _CTRL.sub(" ", proj))
        notes = []
        written = set()
        session_top = None
        # 1. The session's project, as before (silently skipped when it is not a repository).
        try:
            if proj and os.path.isdir(proj):
                common = _git_common(proj)
                if common:
                    write_mark(common, name, body)
                    written.add(common)
                    session_top = os.path.dirname(common)
        except Exception:
            pass
        # 2. The repositories the plan's header names.
        targets = target_repos(plan)
        if targets:
            if header_hidden(plan):
                notes.append("Marks for the repositories named in the plan were NOT written: the plan header "
                             "contains text the approval window may not show (<!--, <details>, a code fence or control characters).")
            else:
                home = os.environ.get("HOME") or ""
                deadline = time.monotonic() + TARGETS_DEADLINE
                ok_list, refused = [], []
                for i, raw in enumerate(targets):
                    shown = _CTRL.sub(" ", raw)[:200]
                    if i >= MAX_TARGETS:
                        refused.append("%s — more than %d repositories in one plan" % (shown, MAX_TARGETS))
                        continue
                    if time.monotonic() > deadline:
                        refused.append("%s — time is up" % shown)
                        continue
                    try:
                        # The session's own repository named in the header: already written above.
                        exp = expand_target(raw, home) if home else None
                        if exp and session_top and os.path.realpath(exp) == session_top:
                            continue
                        common, why = accept_repo(raw, home)
                        if common is None:
                            refused.append("%s — %s" % (shown, why))
                            continue
                        if common not in written:
                            write_mark(common, name, body)
                            written.add(common)
                        if os.path.dirname(common) not in ok_list:
                            ok_list.append(os.path.dirname(common))
                    except Exception as e:
                        refused.append("%s — could not write (%s: %s)" % (shown, type(e).__name__, _CTRL.sub(" ", str(e))[:200]))
                if ok_list:
                    notes.append("Plan approval mark for " + name + " was also written to: " + ", ".join(ok_list) + ".")
                if refused:
                    notes.append("NOT written for: " + "; ".join(refused) + ".")
        if kind != "section" and written:
            why = ("the user decided to go without it" if kind == "user-decision"
                   else "codex is not installed")
            notes.append("Plan approval mark for " + name + " was written WITHOUT the external critic ("
                         + why + "). If you did not decide that, delete monitorex-locks/plan-approved/"
                         + name + ".")
        if notes:
            print(json.dumps({"systemMessage": "\n".join(notes)}, ensure_ascii=False))
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)


if __name__ == "__main__":
    main()
