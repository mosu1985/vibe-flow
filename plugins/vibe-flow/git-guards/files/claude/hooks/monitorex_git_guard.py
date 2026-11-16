#!/usr/bin/env python3
"""PreToolUse guard: blocks staging and committing in the shared working tree.

A separate file, not a heredoc inside the shell script: with `python3 - <<EOF`
the heredoc takes over stdin, and the hook's actual input never reaches the script.

Full rationale: monitorex-git-guard.sh next to this file.

Failure posture (vibe-flow 1.3.0):
  - a deny ALWAYS reaches Claude Code: emit_deny() prints ASCII-only JSON, and if
    even that fails (closed stdout, a broken pipe) it writes an ASCII reason to
    stderr and exits 2, Claude Code's block. It never exits 1: exit 1 is a
    "non-blocking error", and the tool call would run;
  - the hook input is read as bytes and decoded as UTF-8 here: Windows decodes
    stdin as cp1252, and Cyrillic bytes used to raise before any check;
  - the Write guard is fail-CLOSED: when gg_paths is missing, raises or cannot
    decide, a path that looks like git's own directory or the guard's state is
    denied (K13). The Bash checks stay fail-open on infrastructure breakage — the
    owner's decision; the installer's self-test proves the guard denies;
  - program names are compared through gg_paths.cmd_name() and the guard's
    regexes are case-insensitive with both separators on EVERY OS: APFS and NTFS
    are case-insensitive, so `GIT add`, `git.exe add` and `.git/MONITOREX-LOCKS`
    are the real thing.
"""
from __future__ import annotations

import sys

if sys.version_info < (3, 9):
    # Internal status for the hook wrapper: "this interpreter is too old, try the
    # next one" (K2). The wrapper never passes it to Claude Code. Nothing is printed
    # before this line, and nothing above uses syntax newer than 3.8.
    sys.exit(86)

import json
import os
import re
import subprocess
from typing import NoReturn

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "scripts", "git-guards"))

GIT_TIMEOUT = 5                      # seconds per git call
EXIT_BLOCK = 2                       # Claude Code: exit 2 = blocking error, stderr goes to the model
DENY_STDERR_PREFIX = b"vibe-flow guard: DENY: "


def emit_deny(reason: str) -> NoReturn:
    """The only way the guard denies (K4): JSON with ensure_ascii=True on stdout,
    exit 0. If anything fails while emitting, an ASCII reason on stderr and exit 2.
    It cannot raise and never exits 1."""
    try:
        out = sys.stdout
        if out is None:              # fd 1 closed at start: print() would silently do nothing
            raise OSError("stdout is closed")
        out.write(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }}, ensure_ascii=True) + "\n")
        out.flush()
    except BaseException:            # noqa: BLE001 — whatever happened, the deny must still land
        try:
            os.write(2, DENY_STDERR_PREFIX + reason.encode("ascii", "backslashreplace") + b"\n")
        except BaseException:        # noqa: BLE001 — nowhere left to report; exit 2 still blocks
            pass
        os._exit(EXIT_BLOCK)
    # os._exit, not sys.exit: the JSON is out, and nothing at interpreter shutdown
    # may turn the exit code into anything but 0.
    os._exit(0)


def allow() -> NoReturn:
    sys.exit(0)


def read_payload() -> dict | None:
    """The hook input: bytes decoded as UTF-8 (K5). Invalid bytes are kept as
    surrogates instead of raising, so a deny stays a deny."""
    try:
        data = sys.stdin.buffer.read()
        parsed = json.loads(data.decode("utf-8-sig", "surrogateescape"))
    except Exception:                # noqa: BLE001 — broken input: nothing to check (fail-open)
        return None
    return parsed if isinstance(parsed, dict) else None


payload = read_payload()
if payload is None:
    allow()

try:
    import gg_paths as gp
except Exception:                    # noqa: BLE001 — K13: the Write guard falls back, Bash fails open
    gp = None


def git_run(where: str, *args: str) -> tuple[int, str]:
    """(exit code, stripped stdout) of `git -C where …`. Raises on a timeout or a
    missing git: the caller decides what doubt means there."""
    proc = subprocess.run(("git", "-C", where) + args, capture_output=True, encoding="utf-8",
                          errors="surrogateescape", timeout=GIT_TIMEOUT, stdin=subprocess.DEVNULL)
    return proc.returncode, proc.stdout.strip()


def native(path: str) -> str | None:
    """The path in this OS's native form, `~` expanded (HOME first); None — cannot tell."""
    if not gp.WINDOWS:
        path = os.path.expanduser(path)          # to_native is identity on POSIX
    return gp.to_native(path)


def absolute_from(where: str, path: str) -> str | None:
    """A path git printed (absolute, or relative to `where`) as an absolute native path."""
    p = gp.to_native(path)
    if p is None:
        return None
    return p if gp.is_abs(p) else os.path.join(where, p)


def _fold(path: str) -> str:
    """For prefix comparison: casefolded (APFS and NTFS are case-insensitive), one
    separator on Windows, no trailing separator."""
    if gp.WINDOWS:
        path = path.replace("\\", "/")
    return path.rstrip("/").casefold()


def inside(path: str, root: str) -> bool:
    """path is root or below it. Case-folded: APFS is case-insensitive by
    default, and `.GIT/monitorex-locks` is the same directory as `.git/…`."""
    p, r = _fold(path), _fold(root)
    return p == r or p.startswith(r + "/")


def _component(part: str) -> str:
    """A path component as Windows resolves it: no alternate data stream suffix
    (`.git::$INDEX_ALLOCATION`), no trailing dots or spaces (`.git.`), casefolded."""
    return part.split(":", 1)[0].rstrip(". ").casefold()


def has_git_component(path: str) -> bool:
    return any(_component(part) == ".git" for part in re.split(r"[\\/]", path))


# Windows 8.3 aliases (MONITO~1, GIT~1, GIT-CO~1.SH, RUNNER~1): a short name opens
# the same file as the long one and slips past every text check.
SHORT_NAME = re.compile(r"[^.\\/~\s]{1,7}~\d{1,7}(?:\.[^.\\/\s]{1,3})?")


def short_name_left(path: str) -> bool:
    return any(SHORT_NAME.fullmatch(part) for part in re.split(r"[\\/]", path))


