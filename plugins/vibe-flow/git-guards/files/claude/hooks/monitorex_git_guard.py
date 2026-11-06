#!/usr/bin/env python3
"""PreToolUse guard: blocks staging and committing in the shared working tree.

A separate file, not a heredoc inside the shell script: with `python3 - <<EOF`
the heredoc takes over stdin, and the hook's actual input never reaches the script.

Full rationale: monitorex-git-guard.sh next to this file.
"""

import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "scripts", "git-guards"))
raw = sys.stdin.read()


def allow():
    sys.exit(0)


try:
    payload = json.loads(raw)
except Exception:
    allow()

if payload.get("tool_name") != "Bash":
    allow()

cmd = (payload.get("tool_input") or {}).get("command") or ""
cwd = payload.get("cwd") or os.getcwd()
if not cmd.strip():
    allow()

try:
    from shell_segments import (parse, strip_env_prefix, safe_split,
                                first_word, basename_matches)
    detail = parse(cmd)["segments_detail"]
    segments = [s["segment"] for s in detail]
except Exception:
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


# Deliberate-bypass scripts. A HUMAN sets the mark — that is why they ask
# "yes/no". But the question does not stop an agent: `echo yes | git-allow-delete.sh add`
# goes through silently. So the modes that SET a mark are forbidden to the model in any
# tree (marks live in the shared $GIT_COMMON_DIR). Reading and clearing are allowed.
# The hook does not get in a human's way: commands typed via `!` bypass PreToolUse.
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
WRAPPERS = {"env", "command", "nohup", "time", "exec", "builtin", "xargs"}
# Wrapper flags that take the next word: `env -u VAR cmd`, `exec -a name cmd`.
WRAPPER_VALUE_FLAGS = {"-u", "--unset", "-C", "--chdir", "-S", "-a", "-I", "-n", "-L", "-P"}


def basename(word: str) -> str:
    return word.rstrip("/").split("/")[-1]


def command_words(seg: str) -> list[str]:
    """Segment words starting from the real command — without VAR=, shells and wrappers."""
    words = safe_split(strip_env_prefix(seg))
    while words:
        head = basename(words[0])
        if head not in SHELLS and head not in WRAPPERS:
            break
        words = words[1:]
        while words and (words[0].startswith("-")
                         or (head in WRAPPERS and "=" in words[0])):
            takes = head in WRAPPERS and words[0] in WRAPPER_VALUE_FLAGS
            words = words[2:] if takes else words[1:]
    return words


def is_owner_mark(seg: str) -> str | None:
    """Return the script name if the segment sets an owner mark."""
    words = command_words(seg)
    if not words:
        return None
    name = words[0].rstrip("/").split("/")[-1]
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


mark = next((m for s in segments if (m := is_owner_mark(s))), None)
if mark:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": f"""🔴 `{mark}` sets a guard bypass mark — that is a human decision, not an agent's.

Show the user exactly what will be allowed and why, and ask them to run the
command themselves — in the Claude Code input line via `!` with the --yes flag
(there is no way to answer the prompt there), or in a regular terminal without the flag.
The hook will not see it: commands run via `!` bypass PreToolUse.

The agent may view and clear marks: list / status / clear.""",
    }}, ensure_ascii=False))
    sys.exit(0)


# Only the reviewer itself sets the release-gate verdict. Otherwise the main session,
# which the gate is stopping from pushing, would "approve" its own code in one line.
# Inside a subagent the hook receives agent_type — that is how we tell them apart.
# Agent name: own file in .claude/agents → `release-gate`; from the vibe-flow
# plugin → `vibe-flow:release-gate` (plugin agents get a prefix).
GATE_AGENTS = {"release-gate", "vibe-flow:release-gate"}
GATE_PATH = "monitorex-locks/release-gate"
# Commands that write to their file arguments. echo/printf are not here: they
# write to stdout, and writing that to a file is a redirect, which is caught below.
WRITERS = {"cp", "mv", "tee", "touch", "ln", "install", "rsync", "dd"}
# A redirect specifically INTO the verdict directory (`>`, `>>`, `>|`). Matching any `>`
# (2>/dev/null, 2>&1) caused false rejections on reads — and false rejections
# get the whole guard ripped out.
GATE_REDIRECT = re.compile(r">[>|]?\s*['\"]?[^\s;|&'\"]*" + re.escape(GATE_PATH))


def gate_violation(seg: str) -> str | None:
    words = command_words(seg)
    if not words:
        return None
    name = basename(words[0])
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
    if name in WRITERS and any(GATE_PATH in w for w in words[1:]):
        return "write"
    return None


gate = next((g for s in segments if (g := gate_violation(s))), None)
if gate:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": """🔴 Only the `release-gate` agent (an Opus reviewer) sets the release-gate verdict.

