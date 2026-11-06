#!/usr/bin/env bash
# wt-new.sh — рабочее место сессии: свой каталог, своя ветка, свой индекс,
# свой HEAD и свой dev-сервер на свободном порту.
#
#   wt-new.sh <имя> [база]                  новое дерево и ветка от свежего origin/main
#   wt-new.sh --resume <ветка> [имя]        дерево на СУЩЕСТВУЮЩЕЙ ветке
#   wt-new.sh <имя> --new                   новое, несмотря на похожую начатую
#
# Всё, что зависит от стека (dev-команда, признак готовности, базовый порт),
# берётся из .gitguards.conf в корне репозитория.
#
# Основа новой ветки по умолчанию — защищённая ветка (GG_PROTECTED) в самом
# свежем виде: перед созданием скрипт сам делает `git fetch`. Явная [база]
# (ветка, тег, коммит) отменяет это поведение.
set -eu
usage() { sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GG_WT_DIR=""
GG_BRANCH_PREFIX="wt/"
GG_DEV_CMD=""
GG_DEV_PORT_BASE=3000
GG_DEV_PORT_ENV="PORT"
GG_DEV_READY_GLOBS=""
GG_DEV_READY_WAIT=80
GG_PROTECTED="main"
[ -f "$ROOT/.gitguards.conf" ] && . "$ROOT/.gitguards.conf"

RESUME=""; FORCE_NEW=0; NAME=""; BASE=""
if [ "$1" = "--resume" ]; then
    [ $# -ge 2 ] || usage
    RESUME="$2"; NAME="${3:-}"
else
    NAME="$1"; shift
    for a in "$@"; do
        case "$a" in --new) FORCE_NEW=1 ;; *) BASE="$a" ;; esac
    done
fi