# ── Write / Edit / MultiEdit / NotebookEdit: nothing inside git's own directories ──
# The bypass marks (CONFIRM, allow-push, allow-delete), the release-gate verdict,
# the plan approval marks, claims and the installed hooks all live in
# $GIT_COMMON_DIR. Bash writes there are caught below; the Write tool used to walk
# straight past: one Write of `monitorex-locks/release-gate/<tree>` with
# `verdict=pass` and the push went out without review.
#   - the path is file_path, or notebook_path for NotebookEdit; neither → deny;
#   - relative paths resolve from cwd, then realpath (a symlink into .git counts;
#     on Windows realpath also turns 8.3 aliases into long names);
#   - deny if any component is `.git` (also `.git.` and `.git::$INDEX_ALLOCATION`),
#     or the path is inside the common dir of the project — computed from
#     $CLAUDE_PROJECT_DIR, not from cwd: after `cd /private/tmp` a cwd-based check
#     would find no repository and let the absolute path through (M5). Every
#     worktree's gitdir lives under the common dir ($COMMON/worktrees/<name>), so
#     it is covered by the same check;
#   - any failure to decide → deny when the path looks like git's directory or the
#     guard's state (this check is fail-CLOSED, unlike the rest; K13).
WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
GIT_DIR_DENY = """🔴 Writing inside git's own directory (`.git`, the common dir of this project) is forbidden to the model.

That is where the guard keeps its state: bypass marks (CONFIRM, allow-push,
allow-delete), the release-gate verdict, plan approval marks, issue claims and
the installed hooks. Each of them is a human's or a reviewer's decision.

- a verdict: run the release-gate agent;
- a bypass: ask the user to run the script via `!`;
- plan approval: the user approves the plan in Plan Mode (ExitPlanMode);
- stale hooks: bash scripts/install-git-guards.sh.

If you really need to change something there (e.g. .git/info/exclude), ask the user."""
NO_PATH_DENY = ("🔴 The guard cannot see which file this tool writes (no file_path / "
                "notebook_path), so it refuses.")
UNDECIDED_DENY = ("🔴 The guard could not check this write, and the path looks like git's own "
                  "directory or the guard's state, so it refuses. Ask the user if the write is needed.")


SERVICE_LIKE = re.compile(r"monitorex-|[\\/]worktrees[\\/]", re.I)


def looks_like_guard_state(path: str) -> bool:
    """The K13 fallback, without gg_paths: a `.git` component or the guard's names."""
    return bool(SERVICE_LIKE.search(path)) or has_git_component(path)


def _write_lands_in_git(path: str) -> bool | None:
    base = native(payload.get("cwd") or os.getcwd())
    target = native(path)
    if base is None or target is None:
        return None
    absp = os.path.normpath(target if gp.is_abs(target) else os.path.join(base, target))
    real = os.path.realpath(absp)
    if has_git_component(absp) or has_git_component(real):
        return True
    if gp.WINDOWS and short_name_left(real):
        return None                  # an 8.3 alias realpath did not resolve: where it points is unknown
    # No project, or the project is not a repository (git answered normally with a
    # non-zero code) → there is no common dir to protect: allow. The `.git`
    # component check above still applies.
    proj = os.environ.get("CLAUDE_PROJECT_DIR") or ""
    if not proj:
        return False
    proj = native(proj)
    if proj is None:
        return None
    if not os.path.isdir(proj):
        return False
    rc, common = git_run(proj, "rev-parse", "--git-common-dir")
    if rc != 0 or not common:
        return False
    common = absolute_from(proj, common)
    if common is None:
        return None
    common = os.path.realpath(common)
    return inside(real, common) or inside(absp, common)


def write_verdict(path: str) -> bool | None:
    """True — the write lands in git's own directories, False — it does not,
    None — cannot tell (gg_paths missing, raising or undecided; git timed out)."""
    if gp is None:
        return None
    try:
        return _write_lands_in_git(path)
    except Exception:                # noqa: BLE001 — a doubt, decided by the K13 fallback
        return None


def write_guard() -> NoReturn:
    ti = payload.get("tool_input")
    ti = ti if isinstance(ti, dict) else {}
    path = ti.get("file_path") or ti.get("notebook_path")
    if not isinstance(path, str) or not path.strip():
        emit_deny(NO_PATH_DENY)
    verdict = write_verdict(path)
    if verdict is True:
        emit_deny(GIT_DIR_DENY)
    if verdict is None and looks_like_guard_state(path):
        emit_deny(UNDECIDED_DENY)
    allow()


if payload.get("tool_name") in WRITE_TOOLS:
    write_guard()

if payload.get("tool_name") != "Bash":
    allow()

_tool_input = payload.get("tool_input")
cmd = _tool_input.get("command") if isinstance(_tool_input, dict) else None
cwd = payload.get("cwd")
if not isinstance(cwd, str) or not cwd:
    cwd = os.getcwd()
if not isinstance(cmd, str) or not cmd.strip():
    allow()
# The Bash checks need both helpers; without them they fail open (the installer's
# self-test fails loudly instead).
if gp is None:
    allow()

try:
    from shell_segments import (parse, strip_env_prefix, safe_split,
                                first_word, basename_matches)
    detail = parse(cmd)["segments_detail"]
    segments = [s["segment"] for s in detail]
except Exception:                    # noqa: BLE001 — fail-open, as documented above
    allow()

GUARDED = ("add", "commit")
# git flags that take the next word as their value.
TAKES_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}


def guarded_target(seg: str):
    """(hit 'git add'/'git commit', [-C values in order], whether
    --git-dir/--work-tree is present) — if the segment IS that command, else None.

    🔴 The first version looked for the word "git" anywhere in the segment, and the
    hook rejected `echo "git commit"`, where those words are just text. It blocked
    its own diagnostics, and then the attempt to fix itself. A false rejection of
    legitimate work is worse than a miss: people rip out the whole guard over it.

    So `git` must be IN COMMAND POSITION (after an optional `VAR=1` prefix), and
    flags with values are skipped so that `git -C dir add` is recognized as `add`
    rather than as the path `dir`.

    The `-C` values are returned so the decision is made by the tree where git
    ACTUALLY runs, not by the session cwd (25.10.2026): `git -C <worktree> add`
    from the main working tree is work in your own worktree, not in the shared
    index, and it used to be falsely rejected.
    """
    body = strip_env_prefix(seg)
    head = first_word(body)
    if not head or not basename_matches(head, "git"):
        return None
    words = safe_split(body)[1:]
    c_dirs, explicit = [], False
    i = 0
    while i < len(words):
        w = words[i]
        if w in TAKES_VALUE:
            if w == "-C" and i + 1 < len(words):
                c_dirs.append(words[i + 1])
            if w in ("--git-dir", "--work-tree"):
                explicit = True
            i += 2
            continue
        if w.startswith("--git-dir=") or w.startswith("--work-tree="):
            explicit = True
        if w.startswith("-"):
            i += 1
            continue
        return (f"git {w}", c_dirs, explicit) if w in GUARDED else None
    return None


