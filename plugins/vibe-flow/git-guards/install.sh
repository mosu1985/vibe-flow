#!/usr/bin/env bash
# install.sh [путь-к-проекту] — развернуть git-guards в проекте.
#
# Копирует канонические файлы, определяет стек, пишет .gitguards.conf,
# ставит хуки вне рабочего дерева и прогоняет приёмку.
# Идемпотентен: повторный запуск обновляет файлы и НЕ трогает существующий
# .gitguards.conf (его правит человек).
set -eu

GG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$PWD}"
TARGET="$(cd "$TARGET" && pwd -P)"

say()  { printf '  %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\n🔴 %s\n' "$*" >&2; exit 1; }

# ── 0. Проверки цели ─────────────────────────────────────────────────────────
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || die "$TARGET — не git-репозиторий"
# Оба пути — физические и от TARGET: --git-common-dir бывает относительным
# (".git"), и `cd` от каталога вызывающего уводил в чужой репозиторий.
GITDIR=$(cd "$(git -C "$TARGET" rev-parse --absolute-git-dir)" && pwd -P)
COMMON=$(cd "$TARGET" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
[ "$GITDIR" = "$COMMON" ] || die "это linked worktree. Ставить надо в основном дереве: $COMMON/.."
TOP=$(git -C "$TARGET" rev-parse --show-toplevel)
[ "$TOP" = "$TARGET" ] || die "запускайте из корня репозитория ($TOP)"

head_ "Цель: $TARGET"

# ── 1. Копирование файлов ────────────────────────────────────────────────────
head_ "1. Файлы"
mkdir -p "$TARGET/scripts" "$TARGET/githooks" "$TARGET/.claude/hooks"
for f in "$GG"/files/scripts/*; do
    [ -f "$f" ] || continue                      # подкаталог git-guards идёт отдельно
    n=$(basename "$f")
    if [ -f "$TARGET/scripts/$n" ] && cmp -s "$f" "$TARGET/scripts/$n"; then
        say "= scripts/$n"
    else
        cp "$f" "$TARGET/scripts/$n"; chmod +x "$TARGET/scripts/$n"; say "+ scripts/$n"
    fi
done

# 🔴 scripts/git-guards/ — не «дополнительные утилиты», а зависимость:
# git-safe-commit.sh зовёт verify_staged.py и consumer-warn.sh, а харнесс-хук
# импортирует shell_segments.py. Копирование одних только *.sh давало бы набор,
# который устанавливается без ошибок и падает на первом же коммите.
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

# ── 2. Конфигурация ──────────────────────────────────────────────────────────
head_ "2. Конфигурация"
if [ -f "$TARGET/.gitguards.conf" ]; then
    say "= .gitguards.conf уже есть — не трогаю"
else
    python3 "$GG/detect.py" "$TARGET" > "$TARGET/.gitguards.conf"
    say "+ .gitguards.conf создан по автодетекту стека:"
    grep -E '^GG_' "$TARGET/.gitguards.conf" | sed 's/^/      /'
fi

# ── 3. Харнесс-хук Claude Code ───────────────────────────────────────────────
head_ "3. Хук Claude Code (запрет git add)"
python3 "$GG/settings-merge.py" "$TARGET" | sed 's/^/  /'

# ── 4. Установка git-хуков вне рабочего дерева ───────────────────────────────
head_ "4. git-хуки"
bash "$TARGET/scripts/install-git-guards.sh" | sed 's/^/  /'

# ── 5. Приёмка ───────────────────────────────────────────────────────────────
head_ "5. Приёмка"
if bash "$TARGET/scripts/test-git-guards.sh" > /tmp/gg-accept.log 2>&1; then
    tail -3 /tmp/gg-accept.log | sed 's/^/  /'
    say "✅ приёмка пройдена"
else
    tail -25 /tmp/gg-accept.log | sed 's/^/  /'
    die "приёмка НЕ пройдена — развёртывание считается неуспешным. Лог: /tmp/gg-accept.log"
fi

# Встроенный запуск (vibe-flow init) сам пишет CLAUDE.md и сам говорит про
# коммит — свои «ручные шаги» здесь только запутали бы.
if [ "${GG_EMBEDDED:-0}" != 1 ]; then
head_ "Готово"
cat <<'TXT'
  Осталось два ручных шага:
    1. Дописать в CLAUDE.md проекта раздел про коммиты — образец в
       git-guards/CLAUDE-snippet.md
    2. Закоммитить новые файлы — из основного дерева, изолированным индексом
       (worktree от HEAD их не увидит: они ещё не в истории):
       scripts/git-safe-commit.sh --message-file <файл> -- <пути>
TXT
fi
