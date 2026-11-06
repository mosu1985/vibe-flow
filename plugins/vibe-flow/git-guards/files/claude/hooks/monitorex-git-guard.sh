#!/usr/bin/env bash
# monitorex-git-guard.sh — PreToolUse (Bash): blocks `git add` and `git commit`
# in the SHARED working tree.
#
# WHY SEPARATE FROM GIT HOOKS. git has no hook for `git add` — that is exactly why
# the first version of the scheme did not work: a neighbor managed to stage a file
# while someone else's commit was in progress. A Claude Code hook sees the command
# BEFORE it runs and can reject it. Git hooks remain the backstop for a human in a
# terminal, Codex and IDEs, which never pass through this layer at all.
#
# Command segment parsing comes from a vendored library (shell_segments.py): it
# follows `cd` along the chain, `bash -c`, subshells, `||` and pipes. A homegrown
# parser would have been strictly worse.
#
# FAIL-OPEN on any infrastructure breakage (no python3, broken input, not a
# git directory): a safety catch must not break work when it is unsure itself.
set -u
command -v python3 >/dev/null 2>&1 || exit 0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
[ -f "$DIR/monitorex_git_guard.py" ] || exit 0
exec python3 -B "$DIR/monitorex_git_guard.py"   # -B: no __pycache__ in the project
