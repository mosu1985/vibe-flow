#!/usr/bin/env bash
# git-lock.sh — состояние и снятие локов набора. Авто-снятия нет намеренно:
# протухший лок сообщается человеку и ждёт его решения.
#
#   status   — что держится, кем, жив ли процесс, есть ли незавершённая транзакция
#   release  — снять по подтверждению; в фазе post-cas сначала чинит индекс
#   take     — взять commit-лок под служебную операцию (merge/rebase/cherry-pick)
#              ТОЛЬКО в linked worktree: pre-commit требует его при MERGE_HEAD
#   drop     — снять лок, взятый take этой же сессией
#
# take/drop — для агента: в своём worktree индекс свой, а лок нужен лишь
# затем, чтобы коммит слияния не двигал ссылки одновременно с чужим
# safe-commit. Держать лок только на время коммита: take → commit → drop.
set -eu
COMMON=$(git rev-parse --git-common-dir); case "$COMMON" in /*) ;; *) COMMON="$(cd "$COMMON" && pwd -P)";; esac
LOCKDIR="$COMMON/monitorex-locks"; LOCK="$LOCKDIR/commit"; JOURNAL="$LOCKDIR/journal"
IDXPATH=$(git rev-parse --git-path index); case "$IDXPATH" in /*) ;; *) IDXPATH="$(pwd -P)/$IDXPATH";; esac
IDXLOCK="$IDXPATH.lock"
field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null && echo "жив" || echo "МЁРТВ"; }
age()   { [ -f "$1" ] && echo "$(( ($(date +%s) - $(stat -f %m "$1")) ))с" || echo "-"; }

show() {
  echo "=== Локи ==="
  if [ -d "$LOCK" ] && [ "$(field "$LOCK/owner" purpose)" = "take" ]; then
    echo "commit-лок: занят через take   actor=$(field "$LOCK/owner" actor)  дерево=$(field "$LOCK/owner" worktree)  возраст $(age "$LOCK/owner")"
  elif [ -d "$LOCK" ]; then
    echo "commit-лок: занят   actor=$(field "$LOCK/owner" actor)  pid=$(field "$LOCK/owner" pid) ($(alive "$(field "$LOCK/owner" pid)"))  возраст $(age "$LOCK/owner")"
  else echo "commit-лок: свободен"; fi
  if [ -f "$IDXLOCK" ]; then
    echo "index.lock: занят   actor=$(field "$IDXLOCK" actor)  pid=$(field "$IDXLOCK" pid) ($(alive "$(field "$IDXLOCK" pid)"))  возраст $(age "$IDXLOCK")"
  else echo "index.lock: свободен"; fi
  if [ -f "$JOURNAL" ]; then
    echo
    echo "🔴 Незавершённая транзакция, фаза: $(field "$JOURNAL" phase)"
    echo "   ветка $(field "$JOURNAL" branch): $(field "$JOURNAL" old) → $(field "$JOURNAL" new)"
    [ "$(field "$JOURNAL" phase)" = "post-cas" ] && echo "   Ветка сдвинута, индекс НЕ синхронизирован — нужен release (починит)."
  fi
}

case "${1:-status}" in
  status) show ;;
  release)
    show; echo
    printf 'Снять локи? В фазе post-cas индекс будет приведён к новому HEAD. [да/нет] '
    read -r a; [ "$a" = "да" ] || { echo "отменено"; exit 1; }
    if [ -f "$JOURNAL" ] && [ "$(field "$JOURNAL" phase)" = "post-cas" ]; then
      NEW=$(field "$JOURNAL" new); TMP=$(mktemp -t monitorex-idxrepair)
      GIT_INDEX_FILE="$TMP" git read-tree "$NEW" && mv "$TMP" "$IDXPATH" && rm -f "$JOURNAL" \
        && echo "индекс приведён к $NEW" || { rm -f "$TMP"; echo "🔴 починка не удалась"; exit 1; }
    fi
    rm -f "$IDXLOCK"; rm -rf "$LOCK"; echo "локи сняты" ;;
  take)
    GD=$(git rev-parse --git-dir); case "$GD" in /*) ;; *) GD="$(cd "$GD" && pwd -P)";; esac
    [ "$GD" != "$COMMON" ] || { echo "🔴 take — только в linked worktree (scripts/wt-new.sh); в основном дереве — git-safe-commit.sh"; exit 1; }
    [ ! -f "$JOURNAL" ] || { echo "🔴 незавершённая транзакция — сначала status / release"; exit 1; }
    mkdir -p "$LOCKDIR"
    mkdir "$LOCK" 2>/dev/null || { show; echo; echo "🔴 commit-лок занят — подождите и повторите"; exit 1; }
    printf 'actor=%s\npid=\npurpose=take\nworktree=%s\n' "${CLAUDE_CODE_SESSION_ID:-${MONITOREX_ACTOR:-manual}}" "$(pwd -P)" > "$LOCK/owner"
    echo "commit-лок взят — сделайте коммит и сразу: scripts/git-lock.sh drop" ;;
  drop)
    [ -d "$LOCK" ] || { echo "commit-лок свободен"; exit 0; }
    ME="${CLAUDE_CODE_SESSION_ID:-${MONITOREX_ACTOR:-manual}}"
    if [ "$(field "$LOCK/owner" purpose)" != "take" ] || [ "$(field "$LOCK/owner" actor)" != "$ME" ]; then
      show; echo; echo "🔴 лок взят не через take этой сессии — снимать его здесь нельзя (release — человеком)"; exit 1
    fi
    rm -rf "$LOCK"; echo "commit-лок снят" ;;
  *) echo "использование: git-lock.sh [status|release|take|drop]"; exit 2 ;;
esac
