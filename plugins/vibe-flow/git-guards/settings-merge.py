#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""settings-merge.py <root> — registers the PreToolUse hook in .claude/settings.json.

🔴 MERGE, DO NOT OVERWRITE. The project's settings.json may already hold other
hooks, permissions and settings; clobbering the whole file is exactly the loss of
someone else's work this whole kit was built to prevent. Written atomically via a temp file.
"""
import json, os, sys

root = sys.argv[1]
path = os.path.join(root, ".claude", "settings.json")
CMD = 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/monitorex-git-guard.sh"'

data = {}
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as exc:
        # Broken JSON is not silently "fixed": overwriting would wipe its content.
        print(u"🔴 %s is unreadable (%s) — add the hook manually:" % (path, exc))
        print(u"   PreToolUse / matcher Bash / command: %s" % CMD)
        sys.exit(0)

hooks = data.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])

for entry in pre:
    for hk in entry.get("hooks", []):
        if "monitorex-git-guard" in (hk.get("command") or ""):
            print(u"= hook already registered")
            sys.exit(0)

# Look for an existing group with matcher Bash so we do not create duplicate groups.
target = None
for entry in pre:
    if entry.get("matcher") == "Bash":
        target = entry
        break
if target is None:
    target = {"matcher": "Bash", "hooks": []}
    pre.append(target)

target.setdefault("hooks", []).append({"type": "command", "command": CMD})

os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
os.replace(tmp, path)          # atomic swap
print(u"+ hook added to .claude/settings.json (other content preserved)")