# ── Where a segment may run (paths are resolved only at decision points) ─────
def here() -> str | None:
    """The session cwd in native form; None — cannot tell."""
    return gp.to_native(cwd)


def resolve(base: str, path: str) -> str | None:
    """`path` seen from `base`, absolute and native; None — cannot tell."""
    target = native(path)
    if target is None:
        return None
    if gp.is_abs(target):
        return os.path.normpath(target)
    nbase = gp.to_native(base)
    if nbase is None:
        return None
    return os.path.normpath(os.path.join(nbase, target))


def target_dirs(candidates, c_dirs):
    """All directories where this segment's git may run.
    None in the list — the directory cannot be resolved (cd $VAR etc.)."""
    out = []
    for cand in candidates or [{"cd_dir": None, "cd_ambiguous": False}]:
        if cand.get("cd_ambiguous"):
            out.append(None)
            continue
        where = resolve(cwd, cand["cd_dir"]) if cand.get("cd_dir") else here()
        for c in c_dirs:            # `-C a -C b` — relative paths stack
            where = resolve(where, c) if where is not None else None
        out.append(where)
    return out


class SegmentDirs:
    """The directories one segment may run in, worked out on the first call only:
    on Windows that may start cygpath, which the guard does at decision points only."""

    def __init__(self, candidates) -> None:
        self._candidates = candidates
        self._dirs: list[str | None] | None = None

    def __call__(self) -> list[str | None]:
        if self._dirs is None:
            self._dirs = target_dirs(self._candidates, [])
        return self._dirs


SESSION_DIRS = SegmentDirs(None)


def long_path(word: str, base: str | None) -> str | None:
    """The word as a path from `base` with every existing component in its long
    form (Windows realpath resolves 8.3 aliases); None — cannot tell."""
    if base is None:
        return None
    p = resolve(base, word)
    if p is None:
        return None
    try:
        return os.path.realpath(p)
    except (OSError, ValueError):
        return None


def program_name(word: str, dirs: SegmentDirs) -> str | None:
    """cmd_name of the program a command word runs. On Windows an 8.3 alias
    (`scripts/GIT-CO~1.SH`) is resolved to its long name from every possible cwd;
    None — it cannot be, and the caller denies."""
    name = gp.cmd_name(word)
    if not (gp.WINDOWS and SHORT_NAME.fullmatch(name)):
        return name
    longs = set()
    for base in dirs():
        p = long_path(word, base)
        if p is None or short_name_left(p):
            return None
        longs.add(gp.cmd_name(p))
    return longs.pop() if len(longs) == 1 else None


# Deliberate-bypass scripts. A HUMAN sets the mark — that is why they ask
# "yes/no". But the question does not stop an agent: `echo yes | git-allow-delete.sh add`
# goes through silently. So the modes that SET a mark are forbidden to the model in any
# tree (marks live in the shared $GIT_COMMON_DIR). Reading and clearing are allowed.
# The hook does not get in a human's way: commands typed via `!` bypass PreToolUse.
# Names are lower case: they are compared with gg_paths.cmd_name() (case-insensitive,
# `.exe` stripped). The MODES stay case-sensitive: the scripts match them exactly,
# so `STATUS` is not `status` to them, and an unknown word is not a safe mode here.
OWNER_MARK_SAFE_MODES = {
    "git-confirm.sh": {"status", "clear"},
    "git-allow-push.sh": {"list", "clear"},
    "git-allow-delete.sh": {"list", "clear"},
    # pass is allowed here but checked separately below: release-gate agent only
    "release-gate.sh": {"scope", "status", "pass"},
}
SHELLS = {"bash", "sh", "zsh"}
# Mark-script flags that take the next word as their value.
MARK_VALUE_FLAGS = {"--report", "--head"}
MARK_VALUE_SAFE = re.compile(r"[A-Za-z0-9._/@:+%=-]+")
# Wrappers followed by the real command: `env X=1 cmd`, `nohup cmd`.
# Without stripping them, `nohup scripts/git-confirm.sh commit` slipped past the check.
# `source`/`.` run the script in the current shell, `nice`/`sudo`/`caffeinate`/
# `arch`/`stdbuf` run it as a child: `source scripts/release-gate.sh pass` and
# `nice scripts/git-confirm.sh feat` used to go through in one command (L6).
WRAPPERS = {"env", "command", "nohup", "time", "exec", "builtin", "xargs",
            "source", ".", "nice", "sudo", "caffeinate", "arch", "stdbuf"}
# Wrapper flags that take the next word: `env -u VAR cmd`, `exec -a name cmd`.
WRAPPER_VALUE_FLAGS = {"-u", "--unset", "-C", "--chdir", "-S", "-a", "-I", "-n", "-L", "-P"}
# Per-wrapper sets where they differ (stdbuf's -i takes a value, env's -i does not).
WRAPPER_VALUE_FLAGS_BY = {
    "nice": {"-n", "--adjustment"},
    "sudo": {"-u", "--user", "-g", "--group", "-h", "--host", "-p", "--prompt",
             "-C", "--close-from", "-U", "--other-user", "-r", "--role",
             "-t", "--type", "-D", "--chdir", "-T", "--command-timeout"},
    "caffeinate": {"-t", "-w"},
    "arch": {"-arch", "-e"},
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "source": set(), ".": set(),
}


def command_words(seg: str) -> list[str]:
    """Segment words starting from the real command — without VAR=, shells and wrappers."""
    words = safe_split(strip_env_prefix(seg))
    while words:
        head = gp.cmd_name(words[0])
        if head not in SHELLS and head not in WRAPPERS:
            break
        words = words[1:]
        while words and (words[0].startswith("-")
                         or (head in WRAPPERS and "=" in words[0])):
            takes = head in WRAPPERS and words[0] in WRAPPER_VALUE_FLAGS_BY.get(head, WRAPPER_VALUE_FLAGS)
            words = words[2:] if takes else words[1:]
    return words


