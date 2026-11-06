#!/usr/bin/env bash
# install.sh [path-to-project] — deploy git-guards into a project.
#
# Copies the canonical files, detects the stack, writes .gitguards.conf,
# installs the hooks outside the working tree and runs the acceptance tests.
# Idempotent: a rerun updates the files and does NOT touch an existing
# .gitguards.conf (a human edits it).
set -eu

GG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$PWD}"
TARGET="$(cd "$TARGET" && pwd -P)"

say()  { printf '  %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\n🔴 %s\n' "$*" >&2; exit 1; }

# ── 0. Target checks ─────────────────────────────────────────────────────────
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || die "$TARGET is not a git repository"
# Both paths are physical and resolved from TARGET: --git-common-dir can be relative
# (".git"), and a `cd` from the caller's directory used to land in a different repository.
GITDIR=$(cd "$(git -C "$TARGET" rev-parse --absolute-git-dir)" && pwd -P)
COMMON=$(cd "$TARGET" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
[ "$GITDIR" = "$COMMON" ] || die "this is a linked worktree. Install into the main working tree: $COMMON/.."
TOP=$(git -C "$TARGET" rev-parse --show-toplevel)
[ "$TOP" = "$TARGET" ] || die "run from the repository root ($TOP)"

head_ "Target: $TARGET"

# ── 1. Copy files ────────────────────────────────────────────────────────────
head_ "1. Files"
mkdir -p "$TARGET/scripts" "$TARGET/githooks" "$TARGET/.claude/hooks"
for f in "$GG"/files/scripts/*; do
    [ -f "$f" ] || continue                      # the git-guards subdirectory is handled separately
    n=$(basename "$f")
    if [ -f "$TARGET/scripts/$n" ] && cmp -s "$f" "$TARGET/scripts/$n"; then
        say "= scripts/$n"
    else
        cp "$f" "$TARGET/scripts/$n"; chmod +x "$TARGET/scripts/$n"; say "+ scripts/$n"
    fi
done

# 🔴 scripts/git-guards/ is not "extra utilities", it is a dependency:
# git-safe-commit.sh calls verify_staged.py and consumer-warn.sh, and the harness hook
# imports shell_segments.py. Copying only the *.sh files would produce a kit
# that installs without errors and fails on the very first commit.
mkdir -p "$TARGET/scripts/git-guards"
for f in "$GG"/files/scripts/git-guards/*; do
    n=$(basename "$f"); cp "$f" "$TARGET/scripts/git-guards/$n"
    case "$n" in *.sh|verify_staged.py) chmod +x "$TARGET/scripts/git-guards/$n";; esac
    say "+ scripts/git-guards/$n"
done
for f in "$GG"/files/githooks/*; do
    n=$(basename "$f"); cp "$f" "$TARGET/githooks/$n"; chmod +x "$TARGET/githooks/$n"; say "+ githooks/$n"
done
for f in "$GG"/files/claude/hooks/*; do
    n=$(basename "$f"); cp "$f" "$TARGET/.claude/hooks/$n"
    case "$n" in *.sh) chmod +x "$TARGET/.claude/hooks/$n";; esac
    say "+ .claude/hooks/$n"
done

# ── 2. Configuration ─────────────────────────────────────────────────────────
head_ "2. Configuration"
if [ -f "$TARGET/.gitguards.conf" ]; then
    say "= .gitguards.conf already exists — leaving it alone"
else
    python3 "$GG/detect.py" "$TARGET" > "$TARGET/.gitguards.conf"
    say "+ .gitguards.conf created from stack auto-detection:"
    grep -E '^GG_' "$TARGET/.gitguards.conf" | sed 's/^/      /'
fi

# ── 3. Claude Code harness hook ──────────────────────────────────────────────
head_ "3. Claude Code hook (blocks git add)"
python3 "$GG/settings-merge.py" "$TARGET" | sed 's/^/  /'

# ── 4. Install git hooks outside the working tree ────────────────────────────
head_ "4. git hooks"
bash "$TARGET/scripts/install-git-guards.sh" | sed 's/^/  /'

# ── 5. Acceptance ────────────────────────────────────────────────────────────
head_ "5. Acceptance"
if bash "$TARGET/scripts/test-git-guards.sh" > /tmp/gg-accept.log 2>&1; then
    tail -3 /tmp/gg-accept.log | sed 's/^/  /'
    say "✅ acceptance passed"
else
    tail -25 /tmp/gg-accept.log | sed 's/^/  /'
    die "acceptance FAILED — the deployment counts as unsuccessful. Log: /tmp/gg-accept.log"
fi

# An embedded run (vibe-flow init) writes CLAUDE.md and handles the commit
# message itself — our own "manual steps" here would only confuse.
if [ "${GG_EMBEDDED:-0}" != 1 ]; then
head_ "Done"
cat <<'TXT'
  Two manual steps remain:
    1. Add the commit section to the project's CLAUDE.md — template in
       git-guards/CLAUDE-snippet.md
    2. Commit the new files — from the main working tree, with an isolated index
       (a worktree from HEAD will not see them: they are not in history yet):
       scripts/git-safe-commit.sh --message-file <file> -- <paths>
TXT
fi
