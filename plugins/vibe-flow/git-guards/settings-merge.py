#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""settings-merge.py <root> — registers the kit's Claude Code hooks in .claude/settings.json.

  PreToolUse  Bash                                → monitorex-git-guard.sh
  PreToolUse  Write|Edit|MultiEdit|NotebookEdit   → monitorex-git-guard.sh (writes into .git/)
  PostToolUse ExitPlanMode                        → plan-approved.sh   (if the file is there)
  PostToolUse Edit|Write|MultiEdit                → post-edit-tests.sh (if the file is there; timeout 120 s)

🔴 MERGE, DO NOT OVERWRITE. The project's settings.json may already hold other
hooks, permissions and settings; clobbering the whole file is exactly the loss of
someone else's work this whole kit was built to prevent. Written atomically via a
temp file. Idempotent: a registration that is already there is left alone.

A broken settings.json is refused (exit 1) and left untouched: "fixing" it would
wipe its content.

The two PostToolUse hooks are registered only when their script exists in
.claude/hooks/ (install.sh copies the files before calling this): a registration
pointing at a missing file would print an error after every matching tool call.

Plans directory: Claude Code confirms with a human every edit inside ~/.claude/ — even in
auto mode — so an autonomous session stalls on its own plan. `plansDirectory` moves plans
into the project. Added as ".plans" only when the key is absent (a project's own value is
kept); then the folder is created and listed in .gitignore and in .git/info/exclude (the
latter does not depend on the branch). A value outside the project (absolute, `..`) is left
alone and reported — Claude Code refuses it anyway.
"""
import json, os, re, subprocess, sys

root = sys.argv[1]
path = os.path.join(root, ".claude", "settings.json")
HOOKS_DIR = os.path.join(root, ".claude", "hooks")


def cmd(script):
    return 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/%s"' % script


# (event, matcher, script, timeout or None, needs the file to exist)
WANTED = [
    ("PreToolUse", "Bash", "monitorex-git-guard.sh", None, False),
    ("PreToolUse", "Write|Edit|MultiEdit|NotebookEdit", "monitorex-git-guard.sh", None, False),
    ("PostToolUse", "ExitPlanMode", "plan-approved.sh", None, True),
    # 120 = HOOK_TIMEOUT in post-edit-tests.py (its run ceiling is capped below it)
    ("PostToolUse", "Edit|Write|MultiEdit", "post-edit-tests.sh", 120, True),
]


def refuse(why):
    print(u"🔴 %s — nothing written. Add the hooks manually:" % why)
    for event, matcher, script, timeout, _ in WANTED:
        print(u"   %s / matcher %s / command: %s%s"
              % (event, matcher, cmd(script), "" if timeout is None else " / timeout %d" % timeout))
    sys.exit(1)


data = {}
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as exc:
        refuse(u"%s is unreadable (%s)" % (path, exc))
if not isinstance(data, dict):
    refuse(u"%s is not a JSON object" % path)
hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    refuse(u'"hooks" in %s is not an object' % path)
for event in ("PreToolUse", "PostToolUse"):
    groups = hooks.get(event, [])
    if not isinstance(groups, list) or not all(isinstance(g, dict) for g in groups):
        refuse(u'"hooks.%s" in %s is not a list of objects' % (event, path))

changed = False
for event, matcher, script, timeout, needs_file in WANTED:
    label = u"%s %s → %s" % (event, matcher, script)
    if needs_file and not os.path.isfile(os.path.join(HOOKS_DIR, script)):
        print(u"- %s skipped (.claude/hooks/%s not present)" % (label, script))
        continue
    groups = hooks.setdefault(event, [])
    same = [g for g in groups if g.get("matcher") == matcher]
    if any(script in (hk.get("command") or "")
           for g in same for hk in (g.get("hooks") or []) if isinstance(hk, dict)):
        print(u"= %s already registered" % label)
        continue
    # Reuse an existing group with the same matcher so we do not create duplicates.
    if same:
        target = same[0]
    else:
        target = {"matcher": matcher, "hooks": []}
        groups.append(target)
    if not isinstance(target.get("hooks"), list):
        target["hooks"] = []
    entry = {"type": "command", "command": cmd(script)}
    if timeout is not None:
        entry["timeout"] = timeout
    target["hooks"].append(entry)
    changed = True
    print(u"+ %s" % label)

if "plansDirectory" not in data:
    data["plansDirectory"] = ".plans"
    changed = True
    print(u"+ plansDirectory = .plans (plans in the project, not in ~/.claude/plans)")
else:
    print(u"= plansDirectory already set: %s" % data.get("plansDirectory"))

if changed:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(tmp, path)          # atomic swap
    print(u"  .claude/settings.json updated (other content preserved)")


def add_line(file, line):
    """Append `line` to `file` unless an identical line is there. → True if appended."""
    try:
        with open(file, encoding="utf-8") as fh:
            if line in (l.rstrip("\r\n") for l in fh):
                return False
    except FileNotFoundError:
        pass
    with open(file, "a+", encoding="utf-8") as fh:
        fh.seek(0, os.SEEK_END)
        if fh.tell() > 0:
            fh.seek(fh.tell() - 1)
            if fh.read(1) != "\n":
                fh.write("\n")
        fh.write(line + "\n")
    return True


# Plans directory: same rule as plans_dirs() in plan-gate.sh and plan-approved.py.
pd = data.get("plansDirectory")
if not isinstance(pd, str) or not re.fullmatch(r"\.?[A-Za-z0-9_][A-Za-z0-9_./-]*", pd) or ".." in pd.split("/"):
    print(u"! plansDirectory %r is outside the project or unusable — left alone; the plan gate "
          u"only looks in ~/.claude/plans for this project" % (pd,))
    sys.exit(0)
pd = pd.rstrip("/")
pdir = os.path.join(root, pd)
if os.path.islink(pdir):
    print(u"! %s is a symlink — plans folder not set up" % pd)
    sys.exit(0)
if not os.path.isdir(pdir):
    os.makedirs(pdir)
    print(u"+ %s/ created" % pd)
ignore = "/%s/" % pd
if add_line(os.path.join(root, ".gitignore"), ignore):
    print(u"+ %s in .gitignore" % ignore)
try:
    common = subprocess.run(["git", "-C", root, "rev-parse", "--git-common-dir"],
                            capture_output=True, text=True, timeout=10).stdout.strip()
    if common:
        common = common if os.path.isabs(common) else os.path.join(root, common)
        info = os.path.join(common, "info")
        os.makedirs(info, exist_ok=True)
        if add_line(os.path.join(info, "exclude"), ignore):
            print(u"+ %s in .git/info/exclude" % ignore)
except Exception as exc:
    print(u"! .git/info/exclude not updated (%s)" % exc)
