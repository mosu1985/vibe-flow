#!/usr/bin/env bash
# wt-status.sh — что в репозитории НЕ доделано.
#
# ЗАЧЕМ. Защита набора строилась против того, чтобы сессия утащила ЧУЖИЕ
# изменения, и с этим справляется. Но был противоположный пробел: сессия не
# видела СВОЕЙ прошлой работы. `CLAUDE.md` предписывает начинать с
# `wt-new.sh <имя-задачи>`, шага «посмотри, не начата ли эта работа» в процессе
# не было вовсе — и вторая сессия по той же теме, назвав задачу чуть иначе,
# отпочковывалась от main и писала всё заново. Проверено 10.09.2026: файл,
# сделанный в прошлой сессии, в новом дереве не виден, предупреждения нет.
#
#   scripts/wt-status.sh            — отчёт для человека
#   scripts/wt-status.sh --hook     — для SessionStart: молчит, когда всё доделано
#   scripts/wt-status.sh --names    — только имена веток (для wt-new.sh)
set -eu

MODE="${1:-report}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

GG_BRANCH_PREFIX="wt/"
GG_PROTECTED="main"
[ -f "$ROOT/.gitguards.conf" ] && . "$ROOT/.gitguards.conf"

# База сравнения: и локальная главная ветка, и её слепок на remote. Работа,
# доехавшая до main любым путём, доделанной считается — в том числе если
# въехала с переписанным SHA и сама ветка выглядит отставшей.
BASES=""
git rev-parse --verify -q "refs/heads/$GG_PROTECTED" >/dev/null 2>&1 && BASES="$BASES refs/heads/$GG_PROTECTED"
git rev-parse --verify -q "refs/remotes/origin/$GG_PROTECTED" >/dev/null 2>&1 && BASES="$BASES refs/remotes/origin/$GG_PROTECTED"
[ -n "$BASES" ] || exit 0

# Карта «ветка → её рабочее дерево»
MAP=$(git worktree list --porcelain 2>/dev/null | awk '
    /^worktree /{w=substr($0, 10)} /^branch /{sub("refs/heads/","",$2); print $2"\t"w}')

LINES=""
COUNT=0
for ref in $(git for-each-ref --format='%(refname:short)' "refs/heads/$GG_BRANCH_PREFIX*" 2>/dev/null); do
    n=$(git rev-list --count "$ref" --not $BASES 2>/dev/null || echo 0)
    [ "$n" = "0" ] && continue
    COUNT=$((COUNT+1))
    # 🔴 «Не доехало до main» и «не существует больше нигде» — разные тревоги.
    # Первое значит «не доделано», второе — «единственная копия на этом диске».
    # Показывать только первое означало бы уравнять брошенную ветку, лежащую на
    # origin, с работой, которую потеряет отказ диска.
    nowhere=$(git rev-list --count "$ref" --not --remotes $BASES 2>/dev/null || echo 0)
    when=$(git log -1 --format='%ad' --date=format:'%d.%m' "$ref" 2>/dev/null)
    w=$(printf '%s\n' "$MAP" | awk -F'\t' -v b="$ref" '$1==b{print $2}')
    if [ -n "$w" ]; then
        d=$(git -C "$w" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        extra="дерево: $(basename "$w")"
        [ "$d" != "0" ] && extra="$extra · незакоммичено: $d"
    else
        extra="дерева нет → scripts/wt-new.sh --resume $ref"
    fi
    risk=""
    [ "$nowhere" != "0" ] && risk=" 🔴 $nowhere нет НИГДЕ"
    LINES="$LINES$(printf '   %-32s %2s не в %s · %s · %s%s' "$ref" "$n" "$GG_PROTECTED" "$when" "$extra" "$risk")
"
done

case "$MODE" in
  --names)
    for ref in $(git for-each-ref --format='%(refname:short)' "refs/heads/$GG_BRANCH_PREFIX*" 2>/dev/null); do
        n=$(git rev-list --count "$ref" --not $BASES 2>/dev/null || echo 0)
        [ "$n" != "0" ] && printf '%s\n' "$ref"
    done
    ;;
  --hook)
    # 🔴 Молчание, когда всё доделано: хук выполняется в КАЖДОЙ сессии, и
    # постоянный шум сделал бы его невидимым ровно тогда, когда он нужен.
    [ "$COUNT" = "0" ] && exit 0
    printf '🔶 В репозитории есть незавершённая работа (%s ветк.):\n' "$COUNT"
    printf '%s' "$LINES"
    printf '   Прежде чем заводить новое дерево — проверьте, не начата ли задача здесь.\n'
    ;;
  *)
    if [ "$COUNT" = "0" ]; then
        echo "Незавершённых веток нет — вся работа в $GG_PROTECTED."
    else
        printf '🔶 Незавершённая работа (%s ветк.):\n' "$COUNT"
        printf '%s' "$LINES"
    fi
    ;;
esac
