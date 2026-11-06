#!/usr/bin/env bash
# init.sh [project-path] [--no-gate] — deploy vibe-flow into a project.
#
# Does the mechanical part, the same for everyone:
#   1. git-guards: worktree/commit scripts, git hooks, Claude Code PreToolUse hook
#   2. the release-gate final-gate flag in .gitguards.conf
#   3. the vibe-flow rules block in CLAUDE.md (between markers — refreshed on re-run)
# The "Project" section in CLAUDE.md (stack, commands) is written by the model per the init skill —
# it needs judgment, not a template.
#
# Idempotent: a re-run updates the git-guards files and the rules block,
# but leaves an existing .gitguards.conf and the CLAUDE.md text outside the markers alone.
set -eu

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$PWD"; GATE=1
for a in "$@"; do
    case "$a" in
      --no-gate) GATE=0 ;;
      -*) echo "unknown flag: $a" >&2; exit 2 ;;
      *) TARGET="$a" ;;
    esac
done
TARGET="$(cd "$TARGET" && pwd)"

die() { printf '\n🔴 %s\n' "$*" >&2; exit 1; }

for bin in git python3; do
    command -v "$bin" >/dev/null 2>&1 || die "$bin is required — install it and run again"
done
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 \
    || die "$TARGET is not a git repository. First: git init && git add -A && git commit -m init"
git -C "$TARGET" rev-parse --verify -q HEAD >/dev/null \
    || die "the repository has no commits — make a first commit and run again"

VERSION=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("version","dev"))' \
    "$PLUGIN/.claude-plugin/plugin.json")

# ── 1. git-guards ────────────────────────────────────────────────────────────
GG_EMBEDDED=1 bash "$PLUGIN/git-guards/install.sh" "$TARGET"

# ── 2. final gate ────────────────────────────────────────────────────────────
CONF="$TARGET/.gitguards.conf"
printf '\n\033[1m%s\033[0m\n' "vibe-flow: final gate"
if grep -q '^GG_RELEASE_GATE=' "$CONF" 2>/dev/null; then
    echo "  = GG_RELEASE_GATE already set: $(grep '^GG_RELEASE_GATE=' "$CONF" | tail -1)"
else
    {
        echo ""
        echo "# Final vibe-flow:release-gate review (Opus) before push: without a verdict"
        echo "# pre-push refuses. 0 — disable. Mask of files that need no review."
        echo "GG_RELEASE_GATE=$GATE"
        echo 'GG_RELEASE_GATE_SKIP="*.md"'
    } >> "$CONF"
    echo "  + GG_RELEASE_GATE=$GATE"
fi

# ── 3. CLAUDE.md ─────────────────────────────────────────────────────────────
printf '\n\033[1m%s\033[0m\n' "vibe-flow: CLAUDE.md"
python3 - "$TARGET/CLAUDE.md" "$PLUGIN/templates/CLAUDE.flow.md" "$VERSION" <<'PY'
import os, re, sys
path, tpl, version = sys.argv[1:4]
block = (f"<!-- vibe-flow:begin v{version} -->\n"
         + open(tpl, encoding="utf-8").read().rstrip() + "\n"
         + "<!-- vibe-flow:end -->")
text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
pat = re.compile(r"<!-- vibe-flow:begin[^>]*-->.*?<!-- vibe-flow:end -->", re.S)
if pat.search(text):
    new, how = pat.sub(lambda _: block, text, count=1), "updated"
elif text.strip():
    new, how = text.rstrip() + "\n\n" + block + "\n", "appended to the end"
else:
    new, how = "# Project rules\n\n" + block + "\n", "created"
if new != text:
    open(path, "w", encoding="utf-8").write(new)
    print(f"  + rules block {how} (v{version})")
else:
    print(f"  = rules block is up to date (v{version})")
has_project = "<!-- vibe-flow:project:begin -->" in new
print("  = Project section present" if has_project else "  ! no Project section — /vibe-flow:init will fill it in")
PY

printf '\n✅ vibe-flow %s deployed in %s\n' "$VERSION" "$TARGET"