def is_owner_mark(seg: str, dirs: SegmentDirs) -> str | None:
    """Return the script name if the segment sets an owner mark."""
    words = command_words(seg)
    if not words:
        return None
    name = program_name(words[0], dirs)
    if name is None:
        return f"{gp.cmd_name(words[0])} (an 8.3 short name the guard cannot resolve)"
    if name not in OWNER_MARK_SAFE_MODES:
        return None
    # Flag values (`--report r.md`) are not a mode: otherwise `r.md` in the mode
    # position caused a false rejection of a legitimate `status`.
    args, rest = [], words[1:]
    while rest:
        # Skip the value only if the shell will not expand it into several
        # words: bash turns `--head $X scope` or `--head {a,override} scope`
        # into override mode. An allowlist, not a list of dangerous forms.
        if (name == "release-gate.sh" and rest[0] in MARK_VALUE_FLAGS
                and len(rest) > 1 and MARK_VALUE_SAFE.fullmatch(rest[1])):
            rest = rest[2:]
            continue
        if not rest[0].startswith("-"):
            args.append(rest[0])
        rest = rest[1:]
    if not args:
        return None                  # with no arguments the script only displays
    return None if args[0] in OWNER_MARK_SAFE_MODES[name] else name


mark = next((m for d in detail
             if (m := is_owner_mark(d["segment"], SegmentDirs(d.get("cwd_candidates"))))), None)
if mark:
    emit_deny(f"""🔴 `{mark}` sets a guard bypass mark — that is a human decision, not an agent's.

Show the user exactly what will be allowed and why, and ask them to run the
command themselves — in the Claude Code input line via `!` with the --yes flag
(there is no way to answer the prompt there), or in a regular terminal without the flag.
The hook will not see it: commands run via `!` bypass PreToolUse.

The agent may view and clear marks: list / status / clear.""")


# Only the reviewer itself sets the release-gate verdict. Otherwise the main session,
# which the gate is stopping from pushing, would "approve" its own code in one line.
# Inside a subagent the hook receives agent_type — that is how we tell them apart.
# Agent name: own file in .claude/agents → `release-gate`; from the vibe-flow
# plugin → `vibe-flow:release-gate` (plugin agents get a prefix).
GATE_AGENTS = {"release-gate", "vibe-flow:release-gate"}
# The verdict directory, any letter case, either separator.
GATE_PATH = r"monitorex-locks[\\/]+release-gate"
GATE_PATH_RE = re.compile(GATE_PATH, re.I)
# Commands that write to their file arguments. echo/printf are not here: they
# write to stdout, and writing that to a file is a redirect, which is caught below.
WRITERS = {"cp", "mv", "tee", "touch", "ln", "install", "rsync", "dd"}
# A redirect specifically INTO the verdict directory (`>`, `>>`, `>|`). Matching any `>`
# (2>/dev/null, 2>&1) caused false rejections on reads — and false rejections
# get the whole guard ripped out.
GATE_REDIRECT = re.compile(r">[>|]?\s*['\"]?[^\s;|&'\"]*" + GATE_PATH, re.I)


def gate_violation(seg: str, dirs: SegmentDirs) -> str | None:
    words = command_words(seg)
    if not words:
        return None
    name = program_name(words[0], dirs)
    if name == "release-gate.sh":
        # Look for the mode among ALL words, not just the first argument: the script
        # takes the word after --report/--head as a value, so `--report scope pass …`
        # is pass mode to it, while "first word without -" would see a harmless scope.
        rest = set(words[1:])
        # Bypass is a human decision, even for the reviewer itself.
        if "override" in rest:
            return "pass"
        if "pass" in rest and payload.get("agent_type") not in GATE_AGENTS:
            return "pass"
    # Writing to the verdict directory bypassing the script — whatever the first word,
    # even `release-gate.sh status > …/<tree>`. Reading (ls, cat, grep) is allowed.
    if GATE_REDIRECT.search(seg):
        return "write"
    # Any argument containing the directory path — even as a source (`cp gate/x /tmp`).
    # Telling source from destination was tried (28.10): a trailing `2>/dev/null`
    # became "the last argument", and `cp /tmp/v gate/<tree> 2>/dev/null`
    # got through. A false rejection when copying a verdict out is cheaper.
    if name in WRITERS and any(GATE_PATH_RE.search(w) for w in words[1:]):
        return "write"
    return None


gate = next((g for d in detail
             if (g := gate_violation(d["segment"], SegmentDirs(d.get("cwd_candidates"))))), None)
if gate:
    emit_deny("""🔴 Only the `release-gate` agent (an Opus reviewer) sets the release-gate verdict.

The main session cannot approve its own code: that is the whole point of the gate.
Run the release-gate agent on the current tree. If it returns findings,
fix them, commit, and run it again.

Bypassing review is a human decision: ask the user to run
`! scripts/release-gate.sh override --yes`.""")

# ── Writes into the guard's state, whatever the command ──────────────────────
# Not only the release-gate verdict: CONFIRM (target=feat lets a feature through
# the plan gate), allow-push, allow-delete, plan-approved/, claims/ and the
# installed hooks in monitorex-hooks/ (rolling a hook back, `chmod -x`) are all
# decisions the model must not make.
#
# 🔴 An ALLOWLIST, not a list of writers (HIGH-1′). Every closed list of "commands
# that write" had holes: `sort -o`, `curl -o`, `wget -O`, `tar -C`, `vim -es`,
# `git -C <dir> archive -o`… So: a segment that names these directories in its
# words, or runs inside them (cd/pushd/cwd), is rejected unless its command is a
# plain reader (READERS). The readers' own output redirections are still checked.
# Scripts of the kit run by name (wt-new.sh, git-lock.sh, release-gate.sh status…)
# carry no such path in their words and are not affected.
# `monitorex-$X` too: a name built from a variable is still the guard's directory.
# Case-insensitive with either separator: `.git/MONITOREX-LOCKS` is the same
# directory on APFS and NTFS; on Windows `.git.` and `.git:<stream>` are `.git`.
BARRIER = re.compile(r"monitorex-(?:locks|hooks)\b|monitorex-[*?\[{$]", re.I)
# git's remote-tracking refs on disk: rewriting them by hand forges origin/<protected>.
FS_REFS = re.compile(r"\.git[. ]*(?::[^\\/\s]*)?[\\/]+(?:refs[\\/]+remotes|packed-refs)", re.I)
# Ref NAMES in redirect targets (refs/remotes/… written by path relative to .git).
REMOTE_REFS = re.compile(r"(?:^|[\\/])refs[\\/]+remotes(?:[\\/]|$)|packed-refs\b", re.I)
READERS = {"ls", "cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "rg",
           "wc", "stat", "file", "readlink", "realpath", "du", "test", "[", "find",
           "echo", "printf", "diff", "cmp", "shasum", "sha256sum", "md5", "md5sum",
           "sed", "true", ":"}
