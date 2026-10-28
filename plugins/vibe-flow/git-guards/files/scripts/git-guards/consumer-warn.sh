#!/usr/bin/env bash
# consumer-warn.sh — предупреждение (НЕ отказ) о новом экспортирующем модуле,
# на который никто не ссылается. Закрывает часть аварии №3 «мёртвый код на
# проде»: typecheck принимает корректно типизированный код без потребителей.
# Блокировать нельзя — есть законные случаи (модуль под флагом, точка входа cron).
set -eu
COMMIT="$1"; shift
for p in "$@"; do
  case "$p" in lib/*|components/*) ;; *) continue ;; esac
  [ -f "$p" ] || continue
  git cat-file -e "$COMMIT^:$p" 2>/dev/null && continue      # файл не новый
  grep -qE '^export ' "$p" 2>/dev/null || continue
  base="${p%.*}"; stem="${base##*/}"
  if ! grep -rqE "from ['\"].*${stem}['\"]|require\(['\"].*${stem}" \
        --include='*.ts' --include='*.tsx' app lib components 2>/dev/null; then
    printf '⚠️  новый модуль без потребителей: %s\n' "$p" >&2
    printf '   Подключён ли он к роуту/компоненту/крону? (авария №3: мёртвый код на проде)\n' >&2
  fi
done
