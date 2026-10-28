#!/usr/bin/env bash
# test-git-guards.sh — матрица A5. Всё гоняется во ВРЕМЕННЫХ репозиториях
# (mktemp), боевой репозиторий не трогается ни на одном шаге.
#
# Запуск: bash scripts/test-git-guards.sh
# Код возврата: 0 — всё зелено, 1 — есть провал.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "  FAIL - $1: ${2:-}"; }

mkrepo() {                     # $1 = путь
    mkdir -p "$1"; git -C "$1" init -q
    git -C "$1" config user.email t@t; git -C "$1" config user.name t
    echo v1 > "$1/a.txt"; echo v1 > "$1/b.txt"
    printf '#!/bin/sh\necho hi\n' > "$1/s.sh"; chmod +x "$1/s.sh"
    mkdir -p "$1/дир"; echo "рус" > "$1/дир/файл с пробелом.txt"
    git -C "$1" add -A; git -C "$1" commit -qm init
}

commit() {                     # $1 = репо, $2 = сообщение, далее пути
    local repo="$1" msg="$2"; shift 2
    printf '%s\n' "$msg" > "$repo/.msg"
    ( cd "$repo" && CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=test MONITOREX_SKIP_TESTS=1 \
        bash "$ROOT/scripts/git-safe-commit.sh" --message-file .msg -- "$@" ) 2>&1
}

echo "== verify_staged.py =="
V() { python3 "$ROOT/scripts/git-guards/verify_staged.py" "$@"; }
printf 'a.txt\0' | V --expect a.txt b.txt >/dev/null 2>&1 && ok "подмножество ожидаемого — allow" || bad "подмножество — allow"
printf 'a.txt\0чужой.ts\0' | V --expect a.txt >/dev/null 2>&1 && bad "лишний путь — deny" "получен allow" || ok "лишний путь — deny"
printf 'lib/x/y.ts\0' | V --expect lib >/dev/null 2>&1 && ok "путь внутри каталога-pathspec — allow" || bad "каталог-pathspec"
printf 'дир/файл с пробелом.txt\0' | V --expect 'дир/файл с пробелом.txt' >/dev/null 2>&1 && ok "кириллица и пробелы" || bad "кириллица и пробелы"
printf 'a.txt\0' | V --intersects a.txt b.txt >/dev/null 2>&1 && ok "пересечение найдено" || bad "пересечение найдено"
printf 'c.txt\0' | V --intersects a.txt >/dev/null 2>&1 && bad "пересечения нет — rc=1" "вернул 0" || ok "пересечения нет — rc=1"

echo "== safe-commit: базовый путь =="
R="$TMP/r1"; mkrepo "$R"
echo v2 > "$R/a.txt"; echo "чужое" > "$R/b.txt"          # b.txt правит «сосед»
out=$(commit "$R" "правка a" a.txt); rc=$?
[ $rc -eq 0 ] && ok "коммит одного файла проходит" || bad "коммит проходит" "$out"
names=$(git -C "$R" show --name-only --format='' HEAD)
[ "$names" = "a.txt" ] && ok "в коммите ровно запрошенный файл (чужой b.txt не попал)" || bad "состав коммита" "$names"
git -C "$R" log -1 --format='%(trailers:key=Session-Id)' | grep -q test && ok "трейлер Session-Id проставлен" || bad "трейлер Session-Id"
[ -z "$(git -C "$R" status --porcelain a.txt)" ] && ok "после коммита индекс синхронизирован (a.txt чист)" || bad "индекс синхронизирован" "$(git -C "$R" status --short)"
[ "$(cat "$R/b.txt")" = "чужое" ] && ok "чужая правка на диске цела" || bad "чужая правка цела"
[ -z "$(ls -A "$(git -C "$R" rev-parse --absolute-git-dir)/monitorex-locks" 2>/dev/null | grep -v '^$')" ] && ok "локи сняты после успеха" || bad "локи сняты после успеха"
[ ! -f "$(git -C "$R" rev-parse --absolute-git-dir)/index.lock" ] && ok "index.lock снят" || bad "index.lock снят"