The main session cannot approve its own code: that is the whole point of the gate.
Run the release-gate agent on the current tree. If it returns findings,
fix them, commit, and run it again.

Bypassing review is a human decision: ask the user to run
`! scripts/release-gate.sh override --yes`.""",
    }}, ensure_ascii=False))
    sys.exit(0)

# `git push --no-verify` turns off pre-push entirely: typecheck, the parallel-session
# barriers and release-gate all at once. A human may (the hook does not fire for `!`),
# the model may not. Same bypass: swapping core.hooksPath via `-c`, `--config-env`,
# GIT_CONFIG_* variables, or `git config` beforehand.
# The direct forms are closed; indirect ones (include.path, --remove-section core,
# hand-editing .git/config) cannot be caught by PreToolUse — they show up in review.
HOOKS_PATH = re.compile(r"hooks?path", re.I)
GIT_CONFIG_ENV = re.compile(r"GIT_CONFIG_(COUNT|KEY_\w*|VALUE_\w*|PARAMETERS|GLOBAL|SYSTEM)=")
CONFIG_WRITE_FLAGS = {"--unset", "--unset-all", "--add", "--replace-all", "--edit", "-e"}
CONFIG_READ_FLAGS = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l"}
CONFIG_VALUE_FLAGS = {"-f", "--file", "--blob", "--type", "--default", "--comment"}
ENV_SETTERS = {"export", "declare", "typeset", "env"}


def git_config_env(seg_text: str) -> bool:
    """GIT_CONFIG_* set as environment: via an `X=… git` prefix or export/env."""
    toks = safe_split(seg_text)
    head = []
    for t in toks:
        if basename(t) == "git":
            break
        head.append(t)
    if any(GIT_CONFIG_ENV.match(t) for t in head):
        return True
    return bool(toks) and toks[0] in ENV_SETTERS and any(GIT_CONFIG_ENV.match(t) for t in toks[1:])


def push_bypass(seg: str) -> bool:
    words = command_words(seg)
    if not words or basename(words[0]) != "git":
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
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": """🔴 `git push` bypassing pre-push (--no-verify / swapped core.hooksPath) is forbidden to the model.

It turns off type checking, the parallel-session barriers and release-gate at once —
the code would ship unchecked. Let the hook run; a rejection means there is something
to fix (or the release-gate agent to run).

To delete a remote branch use `gh api -X DELETE …/git/refs/heads/<branch>`.
A deliberate bypass is a human decision: ask the user to push themselves
via `! git push --no-verify …` and explain exactly what gets skipped.""",
    }}, ensure_ascii=False))
    sys.exit(0)


def git(where: str, *args) -> str:
    return subprocess.run(("git", "-C", where) + args, capture_output=True,
                          text=True, timeout=5).stdout.strip()


def is_linked_worktree(where: str) -> bool | None:
    """True — linked worktree (own index), False — shared tree,
    None — not a repository (git will fail by itself, nothing to block)."""
    if not os.path.isdir(where):
        return False                 # no such directory — err on the safe side
    gd = git(where, "rev-parse", "--git-dir")
    if not gd:
        return None
    return gd != git(where, "rev-parse", "--git-common-dir")


def resolve(base: str, path: str) -> str:
    path = os.path.expanduser(path)
    return os.path.normpath(path if os.path.isabs(path) else os.path.join(base, path))


def target_dirs(candidates, c_dirs):
    """All directories where this segment's git may run.
    None in the list — the directory cannot be resolved (cd $VAR etc.)."""
    out = []
    for cand in candidates or [{"cd_dir": None, "cd_ambiguous": False}]:
        if cand.get("cd_ambiguous"):
            out.append(None)
            continue
        where = resolve(cwd, cand["cd_dir"]) if cand.get("cd_dir") else cwd
        for c in c_dirs:            # `-C a -C b` — relative paths stack
            where = resolve(where, c)
        out.append(where)
    return out


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

reason = f"""🔴 `{hit}` is forbidden in the shared working tree.

The git index here is SHARED by all parallel sessions: staged files end up in
someone else's commit within seconds (it already happened on 2026-08-06 — 7 files
of a security fix went into a commit about filter layout).

Commit like this:
  scripts/git-safe-commit.sh --message-file <file> -- <paths>

It builds the commit in an isolated index and moves the branch atomically.
Need partial staging? Work in a separate worktree:
  scripts/wt-new.sh <name>

One-off deliberate bypass (by a human, with confirmation):
  scripts/git-confirm.sh commit"""

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": reason,
}}, ensure_ascii=False))