# 🔴 Каталог деревьев считается от ГЛАВНОГО дерева, а не от расположения
# скрипта: запуск из worktree иначе создаёт вложенное <база>/<база>/.
MAIN=$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')
WT_BASE="${GG_WT_DIR:-$(dirname "$MAIN")/$(basename "$MAIN")-wt}"
case "$WT_BASE" in /*) ;; *) WT_BASE="$(cd "$MAIN" && cd "$(dirname "$WT_BASE")" && pwd)/$(basename "$WT_BASE")" ;; esac

# ── Возобновление начатой работы ─────────────────────────────────────────────
# 🔴 Без этого режима вернуться в брошенную ветку было НЕЧЕМ: скрипт умел только
# заводить новую (`worktree add -b`) и на существующем имени падал с «branch
# already exists». Оставался голый `git worktree add` — мимо клонирования
# зависимостей, копирования .env.local, установки гардов и подъёма dev.
if [ -n "$RESUME" ]; then
    BRANCH="$RESUME"
    git -C "$ROOT" rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null \
        || { echo "🔴 ветки $BRANCH нет локально"; exit 1; }
    EXIST=$(git -C "$ROOT" worktree list --porcelain \
        | awk -v b="refs/heads/$BRANCH" '/^worktree /{w=substr($0, 10)} /^branch /{if ($2==b) print w}')
    if [ -n "$EXIST" ]; then
        echo "🔴 ветка $BRANCH уже разложена в дереве:"; echo "     $EXIST"
        echo "   Работайте там — второй раз одну ветку git не выдаст."; exit 1
    fi
    # Каталог по умолчанию — по имени ветки; он может быть занят ДРУГОЙ веткой,
    # поэтому имя задаётся третьим аргументом, а не подбирается молча.
    [ -n "$NAME" ] || NAME=$(basename "$BRANCH")
else
    BRANCH="$GG_BRANCH_PREFIX$NAME"

    # ── Не начата ли эта работа раньше ───────────────────────────────────────
    # 🔴 Совпадение имён ловит сам git. А вот вторая сессия, назвавшая ту же
    # задачу иначе, молча отпочковывалась от главной ветки и писала всё заново.
    if [ "$FORCE_NEW" = "0" ] && [ -x "$ROOT/scripts/wt-status.sh" ]; then
        UNFIN=$(bash "$ROOT/scripts/wt-status.sh" --names 2>/dev/null || true)
        if [ -n "$UNFIN" ]; then
            HITS=""
            # Общее слово от 4 букв — признак «та же тема». Короче нельзя:
            # «fix», «api», «ui» совпадут у всего, и предупреждение перестанут
            # читать ровно тогда, когда оно понадобится.
            for tok in $(printf '%s' "$NAME" | tr '\-_/' '   '); do
                [ ${#tok} -ge 4 ] || continue
                for b in $UNFIN; do
                    case "$b" in *"$tok"*)
                        case " $HITS " in *" $b "*) ;; *) HITS="$HITS$b ";; esac ;;
                    esac
                done
            done
            if [ -n "$HITS" ]; then
                echo "🔴 Похоже, эта работа уже начата:"
                for b in $HITS; do printf '     %s\n' "$b"; done
                echo ""
                echo "   Продолжить начатое:  scripts/wt-new.sh --resume <ветка>"
                echo "   Это другая задача:   scripts/wt-new.sh $NAME --new"
                exit 1
            fi
            echo "  ⚠️  есть незавершённые ветки (не по этой теме):"
            printf '%s\n' "$UNFIN" | sed 's/^/       /'
        fi
    fi
fi

DIR="$WT_BASE/$NAME"
if [ -e "$DIR" ]; then
    echo "🔴 каталог уже занят: $DIR"
    OCC=$(git -C "$ROOT" worktree list --porcelain | awk -v d="$DIR" '/^worktree /{w=substr($0, 10)} /^branch /{if (w==d) {sub("refs/heads/","",$2); print $2}}')
    [ -n "$OCC" ] && echo "   в нём разложена ветка $OCC"
    [ -n "$RESUME" ] && echo "   Задайте своё имя каталога:  scripts/wt-new.sh --resume $BRANCH <имя>"
    exit 1
fi

# ── Основа новой ветки ───────────────────────────────────────────────────────
# 🔴 Раньше основой был HEAD главного дерева. Но вливание идёт на GitHub, а
# локальную главную ветку после мержа никто не подтягивает: каждая новая
# задача стартовала со СТАРОГО кода — без правок соседних, уже влитых веток.
# Отсюда повторные починки уже починенного и конфликты при мерже. Поэтому
# по умолчанию — свежая защищённая ветка с origin, а не то, что лежит на диске.
has_ref() { git -C "$ROOT" rev-parse --verify -q "$1^{commit}" >/dev/null 2>&1; }
short() { git -C "$ROOT" rev-parse --short "$1"; }
if [ -z "$RESUME" ] && [ -z "$BASE" ]; then
    LOCAL="refs/heads/$GG_PROTECTED"; REMOTE="refs/remotes/origin/$GG_PROTECTED"
    if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
        # Без интерактивного запроса пароля и без вечного ожидания на мёртвой
        # сети: при сбое — предупреждение и работа с тем, что есть локально.
        GIT_TERMINAL_PROMPT=0 git -C "$ROOT" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 \
            fetch -q origin "$GG_PROTECTED" 2>/dev/null \
            || echo "  ⚠️  не удалось обновить origin/$GG_PROTECTED (нет сети, доступа или такой ветки на origin) — беру то, что есть локально"
    fi
    if has_ref "$REMOTE" && has_ref "$LOCAL"; then
        if git -C "$ROOT" merge-base --is-ancestor "$REMOTE" "$LOCAL"; then
            BASE="$LOCAL"       # локальная ветка та же или впереди (неотправленные коммиты)
        elif git -C "$ROOT" merge-base --is-ancestor "$LOCAL" "$REMOTE"; then
            BASE="$REMOTE"      # обычный случай: локальная отстала после мержей на GitHub
        else
            BASE="$REMOTE"
            N=$(git -C "$ROOT" rev-list --count "$REMOTE..$LOCAL")
            echo "  ⚠️  локальная $GG_PROTECTED разошлась с origin/$GG_PROTECTED — основа origin/$GG_PROTECTED;"
            echo "      $N локальных коммита(ов) $GG_PROTECTED в новую ветку НЕ попадут"
        fi
    elif has_ref "$REMOTE"; then
        BASE="$REMOTE"
    elif has_ref "$LOCAL"; then
        BASE="$LOCAL"           # репозиторий без origin — только локальная ветка
    else
        BASE="HEAD"             # нет защищённой ветки вовсе (новый репозиторий)
    fi
    case "$BASE" in
        refs/remotes/*) LABEL="${BASE#refs/remotes/}" ;;
        refs/heads/*)   LABEL="${BASE#refs/heads/}" ;;
        *)              LABEL="$BASE" ;;
    esac
    echo "  основа: $LABEL ($(short "$BASE"))"

    # Главное дерево на защищённой ветке и отстаёт — сказать: dev-сервер
    # главной папки показывает старую версию, и это выглядит как поломка.
    if [ "$BASE" = "$REMOTE" ] && has_ref "$LOCAL" \
       && [ "$(git -C "$MAIN" symbolic-ref -q HEAD 2>/dev/null)" = "$LOCAL" ] \
       && git -C "$ROOT" merge-base --is-ancestor "$LOCAL" "$REMOTE"; then
        BEHIND=$(git -C "$ROOT" rev-list --count "$LOCAL..$REMOTE")
        if [ "$BEHIND" -gt 0 ]; then
            echo "  ℹ️  главная папка отстаёт от origin/$GG_PROTECTED на $BEHIND коммит(ов): git -C \"$MAIN\" pull --ff-only"
        fi
    fi
fi

if [ -n "$RESUME" ]; then
    git -C "$ROOT" worktree add "$DIR" "$BRANCH"
else
    # --no-track: от origin/<ветка> git иначе назначил бы её upstream'ом новой
    # ветки, и `git status` писал бы «впереди origin/main». Свой upstream
    # ветка получает при первом `git push -u origin <ветка>`.
    git -C "$ROOT" worktree add --no-track -b "$BRANCH" "$DIR" "$BASE"
fi

# ── Зависимости ──────────────────────────────────────────────────────────────
# node_modules: КЛОН через APFS clonefile (`cp -Rc`), а НЕ симлинк. Turbopack
# (Next 16) отвергает симлинк за пределы каталога проекта и падает сразу. Клон
# делается за секунды и почти не занимает места (copy-on-write).
if [ -d "$MAIN/node_modules" ]; then
    LOCK_SAME=1
    for f in package-lock.json pnpm-lock.yaml yarn.lock bun.lockb; do
        [ -f "$MAIN/$f" ] && { cmp -s "$MAIN/$f" "$DIR/$f" || LOCK_SAME=0; }
    done
    if [ "$LOCK_SAME" = "1" ]; then
        if cp -Rc "$MAIN/node_modules" "$DIR/node_modules" 2>/dev/null; then
            echo "  node_modules → клон APFS (copy-on-write)"
        else
            cp -R "$MAIN/node_modules" "$DIR/node_modules"
            echo "  node_modules → обычная копия (clonefile недоступен)"
        fi
    else
        echo "  ⚠️  lockfile отличается — нужна своя установка пакетов в $DIR"
    fi
fi

# 🔴 .env.local не отслеживается git — в свежем дереве его нет, и API отдаёт
# 500, а причина выглядит как поломка кода.
for f in .env.local .env.development.local; do
    [ -f "$MAIN/$f" ] && [ ! -f "$DIR/$f" ] && cp "$MAIN/$f" "$DIR/$f" && echo "  $f скопирован"
done

bash "$ROOT/scripts/install-git-guards.sh" >/dev/null

# ── Свой dev на свободном порту ──────────────────────────────────────────────
PORT=""
if [ -n "$GG_DEV_CMD" ]; then
    PORT="$GG_DEV_PORT_BASE"
    while lsof -i:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do PORT=$((PORT+1)); done
    printf '%s\n' ".wt-dev.pid" \
        >> "$(git -C "$DIR" rev-parse --git-path info/exclude)"

    # 🔴 ФОРМА ЗАПУСКА ВАЖНА, И ОЧЕВИДНАЯ — НЕВЕРНА. Связка `cd && nohup … &`
    # уходит в фон целиком, подоболочка не делает exec и ЖДЁТ сервер, держа
    # stdout вызвавшей команды; в pid-файл попадает pid обёртки. Здесь
    # перенаправления навешаны на всю подоболочку, а exec заменяет её сервером.
    # 🔴 Лог — в служебной папке git, НЕ в дереве: Turbopack следит за деревом,
    # каждая строка лога для него «изменение файла» → Fast Refresh → браузер
    # перезагружается → новая строка лога. Вечный цикл перезагрузок.
    DEVLOG="$(git -C "$DIR" rev-parse --absolute-git-dir)/wt-dev.log"
    ( cd "$DIR" && exec env "$GG_DEV_PORT_ENV=$PORT" nohup sh -c "$GG_DEV_CMD" ) \
        < /dev/null > "$DEVLOG" 2>&1 &
    echo $! > "$DIR/.wt-dev.pid"

    # Признак готовности: у Next это сгенерированные .next/types — без них
    # pre-push откажет, и дерево оказалось бы бесполезным.
    if [ -n "$GG_DEV_READY_GLOBS" ]; then
        echo "  жду готовности ($GG_DEV_READY_GLOBS)…"
        WAITED=0; FOUND=0
        while [ "$WAITED" -lt "$GG_DEV_READY_WAIT" ]; do
            for g in $GG_DEV_READY_GLOBS; do [ -e "$DIR/$g" ] && FOUND=1; done
            [ "$FOUND" = "1" ] && break
            sleep 2; WAITED=$((WAITED+2))
        done
        [ "$FOUND" = "1" ] && echo "  готово ✅ — push отсюда пройдёт" \
            || echo "  ⚠️  признак не появился за ${GG_DEV_READY_WAIT}с: $DEVLOG"
    fi
fi

echo
echo "Готово: $DIR"
echo "  ветка:      $BRANCH"
[ -n "$PORT" ] && echo "  dev:        http://localhost:$PORT  (pid $(cat "$DIR/.wt-dev.pid" 2>/dev/null))"
[ -n "$PORT" ] && echo "  лог dev:    $DEVLOG"
echo
echo "Коммит:  scripts/git-safe-commit.sh --message-file <файл> -- <пути>"
echo "Push:    git push -u origin $BRANCH   (отсюда же)"
echo "Убрать:  scripts/wt-done.sh $NAME"