echo "== safe-commit: отказы =="
R2="$TMP/r2"; mkrepo "$R2"
echo v2 > "$R2/a.txt"; git -C "$R2" add a.txt              # «сосед» застейджил
echo v2 > "$R2/b.txt"
out=$(commit "$R2" "правка b" b.txt); rc=$?
[ $rc -ne 0 ] && ok "чужое застейдженное — отказ ДО сдвига ветки" || bad "отказ при грязном индексе" "$out"
[ "$(git -C "$R2" rev-parse HEAD)" = "$(git -C "$R2" rev-parse HEAD)" ] && \
  [ "$(git -C "$R2" log --oneline | wc -l | tr -d ' ')" = "1" ] && ok "ветка не двинулась при отказе" || bad "ветка не двинулась"
git -C "$R2" ls-files -s a.txt | grep -q . && ok "чужой staged-снимок уцелел" || bad "staged-снимок уцелел"
[ ! -f "$(git -C "$R2" rev-parse --absolute-git-dir)/index.lock" ] && ok "index.lock снят после отказа" || bad "index.lock снят после отказа"

R3="$TMP/r3"; mkrepo "$R3"
out=$(commit "$R3" "нечего" a.txt); rc=$?
[ $rc -ne 0 ] && ok "нечего коммитить — отказ" || bad "нечего коммитить" "$out"

R4="$TMP/r4"; mkrepo "$R4"; echo v2 > "$R4/a.txt"
printf 'msg\n' > "$R4/.msg"
out=$( cd "$R4" && MONITOREX_SKIP_TESTS=1 MONITOREX_ACTOR= CLAUDE_CODE_SESSION_ID= \
       bash "$ROOT/scripts/git-safe-commit.sh" --message-file .msg -- a.txt 2>&1 ); rc=$?
[ $rc -ne 0 ] && ok "пустой ACTOR — отказ (fail-closed)" || bad "пустой ACTOR — отказ" "$out"

out=$( cd "$R4" && MONITOREX_ACTOR=t MONITOREX_SKIP_TESTS=1 \
       bash "$ROOT/scripts/git-safe-commit.sh" a.txt 2>&1 ); rc=$?
[ $rc -ne 0 ] && ok "путь без --message-file — отказ" || bad "CLI: путь без --message-file"

echo "== safe-commit: режимы, кириллица, удаление =="
R5="$TMP/r5"; mkrepo "$R5"
printf '#!/bin/sh\necho v2\n' > "$R5/s.sh"
echo "рус2" > "$R5/дир/файл с пробелом.txt"
out=$(commit "$R5" "exec+кириллица" s.sh "дир/файл с пробелом.txt"); rc=$?
[ $rc -eq 0 ] && ok "исполняемый файл и путь с кириллицей коммитятся" || bad "exec+кириллица" "$out"
[ "$(git -C "$R5" ls-files -s s.sh | cut -d' ' -f1)" = "100755" ] && ok "режим 100755 сохранён в индексе" || bad "режим 100755"
rm "$R5/b.txt"
out=$(commit "$R5" "удаление" b.txt); rc=$?
[ $rc -eq 0 ] && ok "удаление файла коммитится" || bad "удаление файла" "$out"
git -C "$R5" show --name-status --format='' HEAD | grep -q '^D' && ok "удаление записано как D" || bad "удаление записано как D"

echo "== safe-commit: .gitignore =="
R8="$TMP/r8"; mkrepo "$R8"
mkdir -p "$R8/ign"; echo v1 > "$R8/ign/tracked.md"
git -C "$R8" add ign/tracked.md; git -C "$R8" commit -qm "отслеживаемый в будущем игнорируемом каталоге"
echo "ign/" > "$R8/.gitignore"; git -C "$R8" add .gitignore; git -C "$R8" commit -qm gitignore
echo v2 > "$R8/ign/tracked.md"
out=$(commit "$R8" "правка отслеживаемого" ign/tracked.md); rc=$?
[ $rc -eq 0 ] && ok "отслеживаемый файл в игнорируемом каталоге коммитится" || bad "отслеживаемый в игнорируемом" "$out"
git -C "$R8" show --name-only --format='' HEAD | grep -qx 'ign/tracked.md' && ok "в коммите правка отслеживаемого файла" || bad "состав коммита ign/" "$(git -C "$R8" show --name-only --format='' HEAD)"
echo new > "$R8/ign/new.md"
out=$(commit "$R8" "новый игнорируемый" ign/new.md); rc=$?
[ $rc -ne 0 ] && ok "новый игнорируемый файл по-прежнему отклоняется" || bad "новый игнорируемый — отказ" "$out"
git -C "$R8" ls-tree -r --name-only HEAD | grep -qx 'ign/new.md' && bad "новый игнорируемый не попал в дерево" "попал" || ok "новый игнорируемый не попал в дерево"

