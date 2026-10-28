#!/usr/bin/env bash
# git-recovery.sh — жизненный цикл refs/monitorex/recovery/*.
# Там лежат коммиты, которые не встали в ветку из-за конфликта CAS.
# Без явного удаления они бессрочно держат деревья от сборки мусора.
set -eu
case "${1:-list}" in
  list)
    git for-each-ref --format='%(refname:short)  %(objectname:short)  %(committerdate:iso)  %(contents:subject)' refs/monitorex/recovery \
      | sed 's/^/  /' ; git for-each-ref refs/monitorex/recovery | grep -q . || echo "  (пусто)" ;;
  show) [ $# -ge 2 ] || { echo "нужен token"; exit 2; }; git show --stat "refs/monitorex/recovery/$2" ;;
  drop)
    [ $# -ge 2 ] || { echo "нужен token"; exit 2; }
    git show --stat "refs/monitorex/recovery/$2" | head -20
    printf '\nУдалить эту ссылку? Коммит станет недостижим. [да/нет] '
    read -r a; [ "$a" = "да" ] || { echo "отменено"; exit 1; }
    git update-ref -d "refs/monitorex/recovery/$2"; echo "удалено" ;;
  *) echo "использование: git-recovery.sh [list|show <token>|drop <token>]"; exit 2 ;;
esac
