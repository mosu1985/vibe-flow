#!/usr/bin/env bash
# Update the vendored copy of git-guards from the source of truth (~/dev/git-guards).
# Changes to the mechanism are made THERE and only copied here; otherwise the copies drift apart.
set -eu
SRC="${GIT_GUARDS_SRC:-$HOME/dev/git-guards}"
DST="$(cd "$(dirname "$0")/.." && pwd)/plugins/vibe-flow/git-guards"
rm -rf "$DST" && mkdir -p "$DST"
cp -R "$SRC"/{files,install.sh,detect.py,settings-merge.py} "$DST"/
# Not needed by vibe-flow: its own CLAUDE.flow.md template writes the git rules,
# and /vibe-flow:init deploys them instead of the git-guards-deploy agent.
rm -rf "$DST/files/claude/agents"
echo "git-guards: $(git -C "$SRC" log -1 --format='%h %s')"
