#!/usr/bin/env bash
# Обновить вендорную копию git-guards из источника правды (~/dev/git-guards).
# Правки механизма делаются ТАМ, сюда только копируются — иначе копии разъедутся.
set -eu
SRC="${GIT_GUARDS_SRC:-$HOME/dev/git-guards}"
DST="$(cd "$(dirname "$0")/.." && pwd)/plugins/vibe-flow/git-guards"
rm -rf "$DST" && mkdir -p "$DST"
cp -R "$SRC"/{files,install.sh,detect.py,settings-merge.py} "$DST"/
# Не нужны vibe-flow: правила git пишет его собственный шаблон CLAUDE.flow.md,
# а разворачивает /vibe-flow:init, а не агент git-guards-deploy.
rm -rf "$DST/files/claude/agents"
echo "git-guards: $(git -C "$SRC" log -1 --format='%h %s')"
