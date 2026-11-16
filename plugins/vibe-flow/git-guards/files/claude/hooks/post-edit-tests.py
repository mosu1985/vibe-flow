#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""post-edit-tests.py — the body of the PostToolUse hook post-edit-tests.sh.

Input: the hook JSON on stdin (tool_name, tool_input.file_path, cwd).
Output: nothing when tests pass, there are none, or anything is off; on a red run
{"decision":"block","reason":"<tail of the output>"} on stdout.

🔴 SECURITY (H2). The hook runs a COMMAND, outside PreToolUse and permissions, so:
  * it only works for files inside a worktree of the project the session was started
    in ($CLAUDE_PROJECT_DIR). Membership is decided by path prefix among
    `git -C $CLAUDE_PROJECT_DIR worktree list` — git is never run in the file's own
    directory (a foreign repository's .git/config could run code via core.fsmonitor);
  * the command and every GG_POST_EDIT_* key come from the protected branch on
    origin (.gitguards.conf read with `ls-tree` + `cat-file`, --no-replace-objects),
    parsed as text — never sourced. A branch cannot swap the command by editing its
    own config. Without an origin remote, the MAIN working tree's config is used;
    with one, an absent or unreadable policy means no run (never the tree copy);
  * paths are passed as separate arguments ("$@"), never pasted into the string;
    no control characters; a leading "-" gets "./" so it cannot become an option.

LOAD. One run per repository at a time (lock $COMMON/monitorex-locks/post-edit-run,
busy → the path waits in this tree's queue and the hook returns at once), a pause
per tree (GG_POST_EDIT_DEBOUNCE, 20 s) and per repository (GG_POST_EDIT_REPO_GAP,
10 s), a ceiling GG_POST_EDIT_MAX (90 s) after which the whole process group is
killed — test runners fork workers, and killing only the top process leaves them
running as orphans.

WINDOWS (vibe-flow 1.3.0). A liveness check is never os.kill(pid, 0): every signal
there is TerminateProcess, and the check killed the lock's owner. Windows has no
SIGHUP/SIGKILL and no process groups by session: the run gets its own process group
and is stopped as a tree with `taskkill /T /F`. Queue paths are relative with
forward slashes, so `src/*.ts` globs match there too. POSIX behaviour is unchanged.

FAIL-OPEN: any error → exit 0 without output.
"""
from __future__ import annotations

import sys

if sys.version_info < (3, 9):
    # Internal status for the hook wrapper: "too old, try the next interpreter" (K2).
    sys.exit(86)

import fnmatch
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
import unicodedata

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "scripts", "git-guards"))
try:
    import gg_paths as gp
except Exception:                    # noqa: BLE001 — fail-open: no helper, no run
    gp = None

WINDOWS = sys.platform == "win32"
SIGHUP = getattr(signal, "SIGHUP", None)        # absent on Windows
SIGKILL = getattr(signal, "SIGKILL", None)      # absent on Windows

DEFAULT_GLOBS = "*.ts *.tsx *.mts *.cts *.js *.jsx *.mjs *.cjs *.vue *.svelte"
POLICY_KEYS = {
    "GG_POST_EDIT_TESTS", "GG_POST_EDIT_GLOBS", "GG_POST_EDIT_CMD",
    "GG_POST_EDIT_DEBOUNCE", "GG_POST_EDIT_REPO_GAP", "GG_POST_EDIT_MAX",
    "GG_TEST_CMD", "GG_PROTECTED",
}
# 🔴 The ceiling must end BEFORE Claude Code kills the hook (registration timeout,
# settings-merge.py): otherwise the hook dies first, killpg never runs and the test
# workers stay alive. After the ceiling: TERM + 3 s, KILL + 5 s, then cleanup.
HOOK_TIMEOUT = 120
MAX_CEILING = HOOK_TIMEOUT - 15
TERM_GRACE = 3
KILL_GRACE = 5
TASKKILL_TIMEOUT = 10
TAIL_LINES = 40
MAX_QUEUE = 50
NO_TESTS = ("No test files found", "No tests found")
CMD_NOT_FOUND = re.compile(r": command not found\s*$")
BLOB_FOUND, BLOB_ABSENT, BLOB_ERROR = 0, 1, 2

# Windows process API (liveness without killing)
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
STILL_ACTIVE = 259
ERROR_ACCESS_DENIED = 5
MAX_PID = 0xFFFFFFFF

# ── secret masking: whatever a test prints ends up in the session transcript ──
SECRET_PATTERNS = [re.compile(p) for p in (
    r"(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{10,}",
    r"(?<![A-Za-z0-9_-])sk_[A-Za-z0-9_]{20,}",         # ElevenLabs sk_…, Stripe sk_live_/sk_test_
    r"(?<![A-Za-z0-9_-])rk_(?:live|test)_[A-Za-z0-9]{10,}",   # Stripe restricted keys
    r"(?<![A-Za-z0-9])\d{8,}:AA[A-Za-z0-9_-]{30,}",     # Telegram bot tokens
    r"(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{16,}",
    r"(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{20,}",
    r"(?<![A-Za-z0-9])xox[abposr]-[A-Za-z0-9-]{8,}",
    r"(?<![A-Za-z0-9])AKIA[0-9A-Z]{16}",
    r"(?<![A-Za-z0-9])AIza[0-9A-Za-z_-]{35}",
    r"(?<![A-Za-z0-9])eyJ[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]+){0,2}",
    r"(?<![A-Za-z0-9])sb_secret_[A-Za-z0-9_-]+",
    r"(?<![A-Za-z0-9])sbp_[A-Za-z0-9]+",
    r"(?<![A-Za-z0-9])enc:[^\s\"'`]+",
)]
ANSI = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-Z\\-_]")


def clean_text(s):
    """ANSI escapes, control (Cc, except \\n \\t) and format (Cf) characters out; secrets masked."""
    s = ANSI.sub("", s)
    s = "".join(c for c in s if c in "\n\t" or unicodedata.category(c) not in ("Cc", "Cf"))
    for p in SECRET_PATTERNS:
        s = p.sub("***", s)
    return s


def git(args, cwd, timeout=10):
    env = {k: v for k, v in os.environ.items()
           if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR")}
    r = subprocess.run(["git", "-C", cwd] + args, capture_output=True, encoding="utf-8",
                       errors="surrogateescape", timeout=timeout, env=env, stdin=subprocess.DEVNULL)
    return r.returncode, r.stdout


def read_blob(cwd, rev, path):
    """A file at a revision the K7 way: `ls-tree` + `cat-file blob`, never a
    `<rev>:<path>` argument, --no-replace-objects (`git replace` cannot swap it).
    → (BLOB_FOUND, text) | (BLOB_ABSENT, "") | (BLOB_ERROR, "")."""
    rc, listed = git(["--no-replace-objects", "ls-tree", "-z", "--full-tree", rev, "--", path], cwd)
    if rc != 0:
        return BLOB_ERROR, ""
    entry = listed.split("\0", 1)[0]
    if not entry:
        return BLOB_ABSENT, ""
    meta = entry.split("\t", 1)[0].split()
    if len(meta) != 3 or meta[1] != "blob":
        return BLOB_ERROR, ""
    rc, text = git(["--no-replace-objects", "cat-file", "blob", meta[2]], cwd)
    return (BLOB_FOUND, text) if rc == 0 else (BLOB_ERROR, "")


def parse_conf(text):
    """^GG_[A-Z_]+= lines, whitelist only, one pair of quotes removed. Last one wins."""
    out = {}
    for line in text.splitlines():
        m = re.match(r"^(GG_[A-Z_]+)=(.*)$", line)
        if not m or m.group(1) not in POLICY_KEYS:
            continue
        v = m.group(2).strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        out[m.group(1)] = v
    return out


def has_ref(proj, ref):
    return git(["rev-parse", "--verify", "-q", ref + "^{commit}"], proj)[0] == 0


def read_policy(proj, common):
    """The kit-wide rule: origin/HEAD → origin/main → origin/master; no origin → main tree."""
    if git(["remote", "get-url", "origin"], proj)[0] == 0:
        branch = None
        rc, out = git(["symbolic-ref", "-q", "refs/remotes/origin/HEAD"], proj)
        out = out.strip()
        if rc == 0 and out.startswith("refs/remotes/origin/") and len(out) > len("refs/remotes/origin/"):
            branch = out[len("refs/remotes/origin/"):]
        else:
            for b in ("main", "master"):
                if has_ref(proj, "refs/remotes/origin/" + b):
                    branch = b
                    break
        if branch:
            state, text = read_blob(proj, "refs/remotes/origin/%s" % branch, ".gitguards.conf")
            # Absent or unreadable on origin → no policy, no run: never the tree copy
            # while origin exists (H2, K8).
            return parse_conf(text) if state == BLOB_FOUND else {}
    path = os.path.join(os.path.dirname(common), ".gitguards.conf")
    try:
        with open(path, encoding="utf-8") as fh:
            return parse_conf(fh.read())
    except OSError:
        return {}


def int_key(pol, key, default, lo, hi):
    try:
        v = int(pol.get(key, ""))
    except ValueError:
        return default
    return v if lo <= v <= hi else default


def bad_chars(s):
    return any(unicodedata.category(c) in ("Cc", "Cf") for c in s)


def matches(rel, globs):
    return any(fnmatch.fnmatchcase(rel, g) for g in globs)


def age(path):
    try:
        return time.time() - os.stat(path).st_mtime
    except OSError:
        return None


def touch(path):
    with open(path, "a"):
        pass
    os.utime(path, None)


def _pid_alive_windows(pid):
    """OpenProcess + GetExitCodeProcess == STILL_ACTIVE. Never os.kill(pid, 0):
    on Windows every signal is TerminateProcess. Cannot tell → alive (the lock
    then ages out by stale_after instead of being stolen)."""
    if pid <= 0 or pid > MAX_PID:
        return False
    try:
        import ctypes
        from ctypes import wintypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.OpenProcess.restype = wintypes.HANDLE
        kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        kernel32.GetExitCodeProcess.restype = wintypes.BOOL
        kernel32.GetExitCodeProcess.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
        kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
        handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not handle:
            # Access denied: the process exists and belongs to someone else.
            return ctypes.get_last_error() == ERROR_ACCESS_DENIED
        try:
            code = wintypes.DWORD()
            if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
                return True
            return code.value == STILL_ACTIVE
        finally:
            kernel32.CloseHandle(handle)
    except Exception:                # noqa: BLE001 — cannot tell → alive
        return True


def pid_alive(pid):
    if WINDOWS:
        return _pid_alive_windows(pid)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def read_pid(owner_file):
    try:
        with open(owner_file, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("pid="):
                    return int(line[4:].strip())
    except (OSError, ValueError):
        pass
    return None


class Lock(object):
    """mkdir lock with an owner file; a dead owner's lock is removed (moved away
    first and re-checked, so two hooks cannot both remove it and both run)."""

    def __init__(self, path, stale_after):
        self.path = path
        self.stale_after = stale_after
        self.held = False

    def _take(self):
        try:
            os.mkdir(self.path)
        except FileExistsError:
            return False
        with open(os.path.join(self.path, "owner"), "w", encoding="utf-8", newline="\n") as fh:
            fh.write("pid=%d\ntime=%d\n" % (os.getpid(), int(time.time())))
        self.held = True
        return True

    def acquire(self):
        if self._take():
            return True
        pid = read_pid(os.path.join(self.path, "owner"))
        a = age(self.path)
        if a is None:
            return self._take()
        stale = (pid is None and a > 10) or (pid is not None and not pid_alive(pid)) \
            or a > self.stale_after
        if not stale:
            return False
        dead = "%s.dead.%d" % (self.path, os.getpid())
        try:
            os.rename(self.path, dead)
        except OSError:
            return False
        if read_pid(os.path.join(dead, "owner")) != pid:
            try:
                os.rename(dead, self.path)
            except OSError:
                pass
            return False
        shutil.rmtree(dead, ignore_errors=True)
        return self._take()

    def release(self):
        if self.held and read_pid(os.path.join(self.path, "owner")) == os.getpid():
            shutil.rmtree(self.path, ignore_errors=True)
        self.held = False


def take_queue(queue):
    work = "%s.%d" % (queue, os.getpid())
    try:
        os.rename(queue, work)
    except OSError:
        return []
    try:
        with open(work, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
    finally:
        try:
            os.unlink(work)
        except OSError:
            pass
    seen, out = set(), []
    for ln in lines:
        if ln and ln not in seen:
            seen.add(ln)
            out.append(ln)
    return out


def kill_tree(proc, sig):
    """Signal the run's whole process group; on Windows kill its process tree
    (taskkill /T /F — there is no gentler stage for console programs)."""
    if WINDOWS:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True,
                       timeout=TASKKILL_TIMEOUT, stdin=subprocess.DEVNULL)
        return
    os.killpg(proc.pid, sig)


def stop_tree(proc):
    """After the ceiling: TERM + grace, KILL + grace (Windows: one taskkill + grace)."""
    stages = ((None, KILL_GRACE),) if WINDOWS else ((signal.SIGTERM, TERM_GRACE), (SIGKILL, KILL_GRACE))
    for sig, grace in stages:
        try:
            kill_tree(proc, sig)
        except (OSError, subprocess.SubprocessError):
            pass
        try:
            proc.wait(timeout=grace)
            return
        except subprocess.TimeoutExpired:
            continue


def run_options():
    """The run gets its own process group, so the whole tree can be stopped."""
    if WINDOWS:
        return {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
    return {"start_new_session": True}


def read_payload():
    """The hook input as bytes, decoded as UTF-8 (K5); None unless a JSON object."""
    try:
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8-sig", "surrogateescape"))
    except Exception:                # noqa: BLE001 — broken input: nothing to do
        return None
    return payload if isinstance(payload, dict) else None


def edited_file(payload):
    """realpath of the edited file, or None (relative paths need an absolute cwd)."""
    ti = payload.get("tool_input")
    fp = ti.get("file_path") if isinstance(ti, dict) else None
    if not isinstance(fp, str) or not fp or bad_chars(fp):
        return None
    fp = gp.to_native(fp)
    if fp is None:
        return None
    if not gp.is_abs(fp):
        cwd = payload.get("cwd")
        cwd = gp.to_native(cwd) if isinstance(cwd, str) else None
        if not cwd or not gp.is_abs(cwd):
            return None
        fp = os.path.join(cwd, fp)
    real = os.path.realpath(fp)
    if not os.path.isfile(real) or bad_chars(real):
        return None
    return real


def owning_tree(proj, real):
    """The deepest worktree of the project holding `real` (no git in foreign dirs)."""
    rc, out = git(["worktree", "list", "--porcelain"], proj)
    if rc != 0:
        return None
    tree = None
    for line in out.splitlines():
        if not line.startswith("worktree "):
            continue
        t = gp.to_native(line[len("worktree "):])
        if not t:
            continue
        t = os.path.realpath(t)
        rel = gp.posix_rel(real, t)
        if os.path.isdir(t) and rel and rel != ".":
            if tree is None or len(t) > len(tree):
                tree = t
    return tree


def main():
    if gp is None:
        return
    payload = read_payload()
    if payload is None or payload.get("tool_name") not in ("Edit", "Write", "MultiEdit"):
        return
    proj = gp.to_native(os.environ.get("CLAUDE_PROJECT_DIR") or "")
    if not proj or not os.path.isdir(proj):
        return
    proj = os.path.realpath(proj)
    real = edited_file(payload)
    if real is None:
        return

    # ── which worktree of THIS project holds the file (no git in foreign dirs) ──
    tree = owning_tree(proj, real)
    if tree is None:
        return

    rc, common = git(["rev-parse", "--git-common-dir"], proj)
    common = gp.to_native(common.strip()) if rc == 0 else None
    if not common:
        return
    common = os.path.realpath(common if gp.is_abs(common) else os.path.join(proj, common))

    pol = read_policy(proj, common)
    if pol.get("GG_POST_EDIT_TESTS") != "1":
        return
    cmd = pol.get("GG_POST_EDIT_CMD") or pol.get("GG_TEST_CMD") or ""
    if not cmd.strip() or bad_chars(cmd):
        return
    globs = (pol.get("GG_POST_EDIT_GLOBS") or DEFAULT_GLOBS).split()
    debounce = int_key(pol, "GG_POST_EDIT_DEBOUNCE", 20, 0, 3600)
    repo_gap = int_key(pol, "GG_POST_EDIT_REPO_GAP", 10, 0, 3600)
    ceiling = min(int_key(pol, "GG_POST_EDIT_MAX", 90, 1, 3600), MAX_CEILING)

    rel = gp.posix_rel(real, tree)
    if not rel or not matches(rel, globs):
        return

    # ── queue (per tree), pauses, lock (per repository) ──
    rc, gitdir = git(["rev-parse", "--absolute-git-dir"], tree)
    gitdir = gp.to_native(gitdir.strip()) if rc == 0 else None
    if not gitdir:
        return
    state = os.path.join(gitdir, "post-edit-tests")
    os.makedirs(state, exist_ok=True)
    queue = os.path.join(state, "pending")
    with open(queue, "a", encoding="utf-8", newline="\n") as fh:
        fh.write(rel + "\n")

    tree_stamp = os.path.join(state, "last-run")
    locks = os.path.join(common, "monitorex-locks")
    os.makedirs(locks, exist_ok=True)
    repo_stamp = os.path.join(locks, "post-edit-last")
    a = age(tree_stamp)
    if a is not None and a < debounce:
        return
    a = age(repo_stamp)
    if a is not None and a < repo_gap:
        return

    lock = Lock(os.path.join(locks, "post-edit-run"), ceiling + 60)
    if not lock.acquire():
        return                                      # busy: the path waits in the queue
    proc = None
    ran = False

    def on_term(signum, frame):
        if proc is not None and proc.poll() is None:
            try:
                kill_tree(proc, SIGKILL)
            except (OSError, subprocess.SubprocessError):
                pass
        lock.release()
        os._exit(0)

    try:
        # Inside the try: whatever fails here, the lock is released below.
        signal.signal(signal.SIGTERM, on_term)
        if SIGHUP is not None:
            signal.signal(SIGHUP, on_term)
        paths = []
        for q in take_queue(queue)[-MAX_QUEUE:]:
            if bad_chars(q):
                continue
            r = os.path.realpath(os.path.join(tree, q))
            q = gp.posix_rel(r, tree)
            if not q or q == "." or not os.path.isfile(r):
                continue
            if bad_chars(q) or not matches(q, globs):
                continue
            arg = "./" + q if q.startswith("-") else q
            if arg not in paths:
                paths.append(arg)
        if not paths:
            return

        ran = True
        env = dict(os.environ, NO_COLOR="1", FORCE_COLOR="0")
        with tempfile.TemporaryFile() as log:
            proc = subprocess.Popen(
                ["sh", "-c", cmd + ' "$@"', "gg-post-edit"] + paths,
                cwd=tree, env=env, stdin=subprocess.DEVNULL, stdout=log,
                stderr=subprocess.STDOUT, **run_options())
            timed_out = False
            try:
                rc = proc.wait(timeout=ceiling)
            except subprocess.TimeoutExpired:
                timed_out = True
                stop_tree(proc)
                rc = proc.returncode
            log.seek(0)
            output = log.read().decode("utf-8", errors="replace")
    finally:
        lock.release()
        if ran:
            for stamp in (tree_stamp, repo_stamp):
                try:
                    touch(stamp)
                except OSError:
                    pass

    # A run cut off by the ceiling is not a verdict about the code: no block.
    if timed_out or rc == 0 or any(s in output for s in NO_TESTS):
        return
    # The runner itself is missing or not executable (a tree whose package install
    # failed, a command not on PATH) — infrastructure, not a red test: silent, like
    # every other infrastructure failure. The shell says so in its first lines.
    if rc in (126, 127) or any(CMD_NOT_FOUND.search(ln) for ln in output.split("\n")[:5]):
        return
    lines = clean_text(output).rstrip().split("\n")
    tail = "\n".join(ln[:500] for ln in lines[-TAIL_LINES:])
    reason = clean_text(
        "Tests related to the edited file(s) failed (exit %s): %s\n"
        "Last %d lines of output:\n%s\n\n"
        "Fix the code (or the test, if the behavior change is intended) before going on."
        % (rc, " ".join(paths), TAIL_LINES, tail))
    sys.stdout.write(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=True) + "\n")


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    sys.exit(0)
