#!/usr/bin/env bash
# install-git-guards.sh — ставит канонические хуки ВНЕ рабочего дерева.
#
# Почему не .husky: husky резолвит хук относительно текущего checkout.
# Worktree со старой базы или переключение основного дерева на ревизию до
# внедрения guard подсунут git СТАРУЮ версию хука — вместе с отсутствием в
# ней всех проверок. Каталог в git-common-dir от переключений не зависит.
#
# Идемпотентен: одинаковое содержимое не трогает, другое — перезаписывает.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
COMMON=$(git -C "$ROOT" rev-parse --git-common-dir)
case "$COMMON" in /*) ;; *) COMMON="$(cd "$ROOT/$COMMON" && pwd -P)" ;; esac
DEST="$COMMON/monitorex-hooks"
mkdir -p "$DEST"

for h in pre-commit pre-push; do
    src="$ROOT/githooks/$h"; dst="$DEST/$h"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        echo "  = $h без изменений"
    else
        tmp="$dst.tmp.$$"
        cp "$src" "$tmp"; chmod +x "$tmp"; mv "$tmp" "$dst"   # атомарная подмена
        echo "  + $h установлен"
    fi
    shasum -a 256 "$src" | cut -d' ' -f1 > "$DEST/$h.sha256"
done

git -C "$ROOT" config core.hooksPath "$DEST"
echo "  core.hooksPath = $DEST"
echo "Готово. Проверить: scripts/git-lock.sh status"
