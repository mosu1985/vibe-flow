#!/usr/bin/env bash
# git-confirm.sh <target> — разовая owner-отметка для обхода защиты.
#
# ЗАЧЕМ ОТДЕЛЬНЫМ ФАЙЛОМ, А НЕ ПЕРЕМЕННОЙ ОКРУЖЕНИЯ. Переменную вроде
# MONITOREX_NO_LOCK=1 агент выставит не задумываясь — это обход одной строкой.
# Отметка живёт 15 минут, привязана к конкретному случаю и ГАСИТСЯ после
# первого использования, поэтому её постановка — осознанное действие человека.
# Механика взята из session-coordination-kit (автор Pavlo Rudomotov).
#
#   scripts/git-confirm.sh commit    — разрешить один обычный git commit
#   scripts/git-confirm.sh status    — что стоит сейчас
#   scripts/git-confirm.sh clear     — снять
#   scripts/git-confirm.sh commit --yes — ответ «да» флагом (запуск через `!`)
set -eu

# --yes — для строки ввода Claude Code (`!`): stdin там не интерактивный.
# Агенту обхода не даёт: постановку отметки из Bash-инструмента модели
# отклоняет PreToolUse-хук. Подробнее — в git-allow-delete.sh.
YES=0; ARGS=()
for a in "$@"; do case "$a" in --yes) YES=1 ;; *) ARGS+=("$a") ;; esac; done
set -- ${ARGS[@]+"${ARGS[@]}"}
COMMON=$(git rev-parse --git-common-dir); case "$COMMON" in /*) ;; *) COMMON="$(cd "$COMMON" && pwd -P)";; esac
F="$COMMON/monitorex-locks/CONFIRM"
TTL=900
mkdir -p "$(dirname "$F")"

case "${1:-status}" in
  status)
    if [ -f "$F" ]; then
      age=$(( $(date +%s) - $(stat -f %m "$F") ))
      [ "$age" -lt "$TTL" ] && echo "отметка: $(cat "$F"), возраст ${age}с (живёт ${TTL}с)" \
                            || echo "отметка протухла (${age}с) — считается отсутствующей"
    else echo "отметки нет"; fi ;;
  clear) rm -f "$F"; echo "снято" ;;
  *)
    TARGET="$1"
    echo "Отметка разрешит ОДИН обход защиты для '$TARGET' в ближайшие $((TTL/60)) минут."
    echo "Она гасится после первого использования."
    printf 'Подтвердить? [да/нет] '
    if [ "$YES" = 1 ]; then echo "да (--yes)"
    else
        read -r a || { echo; echo "🔴 ответить нечем: ввод не с клавиатуры. Добавьте --yes к той же команде."; exit 1; }
        [ "$a" = "да" ] || { echo "отменено"; exit 1; }
    fi
    printf 'target=%s\nts=%s\n' "$TARGET" "$(date -u +%FT%TZ)" > "$F"
    echo "отметка поставлена: $TARGET" ;;
esac
