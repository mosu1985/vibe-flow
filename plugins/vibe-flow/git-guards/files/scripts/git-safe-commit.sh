#!/usr/bin/env bash
# git-safe-commit.sh — единственный разрешённый способ коммитить в общем дереве.
#
# ЗАЧЕМ. В репозитории одновременно работают несколько сессий Claude, агент
# Codex и человек — все в одном рабочем каталоге. Индекс git при этом ОБЩИЙ:
# аккуратный `git add <пути>` от гонки не спасает (проверено 2026-08-06 —
# 7 застейдженных файлов уехали в чужой коммит за секунды).
#
# КАК. Коммит собирается в ИЗОЛИРОВАННОМ индексе (GIT_INDEX_FILE), общий не
# читается для сборки вообще. Ветка двигается через `update-ref <ref> <new>
# <old>` — атомарный compare-and-swap: если сосед сдвинул ветку, наш перевод
# отвергается (rc=128), объект коммита остаётся достижимым.
#
# ПОРЯДОК ЛОКОВ (инвариант, не менять): сначала monitorex-locks/commit,
# потом index.lock. Так два safe-commit никогда не конкурируют за index.lock —
# их сериализует уже первый лок.
#
# Формат: git-safe-commit.sh --message-file <файл> -- <путь…>
#
# План и разбор шести раундов ревью: docs/plans/2026-09-01-parallel-session-guardrails.md

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

die() { printf '\n🔴 %s\n\n' "$*" >&2; exit 1; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
info() { printf '   %s\n' "$*" >&2; }

# ─── 0. Разбор CLI ДО всего остального ──────────────────────────────────────
# Иначе `--message-file` уезжает в pathspec, а MSGFILE остаётся неприсвоенным.
MSGFILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --message-file) [ $# -ge 2 ] || die "--message-file без значения"; MSGFILE="$2"; shift 2 ;;
        --) shift; break ;;
        -*) die "неизвестный флаг: $1 (формат: --message-file <файл> -- <пути>)" ;;
        *) die "путь до --: $1 (формат: --message-file <файл> -- <пути>)" ;;
    esac
