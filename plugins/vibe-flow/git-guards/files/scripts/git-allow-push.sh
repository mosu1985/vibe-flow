#!/usr/bin/env bash
# git-allow-push.sh — разрешить отправку чужих коммитов.
#
# ЗАЧЕМ. pre-push отказывает, если в отправляемом наборе есть коммит, который
# эта сессия не создавала. Причина — авария 02.09.2026: пуш увёз на remote
# коммит соседней сессии, разрешения на который никто не спрашивал. То же
# случилось раньше с `2a2280f1`, который ждал согласования на деплой.
#
# Чужой коммит может быть и законным: сделан в worktree, а пушит основная
# сессия. Поэтому не запрет, а явный список: человек смотрит, что уезжает,
# и подтверждает.
#
#   scripts/git-allow-push.sh add <sha…>   — разрешить (с подтверждением)
#   scripts/git-allow-push.sh add --yes <sha…> — то же, ответ «да» флагом
#   scripts/git-allow-push.sh list         — что разрешено сейчас
#   scripts/git-allow-push.sh clear        — очистить список
set -eu

# --yes — ответ «да» для запуска через `!` в строке ввода Claude Code (stdin
# там не интерактивный). Агенту обхода не даёт: режим add из Bash-инструмента
# модели отклоняет PreToolUse-хук. Подробнее — в git-allow-delete.sh.
YES=0; ARGS=()
for a in "$@"; do case "$a" in --yes) YES=1 ;; *) ARGS+=("$a") ;; esac; done
set -- ${ARGS[@]+"${ARGS[@]}"}

COMMON=$(git rev-parse --git-common-dir)
case "$COMMON" in /*) ;; *) COMMON="$(cd "$COMMON" && pwd -P)" ;; esac
ALLOW="$COMMON/monitorex-locks/push-allow"
mkdir -p "$(dirname "$ALLOW")"
touch "$ALLOW"

# Убрать из списка то, что уже уехало: разрешение одноразовое по смыслу,
# иначе список копится и однажды разрешит совсем не то, что смотрели.
prune() {
    tmp="$ALLOW.tmp.$$"
    : > "$tmp"
    while read -r sha; do
        [ -n "$sha" ] || continue
        if ! git merge-base --is-ancestor "$sha" \
             "$(git for-each-ref --format='%(objectname)' refs/remotes | tr '\n' ' ' | awk '{print $1}')" 2>/dev/null; then
            echo "$sha" >> "$tmp"
        fi
    done < "$ALLOW"
    mv "$tmp" "$ALLOW"
}

case "${1:-list}" in
  list)
    prune 2>/dev/null || true
    if [ -s "$ALLOW" ]; then
        while read -r sha; do
            [ -n "$sha" ] || continue
            printf '  %s  %s\n' "$(git rev-parse --short "$sha" 2>/dev/null || echo "$sha")" \
                                "$(git log -1 --format=%s "$sha" 2>/dev/null || echo '(объект не найден)')"
        done < "$ALLOW"
    else
        echo "  (список пуст)"
    fi ;;

  clear) : > "$ALLOW"; echo "список очищен" ;;

  add)
    shift
    [ $# -gt 0 ] || { echo "нужен хотя бы один SHA"; exit 2; }
    echo "Будут разрешены к отправке:"
    for s in "$@"; do
        full=$(git rev-parse --verify "$s^{commit}" 2>/dev/null) || { echo "🔴 не коммит: $s"; exit 1; }
        printf '  %s  %s\n     автор: %s   Session-Id: %s\n' \
            "$(git rev-parse --short "$full")" "$(git log -1 --format=%s "$full")" \
            "$(git log -1 --format='%an' "$full")" \
            "$(git log -1 --format='%(trailers:key=Session-Id,valueonly)' "$full" | tr -d '\n')"
    done
    printf '\nЭто чужая работа. Отправлять её от своего имени? [да/нет] '
    if [ "$YES" = 1 ]; then echo "да (--yes)"
    else
        read -r a || { echo; echo "🔴 ответить нечем: ввод не с клавиатуры. Добавьте --yes к той же команде."; exit 1; }
        [ "$a" = "да" ] || { echo "отменено"; exit 1; }
    fi
    for s in "$@"; do git rev-parse --verify "$s^{commit}" >> "$ALLOW"; done
    echo "разрешено; список одноразовый — уехавшее вычищается автоматически" ;;

  *) echo "использование: git-allow-push.sh [add <sha…>|list|clear]"; exit 2 ;;
esac