FIND_ACTIONS = re.compile(r"^-(?:delete|exec|execdir|ok|okdir|fprint\w*|fls)$")
SED_WRITE = re.compile(r"(?:^|[;{}\s])[wWe](?:\s|$)")
# Builtins, matched exactly: `CD x` does not change the directory (shell_segments
# does not follow it either).
CD_WORDS = {"cd", "pushd", "popd"}
SAFE_SINKS = {"/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"}
DRIVE_SLASH = re.compile(r"[A-Za-z]:/")


def read_word(seg: str, j: int) -> int:
    """End index of the shell word starting at j (quotes and $(…) kept whole)."""
    k, depth, wq, n = j, 0, None, len(seg)
    while k < n:
        ch = seg[k]
        if wq:
            if ch == wq:
                wq = None
        elif ch in "'\"":
            wq = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and ch in " \t;|&<>":
            break
        k += 1
    return k


def redirect_targets(seg: str) -> list[str]:
    """Targets of output redirections (`>`, `>>`, `>|`, `&>`, `2>`), quotes kept.

    Quote-aware: `echo "a > b"` has no redirection. The target is one shell word,
    `$(…)` included. `>&2` is an fd duplication, not a file."""
    out, i, n, q = [], 0, len(seg), None
    while i < n:
        c = seg[i]
        if q:
            if c == q:
                q = None
            elif c == "\\" and q == '"':
                i += 1
            i += 1
            continue
        if c in "'\"":
            q = c
        elif c == "\\":
            i += 1
        elif c == ">":
            j = i + 1
            if j < n and seg[j] in ">|":
                j += 1
            if j < n and seg[j] == "&":
                i = j + 1
                continue
            while j < n and seg[j] in " \t":
                j += 1
            k = read_word(seg, j)
            out.append(seg[j:k])
            i = k
            continue
        i += 1
    return out


ASSIGN_HEAD = re.compile(r"\s*(?:(?:export|declare|typeset|local|readonly)\s+(?:-\w+\s+)*)?"
                         r"([A-Za-z_][A-Za-z0-9_]*)=")
ASSIGN_ONE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")


def split_assignments(seg: str) -> tuple[list[tuple[str, str]], str]:
    """Leading `NAME=value` words (and export/declare …) → ([(name, value)], rest).
    Values are read as whole shell words: shlex would tear `$(…)` apart."""
    out, rest = [], seg.lstrip()
    m = re.match(r"(?:export|declare|typeset|local|readonly)\s+(?:-\w+\s+)*", rest)
    if m:
        rest = rest[m.end():]
    while True:
        m = ASSIGN_ONE.match(rest)
        if not m:
            break
        k = read_word(rest, m.end())
        out.append((m.group(0)[:-1], rest[m.end():k]))
        rest = rest[k:].lstrip()
    return out, rest


def guarded(text: str) -> bool:
    return bool(BARRIER.search(text) or FS_REFS.search(text))


def unquote(word: str) -> str:
    return word.replace('"', "").replace("'", "")


def tilde_kind(word: str) -> str:
    """'abs' — /…, C:/… (Windows), ~, ~/…, ~user/…; 'prev' — ~- (OLDPWD, unknown);
    'rel' — the rest (~+ and ~N are relative to the current directory stack).
    `C:\\…` stays 'rel': unquoted, bash eats the backslash, and the safe side of a
    doubt here is "relative"."""
    w = unquote(word)
    if w.startswith("/") or (gp.WINDOWS and DRIVE_SLASH.match(w)):
        return "abs"
    if w.startswith("~-"):
        return "prev"
    if w.startswith("~+") or re.match(r"~[0-9]", w):
        return "rel"
    if w.startswith("~"):
        return "abs"
    return "rel"


def short_alias_guarded(word: str, dirs: SegmentDirs) -> bool:
    """Windows: a word with an 8.3 component (`.git/MONITO~1/CONFIRM`) is resolved
    to its long name from every possible cwd. True if that names the guard's dirs,
    cannot be worked out, or an alias inside a `.git` directory stays unresolved."""
    if not gp.WINDOWS:
        return False
    w = unquote(word)
    if not short_name_left(w):
        return False
    if "$" in w or "`" in w:
        return True
    for base in dirs():
        p = long_path(w, base)
        if p is None or guarded(p) or (short_name_left(p) and has_git_component(p)):
            return True
    return False


def is_reader(words: list[str]) -> bool:
    name = gp.cmd_name(words[0])
    if name not in READERS:
        return False
    if name == "find":
        return not any(FIND_ACTIONS.match(w) for w in words[1:])
    if name == "sed":
        return not any(w == "--in-place" or w.startswith("--in-place=")
                       or (w.startswith("-") and not w.startswith("--") and "i" in w[1:])
                       or SED_WRITE.search(w) for w in words[1:])
    return True


def refs_var(text: str, names: set[str]) -> bool:
    return any(re.search(r"\$\{?" + re.escape(n) + r"\b", text) for n in names)


def dir_guarded(cd_dir: str) -> bool:
    """A cwd candidate (relative to the session cwd) inside the guard's dirs."""
    return guarded(cd_dir) or short_alias_guarded(cd_dir, SESSION_DIRS)


def barrier_violation() -> bool:
    taint: set[str] = set()
    ever_in = guarded(cwd)          # was the command ever inside the guard's dirs
    sticky = guarded(cwd)           # an unresolvable cd into them: everything after runs there
    for d in detail:
        seg = d["segment"]
        dirs = SegmentDirs(d.get("cwd_candidates"))
        assigns, body = split_assignments(seg)
        for name, value in assigns:
            if guarded(value) or refs_var(value, taint):
                taint.add(name)
        in_dir = sticky or any(dir_guarded(c.get("cd_dir") or "")
                               for c in d.get("cwd_candidates") or [])
        ever_in = ever_in or in_dir
        # 1. Output redirections of ANY command.
        for t in redirect_targets(body):
            if unquote(t) in SAFE_SINKS:
                continue
            kind = tilde_kind(t)
            if (guarded(t) or REMOTE_REFS.search(t) or refs_var(t, taint)
                    or short_alias_guarded(t, dirs)
                    or (in_dir and kind == "rel") or (ever_in and kind == "prev")):
                return True
        if not body.strip():
            continue
        words = command_words(body)
        if not words:
            continue
        if words[0] in CD_WORDS:
            arg = next((w for w in words[1:] if not w.startswith("-")), "")
            if guarded(body) or refs_var(body, taint) or short_alias_guarded(arg, dirs):
                if "$" in arg or "`" in arg:
                    sticky = True
                ever_in = True
            continue
        # 2. Naming the guard's dirs (or running inside them) — readers only.
        if is_reader(words):
            continue
        if (in_dir or guarded(body) or refs_var(body, taint)
                or any(short_alias_guarded(w, dirs) for w in words[1:])):
            return True
    return False


