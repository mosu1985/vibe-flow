#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""detect.py <root> — detects the stack and prints .gitguards.conf.

An empty value always means "this project has no such thing". That is safer than
a guess: a nonexistent command in GG_TYPECHECK_CMD would make push impossible,
and the cause would look like a broken hook.
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

# ── protected branch: ask the repository itself ─────────────────────────────
protected = "main"
try:
    ref = subprocess.run(["git", "-C", root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
                         capture_output=True, text=True, timeout=5).stdout.strip()
    if ref.startswith("origin/"):
        protected = ref.split("/", 1)[1]
except Exception:
    pass

# ── test runner ─────────────────────────────────────────────────────────────
if "vitest" in deps:
    test_cmd = "npx vitest related --run"
elif "jest" in deps:
    test_cmd = "npx jest --passWithNoTests --findRelatedTests"
else:
    test_cmd = ""

# ── type checking ───────────────────────────────────────────────────────────
if "typecheck" in scripts:
    type_cmd = "npm run typecheck"
elif "typescript" in deps:
    type_cmd = "npx tsc --noEmit"
else:
    type_cmd = ""

# ── plan gate: a new migration needs a plan too (if the project has them) ──
plan_new = "supabase/migrations/*.sql" if os.path.isdir(os.path.join(root, "supabase", "migrations")) else ""

# ── dev server and readiness marker ─────────────────────────────────────────
dev_cmd = "npm run dev" if "dev" in scripts else ""
if "next" in deps:
    ready, require_ready, proc = ".next/types .next/dev/types", "1", "next"
elif "vite" in deps:
    ready, require_ready, proc = "", "0", "vite"
else:
    ready, require_ready, proc = "", "0", ("node" if dev_cmd else "")

out = u"""# .gitguards.conf — the project-specific parts of the guards.
# Generated automatically when git-guards was deployed. Edit by hand.
# Empty value = "this project has no such thing", and the matching check stays silent.

# Where session worktrees go. Empty → <repo parent>/<repo name>-wt
GG_WT_DIR=""
GG_BRANCH_PREFIX="wt/"

# Branch that pre-push refuses to delete or rewind
GG_PROTECTED="%(protected)s"

# Test runner on commit. Paths are passed positionally; do not append $@.
GG_TEST_CMD=%(test_cmd)s

# Type check on push. 🔴 Empty means NOBODY checks types.
GG_TYPECHECK_CMD=%(type_cmd)s

# Dev server for a new worktree. Empty → no dev server is started.
GG_DEV_CMD=%(dev_cmd)s
GG_DEV_PORT_BASE=3000
GG_DEV_PORT_ENV="PORT"

# Dev readiness marker: paths whose appearance means "the build has warmed up".
# For Next these are the generated App Router types — without them tsc silently
# checks less and still says "ok".
GG_DEV_READY_GLOBS=%(ready)s
GG_DEV_READY_WAIT=80
# 1 = pre-push refuses while the marker is missing. Set it only if the marker
# really appears on its own; otherwise push becomes impossible.
GG_REQUIRE_DEV_READY=%(require_ready)s

# Part of the dev process name — so wt-done.sh can kill an orphaned server
GG_DEV_PROC_MATCH=%(proc)s

# Plan gate (pre-push, policy read from origin): commits of these types — and
# commits adding a file matching GG_PLAN_REQUIRED_NEW — need "Plan: <name>.md"
# with an approved plan. Space-separated.
GG_PLAN_REQUIRED_TYPES="feat"
GG_PLAN_GATE="githooks/plan-gate.sh"
%(plan_new)s
# Tests right after an edit (PostToolUse hook post-edit-tests.sh). Policy read from
# origin. Optional: GG_POST_EDIT_CMD (default GG_TEST_CMD), GG_POST_EDIT_GLOBS,
# GG_POST_EDIT_DEBOUNCE=20, GG_POST_EDIT_REPO_GAP=10, GG_POST_EDIT_MAX=90 (seconds).
%(post_edit)s""" % {
    "protected": protected,
    "test_cmd": json.dumps(test_cmd, ensure_ascii=False),
    "type_cmd": json.dumps(type_cmd, ensure_ascii=False),
    "dev_cmd": json.dumps(dev_cmd, ensure_ascii=False),
    "ready": json.dumps(ready, ensure_ascii=False),
    "require_ready": require_ready,
    "proc": json.dumps(proc, ensure_ascii=False),
    "plan_new": ("GG_PLAN_REQUIRED_NEW=%s\n" % json.dumps(plan_new)) if plan_new else "",
    "post_edit": "GG_POST_EDIT_TESTS=1\n" if test_cmd else "",
}
sys.stdout.write(out)
