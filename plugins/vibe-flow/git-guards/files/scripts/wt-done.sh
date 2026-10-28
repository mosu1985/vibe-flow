#!/usr/bin/env bash
# wt-done.sh <имя> [--force] — закрыть рабочее место: погасить dev, закрыть
# вкладки Orca, снять каталог, удалить ветку.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ СКРИПТ. `wt-new.sh` поднимает dev, но `git worktree remove`
# про него не знает: каталог исчезает, а процесс живёт сиротой и держит порт.
# Проверено 10.09.2026 — за пару дней так накопились висящие серверы.
#
# 🔴 НИЧЕГО НЕ УДАЛЯЕТ МОЛЧА. Незакоммиченные правки и неотправленные коммиты —
# стоп с объяснением, а не «поглощено вместе с каталогом»: это ровно та потеря
# работы, от которой строилась вся защита набора.
set -eu

[ $# -ge 1 ] || { echo "использование: wt-done.sh <имя> [--force]"; exit 2; }
NAME="$1"; FORCE="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Конфигурация проекта ─────────────────────────────────────────────────────
GG_WT_DIR=""
GG_BRANCH_PREFIX="wt/"
GG_PROTECTED="main"
GG_DEV_PROC_MATCH=""      # часть имени процесса dev для добивания сирот
[ -f "$ROOT/.gitguards.conf" ] && . "$ROOT/.gitguards.conf"

MAIN=$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')
WT_BASE="${GG_WT_DIR:-$(dirname "$MAIN")/$(basename "$MAIN")-wt}"
case "$WT_BASE" in /*) ;; *) WT_BASE="$(cd "$MAIN" && cd "$(dirname "$WT_BASE")" && pwd)/$(basename "$WT_BASE")" ;; esac
DIR="$WT_BASE/$NAME"

[ -d "$DIR" ] || { echo "🔴 нет каталога $DIR"; exit 1; }

# 🔴 ВЕТКА ЧИТАЕТСЯ ИЗ САМОГО ДЕРЕВА, А НЕ ВЫВОДИТСЯ ИЗ ИМЕНИ КАТАЛОГА.
# Прежнее `BRANCH="wt/$NAME"` верно лишь пока имена совпадают. После появления
# `wt-new.sh --resume <ветка> <имя-каталога>` они расходятся штатно, и вывод по
# имени в лучшем случае не находит ветку, а в худшем — находит ПОСТОРОННЮЮ с
# таким именем и удаляет её. Поймано 10.09.2026 на разборе --resume.
BRANCH=$(git -C "$DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
if [ -z "$BRANCH" ]; then
    echo "🔴 в $DIR отсоединённый HEAD — ветку определить нечем, удалять вслепую не буду."
    echo "   Снимите вручную:  git worktree remove $DIR"
    exit 1
fi

# ── 1. Проверки, что работа не пропадёт ──────────────────────────────────────
# 🔴 НИКАКИХ ПАЙПОВ ПРИ СНЯТИИ СЧЁТЧИКОВ. Прежняя форма
#     UNPUSHED=$(git log "@{upstream}..HEAD" 2>/dev/null | wc -l || echo "?")
# возвращает статус `wc`, а не `git`: при отсутствующем upstream (а он
# отсутствует у любой свежей ветки, которую ещё ни разу не пушили) git молча
# печатал пустоту, wc давал «0», ветка «?» была недостижима — и уборка СНОСИЛА
# ветку вместе с неотправленными коммитами. Ровно та потеря работы, ради
# предотвращения которой скрипт и написан. Поймано 10.09.2026 на приёмке.
if ! DIRTY_OUT=$(cd "$DIR" && git status --porcelain 2>&1); then
    echo "🔴 не удалось прочитать состояние $DIR:"
    printf '%s\n' "$DIRTY_OUT" | sed 's/^/     /'
    exit 1
fi
DIRTY=$(printf '%s' "$DIRTY_OUT" | grep -c . || true)

# Коммиты, которых нет НИГДЕ, кроме этой ветки: ни на одном remote-tracking
# ref, ни в защищённой ветке. Именно они пропадут вместе с удалением.
ORPHANED=$(cd "$DIR" && git rev-list --count HEAD \
    --not --remotes "refs/heads/$GG_PROTECTED" 2>/dev/null || echo "")
if [ -z "$ORPHANED" ]; then
    echo "🔴 не удалось сверить историю $NAME с remote и $GG_PROTECTED — не удаляю."
    echo "   Снять осознанно:  wt-done.sh $NAME --force"
    exit 1
fi

if [ "$FORCE" != "--force" ]; then
    if [ "$DIRTY" != "0" ]; then
        echo "🔴 в $NAME есть незакоммиченные правки ($DIRTY файлов):"
        printf '%s\n' "$DIRTY_OUT" | head -8 | sed 's/^/     /'
        echo
        echo "   Закоммитьте их или снимите осознанно:  wt-done.sh $NAME --force"
        exit 1
    fi
    if [ "$ORPHANED" != "0" ]; then
        echo "🔴 в $NAME есть $ORPHANED коммит(ов), которых нет ни на одном remote"
        echo "   и нет в $GG_PROTECTED — удаление ветки уничтожит их:"
        (cd "$DIR" && git log --oneline HEAD --not --remotes "refs/heads/$GG_PROTECTED" \
            2>/dev/null | head -5 | sed 's/^/     /')
        echo
        echo "   Отправьте их или снимите осознанно:  wt-done.sh $NAME --force"
        exit 1
    fi
fi

# ── 2. Погасить dev ──────────────────────────────────────────────────────────
if [ -f "$DIR/.wt-dev.pid" ]; then
    PID=$(cat "$DIR/.wt-dev.pid" 2>/dev/null || true)
    if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
        # Гасим всё дерево процессов: dev-сервер часто запускает рабочий процесс
        # отдельно, и убийство только родителя оставляет порт занятым.
        pkill -P "$PID" 2>/dev/null || true
        kill "$PID" 2>/dev/null || true
        sleep 1
        kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true
        echo "  dev остановлен (pid $PID)"
    else
        echo "  dev уже не работает"
    fi
fi

# Страховка: процесс, чей рабочий каталог — этот каталог, но pid-файл потерян.
if [ -n "$GG_DEV_PROC_MATCH" ]; then
    for p in $(lsof -t +D "$DIR" 2>/dev/null | head -20); do
        cmd=$(ps -p "$p" -o command= 2>/dev/null || true)
        case "$cmd" in
            *"$GG_DEV_PROC_MATCH"*)
                kill "$p" 2>/dev/null && echo "  добит осиротевший dev (pid $p)" || true;;
        esac
    done
fi

# ── 2b. Закрыть вкладки Orca этого рабочего места ────────────────────────────
# Актуально для машин, где проект открыт в Orca; на остальных шаг молчит.
#
# 🔴 Порядок обязателен: ДО `git worktree remove`. Orca опознаёт рабочее место по
# пути, и после удаления каталога её селектор отвечает `selector_not_found` —
# закрыть вкладки штатной командой становится нечем.
#
# Без этого шага каталог снят, ветка удалена, а в сайдбаре Orca рабочее место
# остаётся: у него живы вкладки терминала, их shell держит удалённый каталог
# своим cwd (в macOS папка живёт, пока её кто-то держит открытой), и Orca считает
# место действующим. Убрать его потом можно только руками. Так в реестре одной
# машины накопилось семь мёртвых путей.
#
# Вызов полезен даже при нуле вкладок: в ответе `retiredSurfaces: true` — Orca
# помечает поверхности рабочего места отставленными.
#
# Всё best-effort: нет Orca, не поднят рантайм, изменился формат вывода — рабочее
# место обязано сняться в любом случае. Поэтому каждый вызов гасится, а под
# `set -e` здесь только `if`: `[ ... ] && echo` уронил бы скрипт ровно там, где
# закрывать нечего.
if command -v orca >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    CLOSED=0

    # Основной путь: закрыть все терминалы рабочего места одной командой.
    WT_ID=$(orca worktree list --json 2>/dev/null \
        | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
for w in d.get('result', {}).get('worktrees', []):
    if w.get('path') == sys.argv[1]:
        print(w.get('id', ''))
        break
" "$DIR" 2>/dev/null || true)

    if [ -n "${WT_ID:-}" ]; then
        N=$(orca terminal close --worktree "$WT_ID" --all --json 2>/dev/null \
            | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
print(int(d.get('result', {}).get('closed', 0) or 0))
" 2>/dev/null || true)
        CLOSED=$(( CLOSED + ${N:-0} ))
    fi

    # Добивка: вкладки, привязанные к пути, но потерявшие своё рабочее место в
    # реестре Orca (так остаются осиротевшие вкладки от прошлых снятий).
    # Селектор для них уже не работает — закрываем поимённо, по хендлу.
    for h in $(orca terminal list --json 2>/dev/null \
        | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
for t in d.get('result', {}).get('terminals', []):
    if sys.argv[1] in str(t.get('worktreeId', '')):
        h = t.get('handle')
        if h:
            print(h)
" "$DIR" 2>/dev/null || true); do
        if orca terminal close --terminal "$h" --tab --json >/dev/null 2>&1; then
            CLOSED=$(( CLOSED + 1 ))
        fi
    done

    if [ "$CLOSED" -gt 0 ]; then
        echo "  вкладок Orca закрыто: $CLOSED"
    fi
fi

# ── 3. Снять каталог и ветку ─────────────────────────────────────────────────
git -C "$ROOT" worktree remove --force "$DIR" && echo "  каталог снят: $DIR"
git -C "$ROOT" branch -D "$BRANCH" 2>/dev/null | sed 's/^/  /' || echo "  ветки $BRANCH нет локально"

# ── 4. Подсказать про удалённую ветку ────────────────────────────────────────
# 🔴 `git push origin --delete` блокируется pre-push: при удалении уходит нулевая
# ссылка, и хук принимает это за отправку постороннего коммита. Кода там нет —
# проверять нечего, поэтому штатный путь через API, а не `--no-verify`.
if git -C "$ROOT" ls-remote --heads origin "$BRANCH" 2>/dev/null | grep -q .; then
    SLUG=$(git -C "$ROOT" remote get-url origin 2>/dev/null \
        | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')
    echo
    echo "  На origin ветка ещё есть. Если она влита — удалить так:"
    if [ -n "$SLUG" ]; then
        echo "    gh api -X DELETE repos/$SLUG/git/refs/heads/$BRANCH"
    else
        echo "    gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/$BRANCH"
    fi
fi

echo
echo "Готово: $NAME закрыт."