echo "== CAS: конфликт и recovery-ref =="
R6="$TMP/r6"; mkrepo "$R6"
# сосед двигает ветку прямо перед CAS — эмулируем через хук на середине:
# проще проверить примитив напрямую
A=$(git -C "$R6" rev-parse HEAD)
echo x > "$R6/c.txt"; git -C "$R6" add c.txt; git -C "$R6" commit -qm neighbour
echo v2 > "$R6/a.txt"
IDXF=$(mktemp -t idx); GIT_INDEX_FILE="$IDXF" git -C "$R6" read-tree "$A"
GIT_INDEX_FILE="$IDXF" git -C "$R6" add a.txt
TREE=$(GIT_INDEX_FILE="$IDXF" git -C "$R6" write-tree)
N=$(echo m | git -C "$R6" commit-tree "$TREE" -p "$A")
git -C "$R6" update-ref refs/heads/main "$N" "$A" 2>/dev/null && bad "CAS отвергает устаревший old" "прошёл" || ok "CAS отвергает устаревший old"
git -C "$R6" cat-file -t "$N" >/dev/null 2>&1 && ok "объект коммита пережил отказ CAS" || bad "объект пережил отказ"
rm -f "$IDXF"

echo "== pre-commit: политика по дереву =="
R7="$TMP/r7"; mkrepo "$R7"
HOOK="$ROOT/githooks/pre-commit"
out=$( cd "$R7" && sh "$HOOK" 2>&1 ); rc=$?
[ $rc -ne 0 ] && ok "обычный commit в основном дереве — отказ" || bad "обычный commit — отказ" "$out"
echo "$out" | grep -q 'git-safe-commit' && ok "отказ подсказывает safe-commit" || bad "подсказка в отказе"
git -C "$R7" worktree add -q "$TMP/r7-wt" -b wtb >/dev/null 2>&1
out=$( cd "$TMP/r7-wt" && sh "$HOOK" 2>&1 )
if echo "$out" | grep -q 'запрещён'; then bad "worktree не блокируется политикой" "$out"; else ok "в linked worktree commit не блокируется политикой"; fi

echo "== git-lock take/drop: лок под merge в своём worktree =="
GL="$ROOT/scripts/git-lock.sh"
out=$( cd "$R7" && CLAUDE_CODE_SESSION_ID=s1 bash "$GL" take 2>&1 ); rc=$?
[ $rc -ne 0 ] && ok "take в основном дереве — отказ" || bad "take в основном дереве — отказ" "$out"
out=$( cd "$TMP/r7-wt" && CLAUDE_CODE_SESSION_ID=s1 bash "$GL" take 2>&1 ); rc=$?
[ $rc -eq 0 ] && [ -d "$R7/.git/monitorex-locks/commit" ] && ok "take в worktree — лок взят" || bad "take в worktree" "$out"
out=$( cd "$TMP/r7-wt" && CLAUDE_CODE_SESSION_ID=s2 bash "$GL" take 2>&1 ); rc=$?
[ $rc -ne 0 ] && ok "повторный take при занятом локе — отказ" || bad "повторный take — отказ" "$out"
git -C "$TMP/r7-wt" merge -q --no-ff --no-commit HEAD >/dev/null 2>&1 || true
printf '%s\n' "$(git -C "$TMP/r7-wt" rev-parse HEAD)" > "$(git -C "$TMP/r7-wt" rev-parse --git-path MERGE_HEAD)"
out=$( cd "$TMP/r7-wt" && sh "$HOOK" 2>&1 ); rc=$?
[ $rc -eq 0 ] && ok "pre-commit при MERGE_HEAD с локом take — пропуск" || bad "MERGE_HEAD с локом" "$out"
rm -f "$(git -C "$TMP/r7-wt" rev-parse --git-path MERGE_HEAD)"
out=$( cd "$TMP/r7-wt" && CLAUDE_CODE_SESSION_ID=s2 bash "$GL" drop 2>&1 ); rc=$?
[ $rc -ne 0 ] && [ -d "$R7/.git/monitorex-locks/commit" ] && ok "drop чужой сессией — отказ" || bad "drop чужой сессией" "$out"
out=$( cd "$TMP/r7-wt" && CLAUDE_CODE_SESSION_ID=s1 bash "$GL" drop 2>&1 ); rc=$?
[ $rc -eq 0 ] && [ ! -d "$R7/.git/monitorex-locks/commit" ] && ok "drop своей сессией — лок снят" || bad "drop своей сессией" "$out"
mkdir -p "$R7/.git/monitorex-locks/commit"; printf 'actor=safe\npid=1\n' > "$R7/.git/monitorex-locks/commit/owner"
out=$( cd "$TMP/r7-wt" && CLAUDE_CODE_SESSION_ID=safe bash "$GL" drop 2>&1 ); rc=$?
[ $rc -ne 0 ] && ok "drop лока safe-commit (не take) — отказ" || bad "drop не-take лока" "$out"
rm -rf "$R7/.git/monitorex-locks/commit"

