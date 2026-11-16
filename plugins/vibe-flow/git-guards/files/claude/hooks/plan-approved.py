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

Native Windows (vibe-flow 1.3.0): a header path may be `C:/…`, `C:\\…` or `/c/…`;
`~` is HOME first (Git Bash sets it; os.path.expanduser reads USERPROFILE there);
"inside HOME" is decided on one drive, never by a commonpath that raises across
drives; a junction counts as a link (os.path.islink misses junctions before 3.12),
and links are found by walking the components, because 8.3 short names (RUNNER~1)
make realpath(p) differ from p with no link anywhere.
"""
from __future__ import annotations

import sys

if sys.version_info < (3, 9):
    # Internal status for the hook wrapper: "too old, try the next interpreter" (K2).
    sys.exit(86)

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import time

WINDOWS = sys.platform == "win32"
# A reparse point whose tag has the "name surrogate" bit redirects to another path:
# symlinks, junctions, WSL symlinks. Cloud placeholders (OneDrive) carry other tags
# and are ordinary directories for this purpose.
REPARSE_TAG_NAME_SURROGATE = 0x20000000
DEFAULT_PATHEXT = ".COM;.EXE;.BAT;.CMD"
_MSYS_DRIVE = re.compile(r"/([A-Za-z])(?=/|$)")

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


def _home():
    """HOME first (Git Bash sets it), then the OS's own idea of the home directory."""
    return os.environ.get("HOME") or os.path.expanduser("~")


def _expanduser(path):
    """os.path.expanduser, except that on Windows `~` is HOME first (K6 home())."""
    if WINDOWS and (path == "~" or path.startswith(("~/", "~\\"))):
        return _home() + path[1:]
    return os.path.expanduser(path)


def _native_drive(path):
    """Windows: the Git Bash form `/c/x` → `C:/x`; anything else unchanged."""
    m = _MSYS_DRIVE.match(path) if WINDOWS else None
    return m.group(1).upper() + ":" + (path[2:] or "/") if m else path


def search_dirs(extra=""):
    """Standard Codex locations — ALWAYS; GG_CODEX_SEARCH_PATHS may only ADD."""
    dirs = [_expanduser(d) for d in STANDARD_DIRS]
    appdata = os.environ.get("APPDATA")
    if appdata:
        dirs.append(os.path.join(appdata, "npm"))      # `npm install -g` on Windows
    for d in (extra or "").split(os.pathsep):
        if d.strip():
            dirs.append(_expanduser(d.strip()))
    return dirs


def _program_files(directory, name):
    """The files that would run `name` from `directory`: on Windows one per PATHEXT
    extension (codex.cmd from npm), elsewhere the bare name."""
    base = os.path.join(directory, name)
    if not WINDOWS:
        return [base]
    exts = [e for e in (os.environ.get("PATHEXT") or DEFAULT_PATHEXT).split(os.pathsep) if e]
    return [base + e for e in exts]


def _runnable(path):
    # Windows has no exec bit (os.access(X_OK) is always true): the PATHEXT
    # extension, already in the name, is what makes a file runnable there.
    return os.path.isfile(path) and (WINDOWS or os.access(path, os.X_OK))


def codex_found(path_env, dirs):
    if shutil.which("codex", path=path_env or ""):
        return True
    return any(_runnable(f) for d in dirs for f in _program_files(d, "codex"))


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
DRIVE_TARGET_PATH = re.compile(r"^[A-Za-z]:[\\/][^\s`]*$")     # Windows only: C:/…, C:\…
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


def _target_like(token):
    """An absolute or `~` path as the header must write it (drive forms on Windows only)."""
    return bool(TARGET_PATH.match(token or "") or (WINDOWS and DRIVE_TARGET_PATH.match(token or "")))


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
        if token and _target_like(token) and token not in out:
            out.append(token)
        elif token and not _target_like(token) and token.strip(",;"):
            out.append(token)   # accept_repo refuses it with a reason (relative path)
    return out