if barrier_violation():
    emit_deny("""🔴 Writing into monitorex-locks/ or monitorex-hooks/ is forbidden to the model.

These directories hold the guard's state: bypass marks (CONFIRM, allow-push,
allow-delete), the release-gate verdict, plan approval marks, issue claims, and
the installed hooks. Each entry is a human's or a reviewer's decision.

- a bypass mark: show the user what it allows and ask them to run the script via `!`;
- a stuck lock: scripts/git-lock.sh release;
- stale hooks: bash scripts/install-git-guards.sh (installs from origin);
- reading (ls, cat, grep) is allowed.""")


# `git push --no-verify` turns off pre-push entirely: typecheck, the parallel-session
# barriers and release-gate all at once. A human may (the hook does not fire for `!`),
# the model may not. Same bypass: swapping core.hooksPath via `-c`, `--config-env`,
# GIT_CONFIG_* variables, or `git config` beforehand.
# The direct forms are closed; indirect ones (include.path, --remove-section core,
# hand-editing .git/config) cannot be caught by PreToolUse — they show up in review.
HOOKS_PATH = re.compile(r"hooks?path", re.I)
# Case-insensitive: Windows environment variables are, and git.exe reads them so.
GIT_CONFIG_ENV = re.compile(r"GIT_CONFIG_(COUNT|KEY_\w*|VALUE_\w*|PARAMETERS|GLOBAL|SYSTEM)=", re.I)
CONFIG_WRITE_FLAGS = {"--unset", "--unset-all", "--add", "--replace-all", "--edit", "-e"}
CONFIG_READ_FLAGS = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l"}
CONFIG_VALUE_FLAGS = {"-f", "--file", "--blob", "--type", "--default", "--comment"}
ENV_SETTERS = {"export", "declare", "typeset", "env"}


def git_config_env(seg_text: str) -> bool:
    """GIT_CONFIG_* set as environment: via an `X=… git` prefix or export/env."""
    toks = safe_split(seg_text)
    head = []
    for t in toks:
        if gp.cmd_name(t) == "git":
            break
        head.append(t)
    if any(GIT_CONFIG_ENV.match(t) for t in head):
        return True
    return (bool(toks) and gp.cmd_name(toks[0]) in ENV_SETTERS
            and any(GIT_CONFIG_ENV.match(t) for t in toks[1:]))


def push_bypass(seg: str) -> bool:
    words = command_words(seg)
    if not words or gp.cmd_name(words[0]) != "git":
        return False
    rest, conf = words[1:], []     # conf holds only -c/--config-env values, not the -C path
    while rest and rest[0].startswith("-"):
        w = rest[0]
        if w in ("-c", "--config-env"):
            conf.extend(rest[1:2])
        elif w.startswith("-c") or w.startswith("--config-env="):
            conf.append(w)
        if w in TAKES_VALUE or w == "--config-env":
            rest = rest[2:]
        else:
            rest = rest[1:]
    if not rest:
        return False
    sub, args = rest[0], rest[1:]
    if sub == "config":
        # Reading (`git config --get core.hooksPath`, `git config get …`) is allowed.
        if not any(HOOKS_PATH.search(a) for a in args):
            return False
        pos, i = [], 0
        while i < len(args):
            if args[i] in CONFIG_VALUE_FLAGS:
                i += 2
                continue
            if not args[i].startswith("-"):
                pos.append(args[i])
            i += 1
        if CONFIG_READ_FLAGS & set(args) or pos[:1] in (["get"], ["list"]):
            return False
        return (len(pos) >= 2 or bool(CONFIG_WRITE_FLAGS & set(args))
                or pos[:1] in (["set"], ["unset"]))
    if sub != "push":
        return False
    if any(HOOKS_PATH.search(w) for w in conf):
        return True
    if git_config_env(seg) or any(git_config_env(s) for s in segments):
        return True
    # git accepts abbreviated long options: `--no-verif` = `--no-verify`.
    return any(len(w) >= 6 and "--no-verify".startswith(w) for w in args)


if any(push_bypass(s) for s in segments):
    emit_deny("""🔴 `git push` bypassing pre-push (--no-verify / swapped core.hooksPath) is forbidden to the model.

It turns off type checking, the parallel-session barriers and release-gate at once —
the code would ship unchecked. Let the hook run; a rejection means there is something
to fix (or the release-gate agent to run).

To delete a remote branch use `gh api -X DELETE …/git/refs/heads/<branch>`.
A deliberate bypass is a human decision: ask the user to push themselves
via `! git push --no-verify …` and explain exactly what gets skipped.""")


# ── What `origin/<protected>` means must not be rewritten in one command ─────
# pre-push, the installer and the hook check below all trust refs/remotes/origin/*.
# `git -c url.<local>.insteadOf=<origin> fetch` fills them with local commits
# (C1-r2); set-head / symbolic-ref / update-ref / a `:refs/remotes/…` refspec move
# them directly. Reading (`git symbolic-ref refs/remotes/origin/HEAD`) is allowed.
# Ref paths are compared casefolded: loose refs are files, and on APFS/NTFS
# `REFS/REMOTES/…` is the same file.
REDIRECT_CONF = re.compile(r"(?:url|remote)\.", re.I)
FETCHERS = {"fetch", "pull", "push", "remote", "ls-remote", "clone", "submodule"}
REMOTE_REF_PREFIXES = ("refs/remotes/", "remotes/")


def git_parts(seg: str):
    """(config values from -c/--config-env, subcommand, args) for a git segment."""
    words = command_words(seg)
    if not words or gp.cmd_name(words[0]) != "git":
        return None
    rest, conf = words[1:], []
    while rest and rest[0].startswith("-"):
        w = rest[0]
        if w in ("-c", "--config-env"):
            conf.extend(rest[1:2])
        elif w.startswith("--config-env="):
            conf.append(w[len("--config-env="):])
        elif w.startswith("-c") and w != "-C":
            conf.append(w[2:])
        rest = rest[2:] if (w in TAKES_VALUE or w == "--config-env") else rest[1:]
    if not rest:
        return conf, "", []
    return conf, rest[0], rest[1:]