done
[ -n "$MSGFILE" ] || die "нужен --message-file <файл>"
[ -f "$MSGFILE" ] || die "файл сообщения не найден: $MSGFILE"
[ $# -gt 0 ] || die "нужен хотя бы один путь после --"
# дальше в "$@" ТОЛЬКО pathspec

# ─── 0. Конфигурация проекта ────────────────────────────────────────────────
# Тестраннер зависит от стека, поэтому приходит из .gitguards.conf. Пусто —
# тесты не гоняются, и об этом говорится вслух: молчаливый пропуск неотличим
# от зелёного прогона.
GG_TEST_CMD=""
GG_PLAN_GATE=""
GG_TOP=$(git rev-parse --show-toplevel 2>/dev/null || echo .)
if [ -f "$GG_TOP/.gitguards.conf" ]; then . "$GG_TOP/.gitguards.conf"; fi

# ─── 0б. Гейт проекта — проверка ДО тестов и локов ──────────────────────────
# Скрипт из .gitguards.conf решает, можно ли коммитить с этим сообщением и
# этими путями (например: фича — только с пройденным планом). Получает файл
# сообщения и пути; ненулевой код — отказ. Пусто — гейта нет.
if [ -n "$GG_PLAN_GATE" ]; then
    [ -f "$GG_TOP/$GG_PLAN_GATE" ] || die "GG_PLAN_GATE указывает на несуществующий файл: $GG_PLAN_GATE"
    bash "$GG_TOP/$GG_PLAN_GATE" "$MSGFILE" "$@" || exit 1
fi

# ─── 1. Тесты — ДО любых локов ──────────────────────────────────────────────
# Держать лок минуты нельзя: пока идут тесты, соседи стоят.
if [ "${MONITOREX_SKIP_TESTS:-0}" = "1" ]; then
    warn "тесты пропущены (MONITOREX_SKIP_TESTS=1)"
elif [ -z "$GG_TEST_CMD" ]; then
    warn "тестраннер не настроен (GG_TEST_CMD в .gitguards.conf) — тесты НЕ гонялись"
else
    info "тесты по изменённым путям…"
    # Пути передаются позиционно, а не подстановкой в строку: иначе имя файла
    # с пробелом развалит команду, а имя с ; — выполнит постороннее.
    if ! sh -c "$GG_TEST_CMD \"\$@\"" gg-test "$@" >/dev/null 2>&1; then
        die "тесты не прошли. Прогнать вручную: $GG_TEST_CMD $*
   Пропустить осознанно: MONITOREX_SKIP_TESTS=1"
    fi
fi

# ─── 2. Идентичность ────────────────────────────────────────────────────────
# Пустой ACTOR делал бы проверку владельца fail-open (пустая подстрока
# совпадает с любым владельцем), поэтому — отказ.
ACTOR="${CLAUDE_CODE_SESSION_ID:-${MONITOREX_ACTOR:-}}"
[ -n "$ACTOR" ] || die "нет идентичности: задайте MONITOREX_ACTOR=<кто вы>"

COMMON=$(git rev-parse --git-common-dir)
case "$COMMON" in /*) ;; *) COMMON="$(cd "$COMMON" && pwd -P)" ;; esac
LOCKDIR="$COMMON/monitorex-locks"
LOCK="$LOCKDIR/commit"
JOURNAL="$LOCKDIR/journal"
IDXPATH=$(git rev-parse --git-path index)          # per-worktree, НЕ $COMMON/index
case "$IDXPATH" in /*) ;; *) IDXPATH="$(pwd -P)/$IDXPATH" ;; esac
IDXLOCK="$IDXPATH.lock"
TOKEN=$(uuidgen)
mkdir -p "$LOCKDIR"

IDX=""; T=""; OWN_IDXLOCK=0; OWN_COMMIT_LOCK=0; PHASE=""; NEW=""

sync_index_to() {   # $1 = commit-ish, чьё дерево кладём в общий индекс
    local tmp
    tmp=$(mktemp -t monitorex-idxcopy) || return 1
    if GIT_INDEX_FILE="$tmp" git read-tree "$1" 2>/dev/null && mv "$tmp" "$IDXPATH"; then
        return 0
    fi
    rm -f "$tmp"; return 1
}

# ─── ЕДИНЫЙ обработчик выхода ───────────────────────────────────────────────
# Второй `trap ... EXIT` в POSIX shell ЗАМЕНЯЕТ первый, поэтому здесь всё
# сразу. Забытый index.lock парализует репозиторий — снимать обязательно.
cleanup() {
    local rc=$?
    [ -n "$IDX" ] && rm -f "$IDX"
    [ -n "$T" ] && rm -f "$T"

    # Фаза post-cas: ветка уже на NEW, а общий индекс ещё на старом дереве.
    # Отпустить лок в таком виде = оставить разъехавшееся состояние, в котором
    # `git checkout` уносит файлы, а `git stash` молча забирает разницу.
    if [ "$PHASE" = "post-cas" ]; then
        if sync_index_to "$NEW"; then
            rm -f "$JOURNAL"
        else
            warn "индекс НЕ синхронизирован. Лок и журнал ОСТАВЛЕНЫ для починки:"
            warn "    scripts/git-lock.sh release   (увидит фазу post-cas и предложит repair)"
            exit "$rc"          # index.lock намеренно НЕ снимаем
        fi
    fi

    [ "$OWN_IDXLOCK" = 1 ] && rm -f "$IDXLOCK"
    if [ "$OWN_COMMIT_LOCK" = 1 ] &&
       [ "$(sed -n 's/^token=//p' "$LOCK/owner" 2>/dev/null)" = "$TOKEN" ]; then
        rm -rf "$LOCK"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ─── 3. Лок сериализации ────────────────────────────────────────────────────
if ! mkdir "$LOCK" 2>/dev/null; then
    die "коммит уже идёт: $(cat "$LOCK/owner" 2>/dev/null | tr '\n' ' ')
   Посмотреть/снять: scripts/git-lock.sh status"
fi
OWN_COMMIT_LOCK=1
printf 'actor=%s\ntoken=%s\npid=%s\nts=%s\n' \
    "$ACTOR" "$TOKEN" "$$" "$(date -u +%FT%TZ)" > "$LOCK/owner"

# ─── 4. index.lock — ДО сборки коммита, сразу с владельцем внутри ───────────
# Проверено: удержание index.lock не мешает нашим операциям с изолированным
# индексом, commit-tree и update-ref, но соседский `git add` громко отказывает.
attempts=0
until ( set -C; printf 'actor=%s\ntoken=%s\npid=%s\nts=%s\n' \
        "$ACTOR" "$TOKEN" "$$" "$(date -u +%FT%TZ)" > "$IDXLOCK" ) 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -ge 30 ] && die "index.lock занят 30с: $(cat "$IDXLOCK" 2>/dev/null | tr '\n' ' ')
   Если держатель мёртв: scripts/git-lock.sh status"
    sleep 1
done
OWN_IDXLOCK=1

BR=$(git symbolic-ref --quiet HEAD) || die "detached HEAD — коммитить нельзя"
HEAD_START=$(git rev-parse HEAD)

# ─── 5. ПРЕДусловие: общий индекс чист относительно HEAD_START ──────────────
# Именно предусловие, а не постусловие: отказ обязан случиться ДО того, как
# мы двинем ветку, иначе HEAD и индекс разъедутся.
if ! git diff-index --quiet --cached "$HEAD_START"; then
    die "в общем индексе есть застейдженное — коммит невозможен:
$(git diff --cached --name-only | sed 's/^/     /')
   Это аномалия: коммитить из общего индекса запрещено (см. хук pre-commit).
   Снять: git reset   (файлы на диске не пострадают)"
fi

# ─── 6. Сборка коммита в СВОЁМ индексе ──────────────────────────────────────
# 🔴 Файл, который УЖЕ есть в дереве коммита, добавляется с --force: .gitignore решает,
# что впервые брать в репозиторий, а не запрещает править отслеживаемое. Без этого
# правка отслеживаемого файла из игнорируемого каталога не коммитилась вовсе (так
# лежит .claude/agents/ в Bomond — 16.09.2026 починка агента встала на этом).
# --force точечный: только отдельный файл из HEAD_START; новые игнорируемые файлы и
# каталоги по-прежнему отклоняются. Сравнение через -z — пути с кириллицей git
# иначе кавычит, и файл не узнавался бы.
stage_paths() {      # IDX/HEAD_START — переменные; $@ — пути
    local p
    for p in "$@"; do
        if [ ! -d "$p" ] && \
           [ "$(git ls-tree -z --name-only "$HEAD_START" -- "$p" | tr -d '\0')" = "$p" ]; then
            GIT_INDEX_FILE="$IDX" git add --force -- "$p"
        else
            GIT_INDEX_FILE="$IDX" git add -- "$p"
        fi
    done
}

IDX=$(mktemp -t monitorex-idx)
GIT_INDEX_FILE="$IDX" git read-tree "$HEAD_START"
stage_paths "$@"

# ─── 7. Сверка состава: в коммите ровно то, что просили ─────────────────────
if ! GIT_INDEX_FILE="$IDX" git -c core.quotePath=false diff --cached -z --name-only "$HEAD_START" \
     | python3 -B "$SCRIPT_DIR/git-guards/verify_staged.py" --expect "$@"; then
    die "состав коммита не совпал с запрошенными путями (см. выше)"
fi

if GIT_INDEX_FILE="$IDX" git diff-index --quiet --cached "$HEAD_START"; then
    die "нечего коммитить: указанные пути не отличаются от HEAD"
fi

info "состав коммита:"
GIT_INDEX_FILE="$IDX" git diff --cached --stat "$HEAD_START" | sed 's/^/     /' >&2

# ─── 8. Коммит + журнал транзакции ──────────────────────────────────────────
TREE=$(GIT_INDEX_FILE="$IDX" git write-tree)
NEW=$(git interpret-trailers --trailer "Session-Id: $ACTOR" < "$MSGFILE" \
      | git commit-tree "$TREE" -p "$HEAD_START")

# Объект commit-tree недостижим — закрепляем ref-ом ДО CAS, иначе соседский
# `git gc --prune=now` его сотрёт.
git update-ref "refs/monitorex/recovery/$TOKEN" "$NEW"

write_journal() {
    printf 'branch=%s\nold=%s\nnew=%s\ntoken=%s\nactor=%s\nphase=%s\n' \
        "$BR" "$HEAD_START" "$NEW" "$TOKEN" "$ACTOR" "$1" > "$JOURNAL"
}
write_journal pre-cas

# ─── 9. CAS ─────────────────────────────────────────────────────────────────
retry_or_die() {      # $@ — pathspec; NEW/HEAD_START/BR/TREE — переменные
    local attempt=1 new_head changed
    while [ "$attempt" -le 3 ]; do
        new_head=$(git rev-parse "$BR")

        # Пересечение путей — ОТКАЗ, а не пересборка: иначе мы пересоберём от
        # чужого коммита и затрём его правку своим содержимым с диска.
        changed=$(git diff --name-only -z "$HEAD_START" "$new_head" || true)
        if printf '%s' "$changed" \
           | python3 -B "$SCRIPT_DIR/git-guards/verify_staged.py" --intersects "$@"; then
            die "сосед изменил те же файлы (попытка $attempt).
   Ваш коммит сохранён: refs/monitorex/recovery/$TOKEN
   Посмотреть: scripts/git-recovery.sh show $TOKEN"
        fi

        HEAD_START="$new_head"
        GIT_INDEX_FILE="$IDX" git read-tree "$HEAD_START"
        stage_paths "$@"
        TREE=$(GIT_INDEX_FILE="$IDX" git write-tree)
        NEW=$(git interpret-trailers --trailer "Session-Id: $ACTOR" < "$MSGFILE" \
              | git commit-tree "$TREE" -p "$HEAD_START")
        git update-ref "refs/monitorex/recovery/$TOKEN" "$NEW"
        write_journal pre-cas

        if git update-ref "$BR" "$NEW" "$HEAD_START" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
    done
    die "3 попытки CAS исчерпаны. Коммит сохранён: refs/monitorex/recovery/$TOKEN
   Восстановить: git cherry-pick $NEW"
}

if ! git update-ref "$BR" "$NEW" "$HEAD_START" 2>/dev/null; then
    warn "ветку сдвинул сосед — пересобираю коммит"
    retry_or_die "$@"
fi

PHASE=post-cas
write_journal post-cas

# ─── 10. Синхронизация общего индекса под уже удерживаемым локом ────────────
sync_index_to "$NEW" || die "индекс не синхронизирован — см. scripts/git-lock.sh release"

# ─── 11. Транзакция завершена ───────────────────────────────────────────────
git update-ref -d "refs/monitorex/recovery/$TOKEN"
rm -f "$JOURNAL"
PHASE=done

# ─── 12. Предупреждение о новом коде без потребителей (не блокирует) ────────
bash "$SCRIPT_DIR/git-guards/consumer-warn.sh" "$NEW" "$@" || true

printf '\n✅ %s  %s\n\n' "$(git rev-parse --short "$NEW")" "$(git log -1 --format=%s "$NEW")" >&2
