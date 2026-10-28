#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""settings-merge.py <корень> — вписывает PreToolUse-хук в .claude/settings.json.

🔴 СЛИЯНИЕ, А НЕ ПЕРЕЗАПИСЬ. В settings.json проекта уже могут жить чужие хуки,
разрешения и настройки; затирание файла целиком — это ровно та потеря чужой
работы, от которой строился весь набор. Пишем атомарно через временный файл.
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
        # Битый JSON не чиним молча: перезапись стёрла бы содержимое.
        print(u"🔴 %s не читается (%s) — впишите хук вручную:" % (path, exc))
        print(u"   PreToolUse / matcher Bash / command: %s" % CMD)
        sys.exit(0)

hooks = data.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])

for entry in pre:
    for hk in entry.get("hooks", []):
        if "monitorex-git-guard" in (hk.get("command") or ""):
            print(u"= хук уже зарегистрирован")
            sys.exit(0)

# Ищем существующую группу с matcher Bash, чтобы не плодить дубли групп.
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
os.replace(tmp, path)          # атомарная подмена
print(u"+ хук вписан в .claude/settings.json (остальное содержимое сохранено)")