REMOTE_REWRITE = {"set-head", "set-url", "rename", "remove", "rm", "set-branches"}
CONFIG_SECTION_FLAGS = {"--rename-section", "--remove-section"}


def config_written_keys(args: list[str]) -> list[str]:
    """Keys a `git config …` call writes (empty for reads)."""
    pos, i = [], 0
    while i < len(args):
        if args[i] in CONFIG_VALUE_FLAGS:
            i += 2
            continue
        if not args[i].startswith("-"):
            pos.append(args[i])
        i += 1
    flags = set(args)
    if CONFIG_SECTION_FLAGS & flags:
        return pos
    if CONFIG_READ_FLAGS & flags or pos[:1] in (["get"], ["list"]):
        return []
    if pos[:1] in (["set"], ["unset"], ["rename-section"], ["remove-section"]):
        return pos[1:2]
    if CONFIG_WRITE_FLAGS & flags or len(pos) >= 2:
        return pos[:1]
    return []


def remote_ref_tamper(seg: str) -> bool:
    parts = git_parts(seg)
    if not parts:
        return False
    conf, sub, args = parts
    if any(REDIRECT_CONF.match(c) for c in conf):
        return True
    if sub in FETCHERS and git_config_env(seg):
        return True
    pos = [a for a in args if not a.startswith("-")]
    # set-url/rename/remove repoint or drop origin; the next fetch then fills
    # refs/remotes/origin/* from anywhere (LOW-5). `git remote add` stays allowed.
    if sub == "remote" and pos[:1] and pos[0] in REMOTE_REWRITE:
        # `set-head origin --auto` asks the remote itself — that is the honest value.
        auto = pos[0] == "set-head" and ("-a" in args or "--auto" in args) and len(pos) <= 2
        if not auto:
            return True
    if sub == "config" and any(REDIRECT_CONF.match(k) for k in config_written_keys(args)):
        return True
    if sub == "symbolic-ref":
        deleting = "-d" in args or "--delete" in args
        if pos and pos[0].casefold().startswith("refs/remotes/") and (deleting or len(pos) >= 2):
            return True
    if sub == "update-ref" and (any("refs/remotes/" in a.casefold() for a in args) or "--stdin" in args):
        return True
    # git completes a refspec destination itself: `HEAD:remotes/origin/main` is
    # refs/remotes/origin/main (MEDIUM-1).
    if sub in ("fetch", "pull"):
        for a in args:
            if ":" in a and a.rsplit(":", 1)[1].lstrip("+").casefold().startswith(REMOTE_REF_PREFIXES):
                return True
    return False


ALIAS_CONF = re.compile(r"alias\.", re.I)
GIT_WORD = re.compile(r"(?<![\w.-])git(?![\w.-])", re.I)


def alias_or_eval(seg: str) -> bool:
    """`git -c alias.p='push --no-verify' p` runs a command the guard never sees as
    such; `eval "git push --no-verify"` hides it in a string. Both → deny."""
    words = command_words(seg)
    if words and gp.cmd_name(words[0]) == "eval":
        return bool(GIT_WORD.search(seg))
    parts = git_parts(seg)
    if not parts:
        return False
    conf, sub, args = parts
    if any(ALIAS_CONF.match(c) for c in conf):
        return True
    return sub == "config" and any(ALIAS_CONF.match(k) for k in config_written_keys(args))


# `CMD="git push --no-verify"; eval $CMD` / `$CMD`: the command lives in a variable.
NO_VERIFY_VALUE = re.compile(r"\bpush\b.*--no-verif", re.S)


def no_verify_assignment(seg: str) -> bool:
    assigns, _ = split_assignments(seg)
    return any(NO_VERIFY_VALUE.search(v) for _, v in assigns)


if any(alias_or_eval(s) or no_verify_assignment(s) for s in segments):
    emit_deny("""🔴 git aliases defined on the fly (`git -c alias.*=…`, `git config alias.*`), `eval` of a git command and a `push --no-verify` stored in a variable are forbidden to the model.

The guard decides by the command it sees; an alias or an eval'd string hides the
real one (e.g. `push --no-verify`). Run the git command directly.""")


if any(remote_ref_tamper(s) for s in segments):
    emit_deny("""🔴 Rewriting what `origin/<protected branch>` points to is forbidden to the model.

pre-push, install-git-guards.sh and the hook check all trust refs/remotes/origin/*:
the plan gate's policy, the release-gate base and the installed hooks come from
there. Forbidden: `git -c url.*/remote.* …`, `--config-env` with those keys,
GIT_CONFIG_* for fetch/push, `git remote set-head`, `git symbolic-ref
refs/remotes/… <target>`, `git update-ref refs/remotes/…`, `git fetch … :refs/remotes/…`.

A plain `git fetch origin` is fine. Anything else — ask the user.""")


def git(where: str, *args: str) -> str:
    return git_run(where, *args)[1]


def is_linked_worktree(where: str) -> bool | None:
    """True — a linked worktree (own index), None — not a repository (git will fail
    by itself, nothing to block), False — the shared tree.

    "Linked" only on positive evidence (K14): <abs gitdir>/commondir exists AND the
    git dir is not the common dir (same_path False). Any doubt — a timeout, an empty
    answer, a path that cannot be compared — is the shared tree, which denies."""
    if not os.path.isdir(where):
        return False                 # no such directory — err on the safe side
    try:
        rc, gd = git_run(where, "rev-parse", "--git-dir")
        if rc != 0:
            return None
        rc, common = git_run(where, "rev-parse", "--git-common-dir")
        if rc != 0 or not gd or not common:
            return False
        # Resolved paths, not strings: in a subdirectory of the main tree --git-dir
        # comes back absolute and --git-common-dir relative (`../../.git`), and the raw
        # comparison took the shared tree for a linked worktree (--path-format=absolute
        # needs git 2.31+).
        gd_abs, common_abs = absolute_from(where, gd), absolute_from(where, common)
        if gd_abs is None or common_abs is None:
            return False
        if not os.path.isfile(os.path.join(gd_abs, "commondir")):
            return False
        return gp.same_path(gd_abs, common_abs) is False
    except Exception:                # noqa: BLE001 — a doubt is the shared tree (K14)
        return False