echo "== одноразовая отметка (git-confirm) =="
R9="$TMP/r9"; mkrepo "$R9"
CONF="$R9/.git/monitorex-locks/CONFIRM"
mkdir -p "$(dirname "$CONF")"
out=$( cd "$R9" && sh "$HOOK" 2>&1 ); rc=$?
[ $rc -ne 0 ] && ok "без отметки — отказ" || bad "без отметки — отказ"
printf 'target=commit\nts=x\n' > "$CONF"
out=$( cd "$R9" && sh "$HOOK" 2>&1 )
echo "$out" | grep -q 'запрещён' && bad "со свежей отметкой — пропуск" "$out" || ok "со свежей отметкой — пропуск"
[ ! -f "$CONF" ] && ok "отметка погашена после использования (одноразовая)" || bad "отметка погашена"
printf 'target=push\nts=x\n' > "$CONF"
out=$( cd "$R9" && sh "$HOOK" 2>&1 )
echo "$out" | grep -q 'запрещён' && ok "отметка с ЧУЖИМ target не подходит" || bad "чужой target не подходит" "$out"
touch -t 202001010000 "$CONF"
out=$( cd "$R9" && sh "$HOOK" 2>&1 )
echo "$out" | grep -q 'запрещён' && ok "протухшая отметка не действует" || bad "протухшая отметка" "$out"
rm -f "$CONF"

