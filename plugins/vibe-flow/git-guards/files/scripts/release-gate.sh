#!/usr/bin/env bash
# release-gate.sh — финальный гейт перед отправкой кода: вердикт ревьюера Opus.
#
# ЗАЧЕМ. Ревьюеры смотрят ПЛАН, а ошибки живут в КОДЕ и данных: предикат на
# неверном поле iiko прошёл девять проходов ревью плана и доехал до прода.
# Код же, написанный субагентами на Sonnet/Haiku, после реализации не смотрел
# никто. Гейт закрывает эту дыру: pre-push не отправит ветку, пока агент
# `release-gate` (Opus) не прочитал её дифф целиком и не поставил вердикт.
#
# Вердикт привязан к ДЕРЕВУ коммита (HEAD^{tree}), а не к SHA: пересборка
# коммита с тем же содержимым (safe-commit, смена сообщения) вердикт не теряет,
# а любая правка содержимого — теряет, и ревью нужно заново.
#
#   scripts/release-gate.sh scope              — что ревьюить: база, коммиты, файлы
#   scripts/release-gate.sh status             — есть ли вердикт для HEAD
#   scripts/release-gate.sh pass --head <sha> --report <f>
#                                              — записать ✅ (только агент release-gate)
#   scripts/release-gate.sh override --yes     — разовый обход человеком (через `!`)
set -eu

YES=0; REPORT=""; REVIEWED=""; ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
      --yes) YES=1 ;;
      --report) shift; REPORT="${1:-}" ;;
      --head) shift; REVIEWED="${1:-}" ;;
      *) ARGS+=("$1") ;;
    esac
    shift
done
set -- ${ARGS[@]+"${ARGS[@]}"}