# ── Before `git push`: the installed hooks are the ones on origin (H4) ───────
# Old trees keep old copies of install-git-guards.sh, and `npm install` → `prepare`
# runs them: the shared monitorex-hooks/ silently went back to a pre-push without
# the newer barriers, for every tree. A rolled-back hook cannot check itself, so
# the check lives here: each hook of the installed set must exist, be executable
# and match origin/<protected>'s githooks/<name> byte for byte; core.hooksPath must
# point at that set. A hook not on origin yet (bootstrap) is skipped.
HOOK_SET = ("pre-commit", "pre-push", "plan-gate.sh", "prepare-commit-msg")
BLOB_FOUND, BLOB_ABSENT, BLOB_ERROR = 0, 1, 2


def git_blob(where: str, rev: str, path: str) -> tuple[int, bytes]:
    """A file at a revision, the K7 way: `ls-tree` + `cat-file blob`, never a
    `<rev>:<path>` argument, and --no-replace-objects, so `git replace` cannot swap
    the blob. → (BLOB_FOUND, bytes) | (BLOB_ABSENT, b"") | (BLOB_ERROR, b"")."""
    base = ("git", "-C", where, "--no-replace-objects")
    try:
        listed = subprocess.run(base + ("ls-tree", "-z", "--full-tree", rev, "--", path),
                                capture_output=True, timeout=GIT_TIMEOUT, stdin=subprocess.DEVNULL)
        if listed.returncode != 0:
            return BLOB_ERROR, b""
        entry = listed.stdout.split(b"\0", 1)[0]
        if not entry:
            return BLOB_ABSENT, b""
        meta = entry.split(b"\t", 1)[0].split()
        if len(meta) != 3 or meta[1] != b"blob":
            return BLOB_ERROR, b""
        blob = subprocess.run(base + ("cat-file", "blob", meta[2].decode("ascii")),
                              capture_output=True, timeout=GIT_TIMEOUT, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError, ValueError):
        return BLOB_ERROR, b""
    return (BLOB_FOUND, blob.stdout) if blob.returncode == 0 else (BLOB_ERROR, b"")


def protected_ref(where: str) -> str | None:
    """refs/remotes/origin/HEAD → origin/main → origin/master; None without origin."""
    if git_run(where, "remote", "get-url", "origin")[0] != 0:
        return None
    head = git(where, "symbolic-ref", "-q", "refs/remotes/origin/HEAD")
    for b in ([head[len("refs/remotes/origin/"):]] if head else []) + ["main", "master"]:
        ref = f"refs/remotes/origin/{b}"
        if git_run(where, "rev-parse", "-q", "--verify", ref + "^{commit}")[0] == 0:
            return ref
    return None


def hooks_problems(where: str) -> tuple[list[str], str]:
    import hashlib
    rc, common = git_run(where, "rev-parse", "--git-common-dir")
    if rc != 0 or not common:
        return [], ""                    # not a repository — git push fails by itself
    common = absolute_from(where, common)
    ref = protected_ref(where) if common else None
    if not ref:
        return [], ""
    dest = os.path.realpath(os.path.join(common, "monitorex-hooks"))
    probs, on_origin = [], False
    for name in HOOK_SET:
        state, blob = git_blob(where, ref, f"githooks/{name}")
        if state != BLOB_FOUND:
            continue                     # not on origin yet; a read error: pre-push still runs
        on_origin = True
        inst = os.path.join(dest, name)
        if not os.path.isfile(inst):
            probs.append(f"{name}: not installed")
        elif not os.access(inst, os.X_OK):
            probs.append(f"{name}: not executable")
        else:
            with open(inst, "rb") as fh:
                if hashlib.sha256(fh.read()).digest() != hashlib.sha256(blob).digest():
                    probs.append(f"{name}: differs from {ref[len('refs/remotes/'):]}")
    if on_origin:
        rc, hp = git_run(where, "rev-parse", "--git-path", "hooks")
        hp = absolute_from(where, hp) if rc == 0 and hp else None
        if hp is None or gp.same_path(hp, dest) is not True:
            probs.append(f"core.hooksPath is not {dest}")
    return probs, ref[len("refs/remotes/"):]


def is_push(seg: str) -> bool:
    parts = git_parts(seg)
    return bool(parts) and parts[1] == "push"


for d in detail:
    if not is_push(d["segment"]):
        continue
    words = safe_split(strip_env_prefix(d["segment"]))[1:]
    c_dirs = [words[i + 1] for i, w in enumerate(words[:-1]) if w == "-C"]
    for where in target_dirs(d.get("cwd_candidates"), c_dirs):
        where = where or native(os.environ.get("CLAUDE_PROJECT_DIR") or cwd)
        try:
            probs, oref = hooks_problems(where) if where and os.path.isdir(where) else ([], "")
        except Exception:                # noqa: BLE001 — infrastructure trouble: pre-push still runs
            probs, oref = [], ""
        if probs:
            emit_deny("🔴 The installed git hooks do not match origin — they are stale or were replaced:\n\n"
                      + "\n".join(f"   - {p}" for p in probs)
                      + "\n\nA rolled-back pre-push silently drops the newer barriers for every tree "
                      "(this happens when an old tree runs `npm install` → `prepare`).\n"
                      f"First merge {oref} into this tree (or `scripts/wt-new.sh --resume <branch> --merge-main`), "
                      "so its scripts are current, then reinstall the hooks from origin and push again:\n"
                      "  bash scripts/install-git-guards.sh")


hit = None
for d in detail:
    g = guarded_target(d["segment"])
    if not g:
        continue
    name, c_dirs, explicit = g
    if explicit:                     # --git-dir/--work-tree: do not guess
        hit = name
        break
    for where in target_dirs(d.get("cwd_candidates"), c_dirs):
        state = None if where is None else is_linked_worktree(where)
        # Allowed only if EVERY possible directory is a linked worktree
        # (or not a repository at all). An unknown directory → shared tree.
        if where is None or state is False:
            hit = name
            break
    if hit:
        break

if not hit:
    allow()

emit_deny(f"""🔴 `{hit}` is forbidden in the shared working tree.

The git index here is SHARED by all parallel sessions: staged files end up in
someone else's commit within seconds (it already happened on 2026-08-06 — 7 files
of a security fix went into a commit about filter layout).

Commit like this:
  scripts/git-safe-commit.sh --message-file <file> -- <paths>

It builds the commit in an isolated index and moves the branch atomically.
Need partial staging? Work in a separate worktree:
  scripts/wt-new.sh <name>

One-off deliberate bypass (by a human, with confirmation):
  scripts/git-confirm.sh commit""")
