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
    origin (`git show origin/<protected>:.gitguards.conf`), parsed as text — never
    sourced. A branch cannot swap the command by editing its own config. Without an
    origin remote, the MAIN working tree's config is used;
  * paths are passed as separate arguments ("$@"), never pasted into the string;
    no control characters; a leading "-" gets "./" so it cannot become an option.

LOAD. One run per repository at a time (lock $COMMON/monitorex-locks/post-edit-run,
busy → the path waits in this tree's queue and the hook returns at once), a pause
per tree (GG_POST_EDIT_DEBOUNCE, 20 s) and per repository (GG_POST_EDIT_REPO_GAP,
10 s), a ceiling GG_POST_EDIT_MAX (90 s) after which the whole process group is
killed — test runners fork workers, and killing only the top process leaves them
running as orphans.

FAIL-OPEN: any error → exit 0 without output.
"""
import fnmatch
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unicodedata

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
TAIL_LINES = 40
MAX_QUEUE = 50
NO_TESTS = ("No test files found", "No tests found")
CMD_NOT_FOUND = re.compile(r": command not found\s*$")

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
    r = subprocess.run(["git", "-C", cwd] + args, capture_output=True, text=True,
                       timeout=timeout, env=env, stdin=subprocess.DEVNULL)
    return r.returncode, r.stdout


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
            rc, text = git(["show", "refs/remotes/origin/%s:.gitguards.conf" % branch], proj)
            return parse_conf(text) if rc == 0 else {}
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


def pid_alive(pid):
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
        with open(os.path.join(self.path, "owner"), "w", encoding="utf-8") as fh:
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


def main():
    try:
        payload = json.loads(sys.stdin.read())
    except Exception:
        return
    if not isinstance(payload, dict) or payload.get("tool_name") not in ("Edit", "Write", "MultiEdit"):
        return
    ti = payload.get("tool_input")
    fp = ti.get("file_path") if isinstance(ti, dict) else None
    if not isinstance(fp, str) or not fp or bad_chars(fp):
        return
    proj = os.environ.get("CLAUDE_PROJECT_DIR") or ""
    if not proj or not os.path.isdir(proj):
        return
    proj = os.path.realpath(proj)
    if not os.path.isabs(fp):
        cwd = payload.get("cwd")
        if not isinstance(cwd, str) or not os.path.isabs(cwd):
            return
        fp = os.path.join(cwd, fp)
    real = os.path.realpath(fp)
    if not os.path.isfile(real) or bad_chars(real):
        return

    # ── which worktree of THIS project holds the file (no git in foreign dirs) ──
    rc, out = git(["worktree", "list", "--porcelain"], proj)
    if rc != 0:
        return
    tree = None
    for line in out.splitlines():
        if not line.startswith("worktree "):
            continue
        t = os.path.realpath(line[len("worktree "):])
        if os.path.isdir(t) and real.startswith(t.rstrip(os.sep) + os.sep):
            if tree is None or len(t) > len(tree):
                tree = t
    if tree is None:
        return

    rc, common = git(["rev-parse", "--git-common-dir"], proj)
    if rc != 0 or not common.strip():
        return
    common = os.path.realpath(os.path.join(proj, common.strip()))

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

    rel = os.path.relpath(real, tree)
    if not matches(rel, globs):
        return

    # ── queue (per tree), pauses, lock (per repository) ──
    rc, gitdir = git(["rev-parse", "--absolute-git-dir"], tree)
    if rc != 0 or not gitdir.strip():
        return
    state = os.path.join(gitdir.strip(), "post-edit-tests")
    os.makedirs(state, exist_ok=True)
    queue = os.path.join(state, "pending")
    with open(queue, "a", encoding="utf-8") as fh:
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
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
        lock.release()
        os._exit(0)

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGHUP, on_term)
    try:
        paths = []
        for q in take_queue(queue)[-MAX_QUEUE:]:
            if bad_chars(q):
                continue
            r = os.path.realpath(os.path.join(tree, q))
            if not r.startswith(tree.rstrip(os.sep) + os.sep) or not os.path.isfile(r):
                continue
            q = os.path.relpath(r, tree)
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
                stderr=subprocess.STDOUT, start_new_session=True)
            timed_out = False
            try:
                rc = proc.wait(timeout=ceiling)
            except subprocess.TimeoutExpired:
                timed_out = True
                for sig, grace in ((signal.SIGTERM, 3), (signal.SIGKILL, 5)):
                    try:
                        os.killpg(proc.pid, sig)
                    except OSError:
                        pass
                    try:
                        proc.wait(timeout=grace)
                        break
                    except subprocess.TimeoutExpired:
                        continue
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
    sys.stdout.write(json.dumps({"decision": "block", "reason": reason}) + "\n")


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    sys.exit(0)