COMMON=$(git rev-parse --git-common-dir)
case "$COMMON" in /*) ;; *) COMMON="$(cd "$COMMON" && pwd -P)" ;; esac
DIR="$COMMON/monitorex-locks/release-gate"
mkdir -p "$DIR"

GG_PROTECTED="main"
GG_RELEASE_GATE_SKIP="*.md"
TOP=$(git rev-parse --show-toplevel)
if [ -f "$TOP/.gitguards.conf" ]; then . "$TOP/.gitguards.conf"; fi

# origin, если он есть: pre-push получает remote явно, и при втором remote,
# который по алфавиту раньше, scope/status считали бы другую базу.
if git remote | grep -qx origin; then REMOTE=origin; else REMOTE=$(git remote | head -1); fi
BASE_REF="refs/remotes/$REMOTE/$GG_PROTECTED"

# Маски «ревью не нужно» — политика репозитория, как и в pre-push: берём из
# конфига защищённой ветки на remote, нет его — из основного дерева. Конфиг
# ветки на маску не влияет, иначе SKIP="*" в нём отключил бы гейт.
skip_policy() {
    grep -E '^GG_RELEASE_GATE_SKIP=' | tail -1 \
        | sed -e 's/^GG_RELEASE_GATE_SKIP=//' -e "s/^[\"']//" -e "s/[\"']\$//"
}
GG_RELEASE_GATE_SKIP="*.md"
if gpol=$(git show "$BASE_REF:.gitguards.conf" 2>/dev/null); then
    if printf '%s\n' "$gpol" | grep -q '^GG_RELEASE_GATE_SKIP='; then
        GG_RELEASE_GATE_SKIP=$(printf '%s\n' "$gpol" | skip_policy)
    fi
elif [ -f "$(dirname "$COMMON")/.gitguards.conf" ] \
     && grep -q '^GG_RELEASE_GATE_SKIP=' "$(dirname "$COMMON")/.gitguards.conf"; then
    GG_RELEASE_GATE_SKIP=$(skip_policy < "$(dirname "$COMMON")/.gitguards.conf")
fi
HEAD_SHA=$(git rev-parse HEAD)
TREE=$(git rev-parse 'HEAD^{tree}')

base() {
    git rev-parse --verify -q "$BASE_REF" >/dev/null \
        || { echo "🔴 нет $BASE_REF — сделайте git fetch" >&2; exit 1; }
    git merge-base "$BASE_REF" HEAD
}

# Файлы, требующие ревью: всё, кроме масок GG_RELEASE_GATE_SKIP (документация).
# Логика совпадает с pre-push — расхождение дало бы «ревью не нужно» здесь
# и отказ там.
review_files() {
    b=$(base)
    # --no-renames: иначе переименование lib/x.ts → docs/x.md видно только
    # новым путём и сошло бы за «только документацию», хотя это удаление кода.
    # quotePath=false: не-ASCII имя иначе приходит в кавычках и мимо маски.
    git -c core.quotePath=false diff --no-renames --name-only "$b" HEAD | while IFS= read -r f; do
        [ -n "$f" ] || continue
        skip=0
        set -f
        for pat in $GG_RELEASE_GATE_SKIP; do
            case "$f" in ($pat) skip=1 ;; esac
        done
        set +f
        [ "$skip" = 1 ] || printf '%s\n' "$f"
    done
}

# Вердикт настоящий, только если в нём verdict= и head=, чьё дерево совпадает
# с HEAD. Та же проверка, что в pre-push: пустой файл мимо скрипта — не вердикт.
verdict_valid() {
    f="$DIR/$TREE"
    [ -f "$f" ] && grep -qE '^verdict=(pass|override)$' "$f" || return 1
    h=$(sed -n 's/^head=//p' "$f" | head -1)
    [ -n "$h" ] && [ "$(git rev-parse -q --verify "$h^{tree}" 2>/dev/null)" = "$TREE" ]
}

clean_or_die() {
    # Ревьюер читает закоммиченное. Незакоммиченная правка в дереве означала
    # бы, что он видел не то, что уедет.
    if ! git diff --quiet HEAD -- 2>/dev/null; then
        echo "🔴 в рабочем дереве есть незакоммиченные изменения — вердикт относился бы не к HEAD:"
        git status --short | grep -v '^??' | sed 's/^/     /'
        exit 1
    fi
}

case "${1:-status}" in
  scope)
    b=$(base)
    echo "база:    $(git rev-parse --short "$b")  ($BASE_REF)"
    echo "HEAD:    $(git rev-parse --short HEAD)  tree $(git rev-parse --short "$TREE")"
    echo ""
    echo "коммиты:"
    git log --format='  %h  %s' "$b..HEAD"
    echo ""
    files=$(review_files)
    if [ -z "$files" ]; then
        echo "файлов, требующих ревью, нет (только ${GG_RELEASE_GATE_SKIP}) — гейт не нужен"
    else
        echo "файлы на ревью:"
        git diff --stat "$b" HEAD -- $files | sed 's/^/  /'
        echo ""
        echo "дифф целиком: git diff $(git rev-parse --short "$b") HEAD"
    fi ;;

  status)
    # base() вне подстановки: внутри $(…) bash 3.2 глотает её отказ, и без
    # origin/main статус врал бы «гейт не нужен».
    base >/dev/null
    if verdict_valid; then
        echo "✅ вердикт есть для HEAD $(git rev-parse --short HEAD):"
        sed 's/^/     /' "$DIR/$TREE"
    elif [ -z "$(review_files)" ]; then
        echo "⚪️ гейт не нужен: в диффе только ${GG_RELEASE_GATE_SKIP}"
    else
        echo "🔴 вердикта для HEAD $(git rev-parse --short HEAD) нет — нужен агент release-gate"
        exit 1
    fi ;;

  pass)
    [ -n "$REPORT" ] && [ -s "$REPORT" ] \
        || { echo "🔴 нужен непустой --report <файл> с отчётом ревью"; exit 2; }
    # Вердикт — на тот HEAD, который ревьюер ЧИТАЛ, а не на текущий. Пока
    # ревью идёт (xhigh — минуты), в дерево может приехать новый коммит, и
    # без сверки вердикт лёг бы на содержимое, которого никто не видел.
    [ -n "$REVIEWED" ] || { echo "🔴 нужен --head <sha>, с которого начато ревью"; exit 2; }
    # Только полный SHA: `--head HEAD` сверял бы HEAD с самим собой и
    # пропускал коммит, приехавший во время ревью.
    printf '%s' "$REVIEWED" | grep -qE '^[0-9a-f]{40}([0-9a-f]{24})?$' \
        || { echo "🔴 --head — полный SHA коммита (git rev-parse HEAD в начале ревью), не «$REVIEWED»"; exit 2; }
    reviewed_full=$(git rev-parse --verify -q "$REVIEWED^{commit}") \
        || { echo "🔴 --head $REVIEWED — не коммит"; exit 2; }
    if [ "$reviewed_full" != "$HEAD_SHA" ]; then
        echo "🔴 HEAD сдвинулся во время ревью: читали $(git rev-parse --short "$reviewed_full"), сейчас $(git rev-parse --short HEAD)."
        echo "   Вердикт не записан — нужен новый круг ревью на текущий HEAD."
        exit 1
    fi
    clean_or_die
    {
        printf 'verdict=pass\nhead=%s\nbase=%s\nts=%s\nsession=%s\n' \
            "$HEAD_SHA" "$(base)" "$(date -u +%FT%TZ)" "${CLAUDE_CODE_SESSION_ID:-}"
        echo "---"
        cat "$REPORT"
    } > "$DIR/$TREE.tmp.$$"
    mv "$DIR/$TREE.tmp.$$" "$DIR/$TREE"
    # Вердикты старше 30 дней никому не нужны: такие деревья давно в main.
    find "$DIR" -type f -mtime +30 -delete 2>/dev/null || true
    echo "✅ вердикт записан для HEAD $(git rev-parse --short HEAD) (tree $(git rev-parse --short "$TREE"))" ;;

  override)
    clean_or_die
    echo "Обход разрешит отправить HEAD $(git rev-parse --short HEAD) БЕЗ ревью release-gate:"
    git log --format='  %h  %s' "$(base)..HEAD"
    printf '\nОтправлять непроверенный код? [да/нет] '
    if [ "$YES" = 1 ]; then echo "да (--yes)"
    else
        read -r a || { echo; echo "🔴 ответить нечем: ввод не с клавиатуры. Добавьте --yes к той же команде."; exit 1; }
        [ "$a" = "да" ] || { echo "отменено"; exit 1; }
    fi
    printf 'verdict=override\nhead=%s\nts=%s\n' "$HEAD_SHA" "$(date -u +%FT%TZ)" > "$DIR/$TREE"
    echo "обход записан для этого содержимого; любая правка его снимет" ;;

  *) echo "использование: release-gate.sh [scope|status|pass --head <sha> --report <f>|override]"; exit 2 ;;
esac