echo "== подтверждение человеком: клавиатура, пустой ввод, --yes =="
# Запуск через `!` в Claude Code идёт без интерактивного stdin: read получает EOF.
# Раньше скрипт молча выходил с rc=1 — вопрос виден, ответить нечем, отметки нет.
DEL="$R9/.git/monitorex-locks/delete-allow"
PUSHL="$R9/.git/monitorex-locks/push-allow"
R9SHA=$(git -C "$R9" rev-parse HEAD)
for spec in "git-confirm.sh|commit|$CONF" "git-allow-delete.sh|add a.txt|$DEL" "git-allow-push.sh|add $R9SHA|$PUSHL"; do
    s=${spec%%|*}; rest=${spec#*|}; args=${rest%%|*}; mark=${rest#*|}
    rm -f "$mark"
    out=$( cd "$R9" && bash "$ROOT/scripts/$s" $args < /dev/null 2>&1 ); rc=$?
    { [ $rc -ne 0 ] && echo "$out" | grep -q -- '--yes' && [ ! -s "$mark" ]; } \
        && ok "$s: пустой ввод — отказ с подсказкой --yes, отметки нет" || bad "$s: пустой ввод" "$out"
    out=$( cd "$R9" && echo нет | bash "$ROOT/scripts/$s" $args 2>&1 ); rc=$?
    { [ $rc -ne 0 ] && [ ! -s "$mark" ]; } && ok "$s: ответ «нет» — отметки нет" || bad "$s: ответ «нет»" "$out"
    out=$( cd "$R9" && echo да | bash "$ROOT/scripts/$s" $args 2>&1 ); rc=$?
    { [ $rc -eq 0 ] && [ -s "$mark" ]; } && ok "$s: ответ «да» — отметка стоит" || bad "$s: ответ «да»" "$out"
    rm -f "$mark"
    out=$( cd "$R9" && bash "$ROOT/scripts/$s" $args --yes < /dev/null 2>&1 ); rc=$?
    { [ $rc -eq 0 ] && [ -s "$mark" ]; } && ok "$s: --yes без клавиатуры — отметка стоит" || bad "$s: --yes" "$out"
    rm -f "$mark"
done
out=$( cd "$R9" && bash "$ROOT/scripts/git-allow-delete.sh" add --yes a.txt b.txt < /dev/null 2>&1 )
[ "$(cat "$DEL" 2>/dev/null)" = "$(printf 'a.txt\nb.txt')" ] && ok "--yes не попадает в список путей" || bad "--yes в списке путей" "$(cat "$DEL" 2>/dev/null)"
rm -f "$DEL"

echo "== pre-push: ref-матрица =="
PP="$ROOT/githooks/pre-push"
R8="$TMP/r8"; mkrepo "$R8"
REMOTE="$TMP/remote.git"; git init -q --bare "$REMOTE"
git -C "$R8" remote add origin "$REMOTE"
git -C "$R8" push -q origin main 2>/dev/null
R8GIT="$R8/.git"
mkdir -p "$R8GIT/monitorex-hooks"
cp "$PP" "$R8GIT/monitorex-hooks/pre-push"
git -C "$R8" config core.hooksPath "$R8GIT/monitorex-hooks"

RSHA=$(git -C "$R8" rev-parse origin/main)
run_pp() { ( cd "$R8" && printf '%s\n' "$1" | sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 ); }

# удаление main
out=$(run_pp "refs/heads/main 0000000000000000000000000000000000000000 refs/heads/main $RSHA"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'Удаление защищённой' && ok "удаление main — отказ" || bad "удаление main — отказ" "$out"
# перезапись тега
out=$(run_pp "refs/tags/v1 $RSHA refs/tags/v1 $RSHA"); rc=$?
[ $rc -ne 0 ] && ok "перезапись тега — отказ" || bad "перезапись тега — отказ" "$out"
# push в непонятный ref
out=$(run_pp "refs/notes/x $RSHA refs/notes/x 0000000000000000000000000000000000000000"); rc=$?
[ $rc -ne 0 ] && ok "refs/notes — fail-closed отказ" || bad "refs/notes — отказ" "$out"
# не-fast-forward
echo diverged > "$R8/a.txt"; git -C "$R8" add a.txt; git -C "$R8" commit -qm div
DIV=$(git -C "$R8" rev-parse HEAD)
git -C "$R8" reset -q --hard "$RSHA"
echo other > "$R8/a.txt"; git -C "$R8" add a.txt; git -C "$R8" commit -qm other
out=$(run_pp "refs/heads/main $DIV refs/heads/main $(git -C "$R8" rev-parse HEAD)"); rc=$?
[ $rc -ne 0 ] && ok "не-fast-forward — отказ" || bad "не-fast-forward — отказ" "$out"
# удаление файла в пуше в main
git -C "$R8" reset -q --hard "$RSHA"
git -C "$R8" rm -q b.txt; git -C "$R8" commit -qm "снос b.txt"
DELSHA=$(git -C "$R8" rev-parse HEAD)
mkdir -p "$R8GIT/monitorex-locks"; echo "$DELSHA" > "$R8GIT/monitorex-locks/push-allow"
out=$(run_pp "refs/heads/main $DELSHA refs/heads/main $RSHA"); rc=$?
rm -f "$R8GIT/monitorex-locks/push-allow"
[ $rc -ne 0 ] && echo "$out" | grep -q 'УДАЛЯЕТ файлы' && ok "push с удалением файлов в main — отказ" || bad "push с удалением — отказ" "$out"
# --- владение коммитами ---
git -C "$R8" config core.hooksPath "$R8GIT/monitorex-hooks"
git -C "$R8" reset -q --hard "$RSHA"
printf 'свой\n\nSession-Id: acme-session\n' > "$R8/.m"
echo own > "$R8/a.txt"; git -C "$R8" add a.txt
git -C "$R8" commit -q -F "$R8/.m" --no-verify
MINE=$(git -C "$R8" rev-parse HEAD)
out=$( cd "$R8" && printf '%s\n' "refs/heads/main $MINE refs/heads/main $RSHA" | CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=acme-session sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 ); rc=$?
if echo "$out" | grep -q 'не создавала'; then bad "свой коммит (Session-Id совпал) — пропуск" "$out"; else ok "свой коммит (Session-Id совпал) — пропуск"; fi

printf 'чужой\n\nSession-Id: other-session\n' > "$R8/.m"
echo other > "$R8/b.txt"; git -C "$R8" add b.txt
git -C "$R8" commit -q -F "$R8/.m" --no-verify
FOREIGN=$(git -C "$R8" rev-parse HEAD)
out=$( cd "$R8" && printf '%s\n' "refs/heads/main $FOREIGN refs/heads/main $RSHA" | CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=acme-session sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 ); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'не создавала' && ok "чужой Session-Id — отказ" || bad "чужой Session-Id — отказ" "$out"
echo "$out" | grep -q 'git-allow-push' && ok "отказ подсказывает allowlist" || bad "подсказка про allowlist"

mkdir -p "$R8GIT/monitorex-locks"; echo "$FOREIGN" > "$R8GIT/monitorex-locks/push-allow"
out=$( cd "$R8" && printf '%s\n' "refs/heads/main $FOREIGN refs/heads/main $RSHA" | CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=acme-session sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 ); rc=$?
if echo "$out" | grep -q 'не создавала'; then bad "коммит из allowlist — пропуск" "$out"; else ok "коммит из allowlist — пропуск"; fi
rm -f "$R8GIT/monitorex-locks/push-allow"

out=$( cd "$R8" && printf '%s\n' "refs/heads/main $FOREIGN refs/heads/main $RSHA" | MONITOREX_ACTOR= CLAUDE_CODE_SESSION_ID= sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 ); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'MONITOREX_ACTOR' && ok "без личности — отказ с подсказкой задать ACTOR" || bad "без личности — отказ" "$out"
git -C "$R8" reset -q --hard "$RSHA"

# чужой коммит, уже лежащий в ДРУГОЙ ветке remote (main), — не чужая работа
git -C "$R8" push -q --no-verify origin "$FOREIGN:refs/heads/shared" "$RSHA:refs/heads/feat" 2>/dev/null
git -C "$R8" fetch -q origin
git -C "$R8" reset -q --hard "$FOREIGN"
printf 'свой поверх общего\n\nSession-Id: acme-session\n' > "$R8/.m"
echo mine2 > "$R8/a.txt"; git -C "$R8" add a.txt
git -C "$R8" commit -q -F "$R8/.m" --no-verify
MINE2=$(git -C "$R8" rev-parse HEAD)
out=$( cd "$R8" && printf '%s\n' "refs/heads/feat $MINE2 refs/heads/feat $RSHA" | CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=acme-session sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 ); rc=$?
if echo "$out" | grep -q 'не создавала'; then bad "коммит, уже лежащий в другой ветке remote, — не чужой" "$out"; else ok "коммит, уже лежащий в другой ветке remote, — не чужой"; fi
git -C "$R8" push -q --no-verify origin --delete shared 2>/dev/null
git -C "$R8" fetch -q --prune origin
out=$( cd "$R8" && printf '%s\n' "refs/heads/feat $MINE2 refs/heads/feat $RSHA" | CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=acme-session sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 ); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'не создавала' && ok "тот же чужой коммит, которого нет на remote, — отказ" || bad "чужой коммит не на remote — отказ" "$out"
git -C "$R8" reset -q --hard "$RSHA"

echo "== pre-push: release-gate =="
RG="$ROOT/scripts/release-gate.sh"
gate_pp() {   # $1 = каталог запуска, $2 = sha, $3 = sha ветки на remote (по умолчанию $RSHA)
    ( cd "$1" && printf '%s\n' "refs/heads/feat $2 refs/heads/feat ${3:-$RSHA}" \
        | CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=acme-session sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 )
}
own_commit() {   # $1 = файл, $2 = содержимое
    printf 'гейт\n\nSession-Id: acme-session\n' > "$R8/.m"
    echo "$2" > "$R8/$1"; git -C "$R8" add "$1"
    git -C "$R8" commit -q -F "$R8/.m" --no-verify
    git -C "$R8" rev-parse HEAD
}
G1=$(own_commit a.txt gate1)
out=$(gate_pp "$R8" "$G1")
echo "$out" | grep -q 'release-gate' && bad "гейт выключен — молчит" "$out" || ok "гейт выключен — молчит"

echo 'GG_RELEASE_GATE=1' > "$R8/.gitguards.conf"
out=$(gate_pp "$R8" "$G1"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'не прошёл финальное ревью' && ok "код без вердикта — отказ" || bad "код без вердикта — отказ" "$out"
echo "$out" | grep -q 'release-gate.sh override' && ok "отказ называет обход человеком" || bad "подсказка про override"

echo "отчёт ревью" > "$TMP/report.md"
( cd "$R8" && bash "$RG" pass --head HEAD --report "$TMP/report.md" >/dev/null 2>&1 ) && bad "--head HEAD (не SHA) — отказ" || ok "--head HEAD (не SHA) — отказ"
( cd "$R8" && bash "$RG" pass --head "$G1" --report "$TMP/report.md" >/dev/null 2>&1 ) && ok "pass пишет вердикт" || bad "pass пишет вердикт"
( cd "$R8" && bash "$RG" pass --head "$G1" >/dev/null 2>&1 ) && bad "pass без отчёта — отказ" || ok "pass без отчёта — отказ"
( cd "$R8" && bash "$RG" pass --report "$TMP/report.md" >/dev/null 2>&1 ) && bad "pass без --head — отказ" || ok "pass без --head — отказ"
out=$(gate_pp "$R8" "$G1")
echo "$out" | grep -q '✅ release-gate: pass' && ok "есть вердикт — пропуск" || bad "есть вердикт — пропуск" "$out"

# пересборка коммита с тем же деревом вердикт не теряет
git -C "$R8" commit -q --amend --no-verify -m "$(printf 'гейт, новое сообщение\n\nSession-Id: acme-session')"
G1B=$(git -C "$R8" rev-parse HEAD)
out=$(gate_pp "$R8" "$G1B")
echo "$out" | grep -q '✅ release-gate' && ok "то же дерево, другой SHA — вердикт в силе" || bad "то же дерево — вердикт в силе" "$out"

# правка содержимого снимает вердикт
G2=$(own_commit a.txt gate2)
out=$(gate_pp "$R8" "$G2"); rc=$?
[ $rc -ne 0 ] && ok "правка после вердикта — отказ" || bad "правка после вердикта — отказ" "$out"

# HEAD сдвинулся во время ревью — вердикт на непрочитанное не ложится
( cd "$R8" && bash "$RG" pass --head "$G1B" --report "$TMP/report.md" >/dev/null 2>&1 ) \
    && bad "pass на сдвинутый HEAD — отказ" || ok "pass на сдвинутый HEAD — отказ"

# пустой файл вердикта мимо скрипта — не вердикт
G2T=$(git -C "$R8" rev-parse "$G2^{tree}")
touch "$R8GIT/monitorex-locks/release-gate/$G2T"
out=$(gate_pp "$R8" "$G2"); rc=$?
[ $rc -ne 0 ] && ok "пустой файл вердикта — отказ" || bad "пустой файл вердикта — отказ" "$out"
out=$( cd "$R8" && bash "$RG" status 2>&1 ); rc=$?
[ $rc -ne 0 ] && ! echo "$out" | grep -q '✅' && ok "status: пустой файл — не вердикт" || bad "status: пустой файл — не вердикт" "$out"
rm -f "$R8GIT/monitorex-locks/release-gate/$G2T"

# незакоммиченная правка — вердикт не ставится
echo dirty > "$R8/a.txt"
out=$( cd "$R8" && bash "$RG" pass --head "$G2" --report "$TMP/report.md" 2>&1 ); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'незакоммиченные' && ok "pass при грязном дереве — отказ" || bad "pass при грязном дереве — отказ" "$out"
git -C "$R8" checkout -q -- a.txt

# переименование кода в *.md — это удаление кода, ревью нужно
git -C "$R8" reset -q --hard "$RSHA"
printf 'x\ny\nz\n' > "$R8/code.ts"; git -C "$R8" add code.ts; git -C "$R8" commit -qm code --no-verify
git -C "$R8" push -q --no-verify origin HEAD:main 2>/dev/null; git -C "$R8" fetch -q origin
RSHA_OLD=$RSHA; RSHA=$(git -C "$R8" rev-parse origin/main)
git -C "$R8" mv code.ts code.md
printf 'переименование\n\nSession-Id: acme-session\n' > "$R8/.m"
git -C "$R8" commit -q -F "$R8/.m" --no-verify
RN=$(git -C "$R8" rev-parse HEAD)
out=$(gate_pp "$R8" "$RN"); rc=$?
[ $rc -ne 0 ] && ok "переименование .ts → .md — ревью нужно" || bad "переименование .ts → .md — ревью нужно" "$out"

# флаг на remote-ветке main включает гейт, даже если локально его нет нигде
rm -f "$R8/.gitguards.conf"
git -C "$R8" reset -q --hard "$RSHA"
echo 'GG_RELEASE_GATE=1' > "$R8/.gitguards.conf"; git -C "$R8" add .gitguards.conf
git -C "$R8" commit -qm conf --no-verify
git -C "$R8" push -q --no-verify origin HEAD:main 2>/dev/null; git -C "$R8" fetch -q origin
RSHA=$(git -C "$R8" rev-parse origin/main)
git -C "$R8" worktree add -q "$TMP/r8old" "$RSHA_OLD" 2>/dev/null
printf 'старая база\n\nSession-Id: acme-session\n' > "$R8/.m"
echo old > "$TMP/r8old/a.txt"; git -C "$TMP/r8old" add a.txt
git -C "$TMP/r8old" commit -q -F "$R8/.m" --no-verify
OLD=$(git -C "$TMP/r8old" rev-parse HEAD)
git -C "$R8" rm -q --cached .gitguards.conf; rm -f "$R8/.gitguards.conf"
out=$(gate_pp "$TMP/r8old" "$OLD" 0000000000000000000000000000000000000000); rc=$?   # новая ветка
[ $rc -ne 0 ] && echo "$out" | grep -q 'не прошёл финальное ревью' && ok "флаг на origin/main — гейт и для старой базы" || bad "флаг на origin/main — гейт" "$out"
git -C "$R8" worktree remove -f "$TMP/r8old"
git -C "$R8" reset -q --hard "$RSHA"
echo 'GG_RELEASE_GATE=1' > "$R8/.gitguards.conf"

# только документация — гейт не нужен
git -C "$R8" reset -q --hard "$RSHA"
D1=$(own_commit README.md docs)
out=$(gate_pp "$R8" "$D1"); rc=$?
[ $rc -eq 0 ] && ! echo "$out" | grep -q 'release-gate' && ok "только *.md — гейт не нужен" || bad "только *.md — гейт не нужен" "$out"

# флаг основного дерева действует и в worktree без своего конфига (fail-closed)
git -C "$R8" reset -q --hard "$RSHA"
G3=$(own_commit a.txt gate3)
git -C "$R8" worktree add -q "$TMP/r8wt" "$G3" 2>/dev/null
out=$(gate_pp "$TMP/r8wt" "$G3"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'не прошёл финальное ревью' && ok "worktree без конфига — гейт по политике основного дерева" || bad "worktree без конфига — гейт" "$out"
git -C "$R8" worktree remove -f "$TMP/r8wt"

# маска SKIP — политика main: ветка не может прописать себе SKIP="*"
git -C "$R8" worktree add -q "$TMP/r8skip" "$G3" 2>/dev/null
printf 'GG_RELEASE_GATE=1\nGG_RELEASE_GATE_SKIP="*"\n' > "$TMP/r8skip/.gitguards.conf"
out=$(gate_pp "$TMP/r8skip" "$G3"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'не прошёл финальное ревью' && ok "SKIP=\"*\" в конфиге ветки — гейт в силе" || bad "SKIP из конфига ветки" "$out"
echo "$out" | grep -q 'нет scripts/release-gate.sh' && ok "дерево без скрипта — подсказка влить main" || bad "подсказка про скрипт" "$out"
out=$( cd "$TMP/r8skip" && bash "$RG" scope 2>&1 )
echo "$out" | grep -q 'файлы на ревью' && ok "scope: SKIP ветки не действует" || bad "scope: SKIP ветки" "$out"
git -C "$R8" worktree remove -f "$TMP/r8skip"
rm -f "$R8/.gitguards.conf" "$R8/.m"
rm -rf "$R8GIT/monitorex-locks/release-gate"
git -C "$R8" reset -q --hard "$RSHA"

# неканонический hooksPath
git -C "$R8" config core.hooksPath .husky/_
out=$(run_pp "refs/heads/main $RSHA refs/heads/main $RSHA"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'не канонический' && ok "неканонический core.hooksPath — отказ" || bad "неканонический hooksPath" "$out"

echo
echo "=========================================="
echo "  прошло: $PASS   провалено: $FAIL"
[ $FAIL -gt 0 ] && { echo "  провалы:"; printf '    - %s\n' "${FAILED[@]}"; exit 1; }
echo "=========================================="
exit 0
