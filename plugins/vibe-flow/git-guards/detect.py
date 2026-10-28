#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""detect.py <корень> — определяет стек и печатает .gitguards.conf.

Пустое значение всегда означает «в этом проекте такого нет». Оно безопаснее
выдуманного: несуществующая команда в GG_TYPECHECK_CMD сделала бы push
невозможным, а причина выглядела бы как поломка хука.
"""
import json, os, subprocess, sys

root = sys.argv[1]
pkg = {}
p = os.path.join(root, "package.json")
if os.path.isfile(p):
    try:
        pkg = json.load(open(p, encoding="utf-8"))
    except Exception:
        pkg = {}

deps = dict(pkg.get("dependencies") or {}, **(pkg.get("devDependencies") or {}))
scripts = pkg.get("scripts") or {}

# ── защищённая ветка: спрашиваем сам репозиторий ────────────────────────────
protected = "main"
try:
    ref = subprocess.run(["git", "-C", root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
                         capture_output=True, text=True, timeout=5).stdout.strip()
    if ref.startswith("origin/"):
        protected = ref.split("/", 1)[1]
except Exception:
    pass

# ── тестраннер ──────────────────────────────────────────────────────────────
if "vitest" in deps:
    test_cmd = "npx vitest related --run"
elif "jest" in deps:
    test_cmd = "npx jest --passWithNoTests --findRelatedTests"
else:
    test_cmd = ""

# ── проверка типов ──────────────────────────────────────────────────────────
if "typecheck" in scripts:
    type_cmd = "npm run typecheck"
elif "typescript" in deps:
    type_cmd = "npx tsc --noEmit"
else:
    type_cmd = ""

# ── dev-сервер и признак готовности ─────────────────────────────────────────
dev_cmd = "npm run dev" if "dev" in scripts else ""
if "next" in deps:
    ready, require_ready, proc = ".next/types .next/dev/types", "1", "next"
elif "vite" in deps:
    ready, require_ready, proc = "", "0", "vite"
else:
    ready, require_ready, proc = "", "0", ("node" if dev_cmd else "")

out = u"""# .gitguards.conf — что в защите зависит от этого проекта.
# Создан автоматически при развёртывании git-guards. Правится руками.
# Пустое значение = «такого в проекте нет» и соответствующая проверка молчит.

# Куда складывать рабочие деревья сессий. Пусто → <родитель репо>/<имя репо>-wt
GG_WT_DIR=""
GG_BRANCH_PREFIX="wt/"

# Ветка, которую pre-push запрещает удалять и откатывать
GG_PROTECTED="%(protected)s"

# Тестраннер на коммите. Пути передаются позиционно, дописывать $@ не нужно.
GG_TEST_CMD=%(test_cmd)s

# Проверка типов на push. 🔴 Пусто — и типы не проверит НИКТО.
GG_TYPECHECK_CMD=%(type_cmd)s

# Dev-сервер нового рабочего дерева. Пусто → dev не поднимается.
GG_DEV_CMD=%(dev_cmd)s
GG_DEV_PORT_BASE=3000
GG_DEV_PORT_ENV="PORT"

# Признак готовности dev: пути, появление которых значит «сборка прогрелась».
# У Next это сгенерированные типы App Router — без них tsc молча проверяет
# меньше и всё равно говорит «ок».
GG_DEV_READY_GLOBS=%(ready)s
GG_DEV_READY_WAIT=80
# 1 = pre-push откажет, пока признака нет. Ставить только если он реально
# появляется сам: иначе push станет невозможен.
GG_REQUIRE_DEV_READY=%(require_ready)s

# Часть имени процесса dev — чтобы wt-done.sh добил осиротевший сервер
GG_DEV_PROC_MATCH=%(proc)s
""" % {
    "protected": protected,
    "test_cmd": json.dumps(test_cmd, ensure_ascii=False),
    "type_cmd": json.dumps(type_cmd, ensure_ascii=False),
    "dev_cmd": json.dumps(dev_cmd, ensure_ascii=False),
    "ready": json.dumps(ready, ensure_ascii=False),
    "require_ready": require_ready,
    "proc": json.dumps(proc, ensure_ascii=False),
}
sys.stdout.write(out)