def _git_common(path):
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_OPTIONAL_LOCKS="0")
    r = subprocess.run(["git", "-c", "core.fsmonitor=", "-C", path, "rev-parse", "--git-common-dir"],
                       capture_output=True, encoding="utf-8", errors="surrogateescape",
                       timeout=5, env=env, stdin=subprocess.DEVNULL)
    out = r.stdout.strip()
    if r.returncode != 0 or not out:
        return None
    return os.path.realpath(out if os.path.isabs(out) else os.path.join(path, out))


def expand_target(raw, home):
    """`~` / `~/…` against the given home (not the process HOME); `~user` → None."""
    if raw == "~" or raw.startswith("~/") or (WINDOWS and raw.startswith("~\\")):
        return os.path.abspath(os.path.join(home, raw[2:]))
    if raw.startswith("~"):
        return None
    return os.path.abspath(_native_drive(raw))


def _within(path, root):
    """path is root or below it. Same drive first: commonpath raises across drives."""
    if os.path.splitdrive(path)[0].casefold() != os.path.splitdrive(root)[0].casefold():
        return False
    try:
        common = os.path.commonpath([path, root])
    except ValueError:
        return False
    return os.path.normcase(common) == os.path.normcase(root)


def _is_link(path):
    """A symlink; on Windows also a junction or any other redirecting reparse point."""
    if not WINDOWS:
        return os.path.islink(path)
    try:
        st = os.lstat(path)
    except (OSError, ValueError):
        return False
    if not getattr(st, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
        return False
    return bool(getattr(st, "st_reparse_tag", 0) & REPARSE_TAG_NAME_SURROGATE)


def _has_link(path):
    """Any component of the absolute path is a link (walked, not realpath(p) != p)."""
    cur = os.path.abspath(path)
    while True:
        if _is_link(cur):
            return True
        parent = os.path.dirname(cur)
        if parent == cur:
            return False
        cur = parent


def _resolves_elsewhere(path):
    """realpath leaves this path (a link in it). Both sides normalized, so separators
    and letter case do not count as a difference on Windows."""
    return os.path.normcase(os.path.realpath(path)) != os.path.normcase(os.path.normpath(path))


def accept_repo(raw, home):
    """→ (common dir, "") for a target the mark may go to, else (None, reason)."""
    if not home:
        return None, "HOME is not set — no target is accepted"
    if not _target_like(raw):
        return None, "relative path — write an absolute path or ~/…"
    home_r = os.path.realpath(home)
    p = expand_target(raw, home)
    if p is None:
        return None, "~user paths are not supported — write ~/… or an absolute path"
    # Physical location against the physical HOME: an 8.3 HOME (C:\Users\RUNNER~1)
    # and its long form are the same place. A link is refused below anyway.
    if not _within(os.path.realpath(p), home_r):
        return None, "outside HOME (" + home_r + ")"
    if not os.path.isdir(p):
        return None, "does not exist or is not a directory"
    if _has_link(p):
        return None, "the path goes through a symlink — name the real directory"
    g = os.path.join(p, ".git")
    if not os.path.lexists(g):
        return None, "not a git repository"
    if _is_link(g) or not os.path.isdir(g):
        return None, "not the main working tree (a worktree or a gitdir: file) — name the main tree"
    common = _git_common(p)
    if common is None:
        return None, "not a git repository"
    if os.path.normcase(common) != os.path.normcase(os.path.realpath(g)):
        return None, "not the main working tree — name the main tree"
    if not os.path.isfile(os.path.join(common, "monitorex-hooks", "plan-gate.sh")):
        return None, "the git-guards kit is not installed there (no monitorex-hooks/plan-gate.sh)"
    return common, ""


_PLANS_DIR_RE = re.compile(r"\.?[A-Za-z0-9_][A-Za-z0-9_./-]*")


def project_plans_dir(main_tree):
    """plansDirectory from <main tree>/.claude/settings.json (default .plans); None — unusable
    (absolute, `..`, odd characters). Keep in sync with project_plans_dir in plan-gate.sh."""
    v = ".plans"
    s = os.path.join(main_tree, ".claude", "settings.json")
    if os.path.isfile(s):
        try:
            with open(s, encoding="utf-8") as fh:
                v = json.load(fh).get("plansDirectory", ".plans")
        except Exception:
            v = ".plans"
    if not isinstance(v, str) or not _PLANS_DIR_RE.fullmatch(v) or ".." in v.split("/"):
        return None
    return v.rstrip("/")


def plans_dirs(proj):
    """Plans directories the hook accepts, realpath'd: $GG_PLANS_DIR (if set), <project>/<dir>,
    <main tree>/<dir>, ~/.claude/plans. Keep in sync with plans_dirs in plan-gate.sh."""
    raw = []
    if os.environ.get("GG_PLANS_DIR"):
        raw.append(os.environ["GG_PLANS_DIR"])
    if proj and os.path.isdir(proj):
        common = _git_common(proj)
        main = os.path.dirname(common) if common else proj
        d = project_plans_dir(main)
        if d:
            raw += [os.path.join(proj, d), os.path.join(main, d)]
    raw.append("~/.claude/plans")
    out = []
    for p in raw:
        r = os.path.realpath(_expanduser(p))
        if r not in out:
            out.append(r)
    return out


def _same_dir_in(path, dirs):
    """path is one of dirs (realpath'd on both sides; letter case per the OS)."""
    return os.path.normcase(path) in {os.path.normcase(d) for d in dirs}


def copy_plan(common, name, text, source_dir):
    """A plan for several repositories: put the approved plan text into the target's plans
    directory, so its pre-push finds the file. → a note for the user, or None when all is well.
    Only for a plan from a project's plans directory (one in ~/.claude/plans or $GG_PLANS_DIR
    is found by the target as it is) and only into a target that switched the folder on
    (plansDirectory in its settings.json) — elsewhere a stray, un-ignored folder would appear.
    A different file with the same name is never overwritten."""
    shared = {os.path.realpath(_expanduser("~/.claude/plans"))}
    if os.environ.get("GG_PLANS_DIR"):
        shared.add(os.path.realpath(_expanduser(os.environ["GG_PLANS_DIR"])))
    if _same_dir_in(source_dir, shared):
        return None
    main = os.path.dirname(os.path.realpath(common))
    try:
        with open(os.path.join(main, ".claude", "settings.json"), encoding="utf-8") as fh:
            switched_on = "plansDirectory" in json.load(fh)
    except Exception:
        switched_on = False
    if not switched_on:
        return None
    d = project_plans_dir(main)
    if d is None:
        return "%s: its plansDirectory is unusable — %s not copied there" % (main, name)
    dest_dir = os.path.join(main, d)
    if _is_link(dest_dir):
        return "%s: %s is a symlink — %s not copied there" % (main, d, name)
    os.makedirs(dest_dir, exist_ok=True)
    if _resolves_elsewhere(dest_dir):
        return "%s: %s goes through a symlink — %s not copied there" % (main, d, name)
    dest = os.path.join(dest_dir, name)
    if os.path.lexists(dest):
        try:
            # newline="": the text exactly as written, CRLF included (the mark hashes it).
            with open(dest, encoding="utf-8", newline="") as fh:
                same = not _is_link(dest) and fh.read() == text
        except Exception:
            same = False
        return None if same else "%s: a different %s already in %s — not overwritten" % (main, name, d)
    fd, tmp = tempfile.mkstemp(dir=dest_dir, prefix=".tmp-")
    try:
        # newline="\n": no CRLF translation on Windows, the file is the approved text byte for byte.
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        os.replace(tmp, dest)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return None


def write_mark(common, name, body):
    """Atomic write of <common>/monitorex-locks/plan-approved/<name>; refuses symlinked dirs."""
    common = os.path.realpath(common)
    locks = os.path.join(common, "monitorex-locks")
    d = os.path.join(locks, "plan-approved")
    for x in (locks, d):
        if _is_link(x):
            raise OSError("symlink " + x)
    os.makedirs(d, exist_ok=True)
    if _resolves_elsewhere(d):
        raise OSError("symlink in " + d)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(body)
        os.replace(tmp, os.path.join(d, name))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _say(message):
    """Hook JSON on stdout, ASCII only: Windows encodes stdout as cp1252, where the
    reasons' dashes and Cyrillic used to raise and lose the message (K5)."""
    print(json.dumps(message, ensure_ascii=True))


def _tell(reason):
    _say({"decision": "block",
          "reason": "Plan approval mark NOT written: " + reason + " A [feat] "
          "push citing this plan will be rejected by pre-push until the plan "
          "passes the gate and is approved again."})
    sys.exit(0)


def _read_payload():
    """The hook input as bytes, decoded as UTF-8 (K5); None when it is not a JSON object."""
    try:
        p = json.loads(sys.stdin.buffer.read().decode("utf-8-sig", "surrogateescape"))
    except Exception:
        return None
    return p if isinstance(p, dict) else None


def main():
    p = _read_payload()
    if p is None:
        sys.exit(0)
    if p.get("tool_name") != "ExitPlanMode":
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
        proj = _native_drive(os.environ.get("CLAUDE_PROJECT_DIR") or "")
        plans = plans_dirs(proj)
        real = os.path.realpath(_expanduser(_native_drive(fp)))
        name = os.path.basename(real)
        if (not _same_dir_in(os.path.dirname(real), plans) or ".." in name
                or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._-]*\.md", name)):
            _tell("the plan file is not a <name>.md directly in any of the plans directories: "
                  + ", ".join(plans) + ".")
        found = codex_found(os.environ.get("PATH", ""),
                            search_dirs(os.environ.get("GG_CODEX_SEARCH_PATHS", "")))
        ok, kind, reason = decide(plan, found)
        if not ok:
            _tell("for " + name + ": " + reason)
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
                # HOME only: with HOME unset no target is accepted (fail-closed). On
                # Windows outside Git Bash HOME may be absent; the profile is the home there.
                home = os.environ.get("HOME") or (os.path.expanduser("~") if WINDOWS else "")
                deadline = time.monotonic() + TARGETS_DEADLINE
                ok_list, refused, not_copied = [], [], []
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
                        if exp and session_top and _same_dir_in(os.path.realpath(exp), [session_top]):
                            continue
                        common, why = accept_repo(raw, home)
                        if common is None:
                            refused.append("%s — %s" % (shown, why))
                            continue
                        if common not in written:
                            write_mark(common, name, body)
                            written.add(common)
                        cp_note = copy_plan(common, name, plan, os.path.dirname(real))
                        if cp_note:
                            not_copied.append(_CTRL.sub(" ", cp_note)[:300])
                        if os.path.dirname(common) not in ok_list:
                            ok_list.append(os.path.dirname(common))
                    except Exception as e:
                        refused.append("%s — could not write (%s: %s)" % (shown, type(e).__name__, _CTRL.sub(" ", str(e))[:200]))
                if ok_list:
                    notes.append("Plan approval mark for " + name + " was also written to: " + ", ".join(ok_list) + ".")
                if refused:
                    notes.append("NOT written for: " + "; ".join(refused) + ".")
                if not_copied:
                    notes.append("The plan file was NOT copied for: " + "; ".join(not_copied)
                                 + ". A [feat] push there needs the plan file in its plans directory.")
        if kind != "section" and written:
            why = ("the user decided to go without it" if kind == "user-decision"
                   else "codex is not installed")
            notes.append("Plan approval mark for " + name + " was written WITHOUT the external critic ("
                         + why + "). If you did not decide that, delete monitorex-locks/plan-approved/"
                         + name + ".")
        if notes:
            _say({"systemMessage": "\n".join(notes)})
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)


if __name__ == "__main__":
    main()
