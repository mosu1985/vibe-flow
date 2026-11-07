#!/usr/bin/env bash
# test-git-guards.sh — the A5 matrix. Everything runs in TEMPORARY repositories
# (mktemp); the real repository is not touched at any step.
#
# Run: bash scripts/test-git-guards.sh
# Exit code: 0 — all green, 1 — at least one failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "  FAIL - $1: ${2:-}"; }

mkrepo() {                     # $1 = path
    mkdir -p "$1"; git -C "$1" init -q
    git -C "$1" config user.email t@t; git -C "$1" config user.name t
    echo v1 > "$1/a.txt"; echo v1 > "$1/b.txt"
    printf '#!/bin/sh\necho hi\n' > "$1/s.sh"; chmod +x "$1/s.sh"
    mkdir -p "$1/dír"; echo "ünï" > "$1/dír/fïle with space.txt"
    git -C "$1" add -A; git -C "$1" commit -qm init
}

commit() {                     # $1 = repo, $2 = message, then paths
    local repo="$1" msg="$2"; shift 2
    printf '%s\n' "$msg" > "$repo/.msg"
    ( cd "$repo" && CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=test MONITOREX_SKIP_TESTS=1 \
        bash "$ROOT/scripts/git-safe-commit.sh" --message-file .msg -- "$@" ) 2>&1
}

echo "== verify_staged.py =="
V() { python3 "$ROOT/scripts/git-guards/verify_staged.py" "$@"; }
printf 'a.txt\0' | V --expect a.txt b.txt >/dev/null 2>&1 && ok "subset of expected — allow" || bad "subset — allow"
printf 'a.txt\0foreign.ts\0' | V --expect a.txt >/dev/null 2>&1 && bad "extra path — deny" "got allow" || ok "extra path — deny"
printf 'lib/x/y.ts\0' | V --expect lib >/dev/null 2>&1 && ok "path inside a directory pathspec — allow" || bad "directory pathspec"
printf 'dír/fïle with space.txt\0' | V --expect 'dír/fïle with space.txt' >/dev/null 2>&1 && ok "non-ASCII and spaces" || bad "non-ASCII and spaces"
printf 'a.txt\0' | V --intersects a.txt b.txt >/dev/null 2>&1 && ok "overlap found" || bad "overlap found"
printf 'c.txt\0' | V --intersects a.txt >/dev/null 2>&1 && bad "no overlap — rc=1" "returned 0" || ok "no overlap — rc=1"

echo "== safe-commit: happy path =="
R="$TMP/r1"; mkrepo "$R"
echo v2 > "$R/a.txt"; echo "foreign" > "$R/b.txt"          # b.txt is edited by a "neighbor"
out=$(commit "$R" "edit a" a.txt); rc=$?
[ $rc -eq 0 ] && ok "single-file commit passes" || bad "commit passes" "$out"
names=$(git -C "$R" show --name-only --format='' HEAD)
[ "$names" = "a.txt" ] && ok "commit has exactly the requested file (foreign b.txt not included)" || bad "commit contents" "$names"
git -C "$R" log -1 --format='%(trailers:key=Session-Id)' | grep -q test && ok "Session-Id trailer set" || bad "Session-Id trailer"
[ -z "$(git -C "$R" status --porcelain a.txt)" ] && ok "index in sync after commit (a.txt clean)" || bad "index in sync" "$(git -C "$R" status --short)"
[ "$(cat "$R/b.txt")" = "foreign" ] && ok "foreign change on disk intact" || bad "foreign change intact"
[ -z "$(ls -A "$(git -C "$R" rev-parse --absolute-git-dir)/monitorex-locks" 2>/dev/null | grep -v '^$')" ] && ok "locks released after success" || bad "locks released after success"
[ ! -f "$(git -C "$R" rev-parse --absolute-git-dir)/index.lock" ] && ok "index.lock removed" || bad "index.lock removed"

echo "== safe-commit: rejections =="
R2="$TMP/r2"; mkrepo "$R2"
echo v2 > "$R2/a.txt"; git -C "$R2" add a.txt              # a "neighbor" staged it
echo v2 > "$R2/b.txt"
out=$(commit "$R2" "edit b" b.txt); rc=$?
[ $rc -ne 0 ] && ok "foreign staged change — rejected BEFORE the branch moves" || bad "rejection on dirty index" "$out"
[ "$(git -C "$R2" rev-parse HEAD)" = "$(git -C "$R2" rev-parse HEAD)" ] && \
  [ "$(git -C "$R2" log --oneline | wc -l | tr -d ' ')" = "1" ] && ok "branch did not move on rejection" || bad "branch did not move"
git -C "$R2" ls-files -s a.txt | grep -q . && ok "foreign staged snapshot survived" || bad "staged snapshot survived"
[ ! -f "$(git -C "$R2" rev-parse --absolute-git-dir)/index.lock" ] && ok "index.lock removed after rejection" || bad "index.lock removed after rejection"

R3="$TMP/r3"; mkrepo "$R3"
out=$(commit "$R3" "nothing" a.txt); rc=$?
[ $rc -ne 0 ] && ok "nothing to commit — rejected" || bad "nothing to commit" "$out"

R4="$TMP/r4"; mkrepo "$R4"; echo v2 > "$R4/a.txt"
printf 'msg\n' > "$R4/.msg"
out=$( cd "$R4" && MONITOREX_SKIP_TESTS=1 MONITOREX_ACTOR= CLAUDE_CODE_SESSION_ID= \
       bash "$ROOT/scripts/git-safe-commit.sh" --message-file .msg -- a.txt 2>&1 ); rc=$?
[ $rc -ne 0 ] && ok "empty ACTOR — rejected (fail-closed)" || bad "empty ACTOR — rejected" "$out"

out=$( cd "$R4" && MONITOREX_ACTOR=t MONITOREX_SKIP_TESTS=1 \
       bash "$ROOT/scripts/git-safe-commit.sh" a.txt 2>&1 ); rc=$?
[ $rc -ne 0 ] && ok "path without --message-file — rejected" || bad "CLI: path without --message-file"

echo "== safe-commit: modes, non-ASCII, deletion =="
R5="$TMP/r5"; mkrepo "$R5"
printf '#!/bin/sh\necho v2\n' > "$R5/s.sh"
echo "ünï2" > "$R5/dír/fïle with space.txt"
out=$(commit "$R5" "exec+non-ASCII" s.sh "dír/fïle with space.txt"); rc=$?
[ $rc -eq 0 ] && ok "executable file and non-ASCII path commit" || bad "exec+non-ASCII" "$out"
[ "$(git -C "$R5" ls-files -s s.sh | cut -d' ' -f1)" = "100755" ] && ok "mode 100755 preserved in the index" || bad "mode 100755"
rm "$R5/b.txt"
out=$(commit "$R5" "deletion" b.txt); rc=$?
[ $rc -eq 0 ] && ok "file deletion commits" || bad "file deletion" "$out"
git -C "$R5" show --name-status --format='' HEAD | grep -q '^D' && ok "deletion recorded as D" || bad "deletion recorded as D"

echo "== safe-commit: .gitignore =="
R8="$TMP/r8"; mkrepo "$R8"
mkdir -p "$R8/ign"; echo v1 > "$R8/ign/tracked.md"
git -C "$R8" add ign/tracked.md; git -C "$R8" commit -qm "tracked in a soon-to-be-ignored directory"
echo "ign/" > "$R8/.gitignore"; git -C "$R8" add .gitignore; git -C "$R8" commit -qm gitignore
echo v2 > "$R8/ign/tracked.md"
out=$(commit "$R8" "edit tracked" ign/tracked.md); rc=$?
[ $rc -eq 0 ] && ok "tracked file in an ignored directory commits" || bad "tracked in ignored" "$out"
git -C "$R8" show --name-only --format='' HEAD | grep -qx 'ign/tracked.md' && ok "commit contains the tracked file change" || bad "commit contents ign/" "$(git -C "$R8" show --name-only --format='' HEAD)"
echo new > "$R8/ign/new.md"
out=$(commit "$R8" "new ignored" ign/new.md); rc=$?
[ $rc -ne 0 ] && ok "new ignored file is still rejected" || bad "new ignored — rejected" "$out"
git -C "$R8" ls-tree -r --name-only HEAD | grep -qx 'ign/new.md' && bad "new ignored file not in the tree" "it is" || ok "new ignored file not in the tree"

echo "== CAS: conflict and recovery ref =="
R6="$TMP/r6"; mkrepo "$R6"
# a neighbor moves the branch right before the CAS — emulating it via a mid-way hook
# is harder; test the primitive directly
A=$(git -C "$R6" rev-parse HEAD)
echo x > "$R6/c.txt"; git -C "$R6" add c.txt; git -C "$R6" commit -qm neighbour
echo v2 > "$R6/a.txt"
IDXF=$(mktemp -t idx); GIT_INDEX_FILE="$IDXF" git -C "$R6" read-tree "$A"
GIT_INDEX_FILE="$IDXF" git -C "$R6" add a.txt
TREE=$(GIT_INDEX_FILE="$IDXF" git -C "$R6" write-tree)
N=$(echo m | git -C "$R6" commit-tree "$TREE" -p "$A")
git -C "$R6" update-ref refs/heads/main "$N" "$A" 2>/dev/null && bad "CAS rejects a stale old" "passed" || ok "CAS rejects a stale old"
git -C "$R6" cat-file -t "$N" >/dev/null 2>&1 && ok "commit object survived the CAS rejection" || bad "object survived rejection"
rm -f "$IDXF"

echo "== pre-commit: per-tree policy =="
R7="$TMP/r7"; mkrepo "$R7"
HOOK="$ROOT/githooks/pre-commit"
out=$( cd "$R7" && sh "$HOOK" 2>&1 ); rc=$?
[ $rc -ne 0 ] && ok "regular commit in the main working tree — rejected" || bad "regular commit — rejected" "$out"
echo "$out" | grep -q 'git-safe-commit' && ok "rejection suggests safe-commit" || bad "hint in rejection"
git -C "$R7" worktree add -q "$TMP/r7-wt" -b wtb >/dev/null 2>&1
out=$( cd "$TMP/r7-wt" && sh "$HOOK" 2>&1 )
if echo "$out" | grep -q 'forbidden'; then bad "worktree is not blocked by policy" "$out"; else ok "commit in a linked worktree is not blocked by policy"; fi

echo "== git-lock take/drop: lock for a merge in your own worktree =="
GL="$ROOT/scripts/git-lock.sh"
out=$( cd "$R7" && CLAUDE_CODE_SESSION_ID=s1 bash "$GL" take 2>&1 ); rc=$?
[ $rc -ne 0 ] && ok "take in the main working tree — rejected" || bad "take in the main working tree — rejected" "$out"
out=$( cd "$TMP/r7-wt" && CLAUDE_CODE_SESSION_ID=s1 bash "$GL" take 2>&1 ); rc=$?
[ $rc -eq 0 ] && [ -d "$R7/.git/monitorex-locks/commit" ] && ok "take in worktree — lock taken" || bad "take in worktree" "$out"
out=$( cd "$TMP/r7-wt" && CLAUDE_CODE_SESSION_ID=s2 bash "$GL" take 2>&1 ); rc=$?
[ $rc -ne 0 ] && ok "second take while lock is held — rejected" || bad "second take — rejected" "$out"
git -C "$TMP/r7-wt" merge -q --no-ff --no-commit HEAD >/dev/null 2>&1 || true
printf '%s\n' "$(git -C "$TMP/r7-wt" rev-parse HEAD)" > "$(git -C "$TMP/r7-wt" rev-parse --git-path MERGE_HEAD)"
out=$( cd "$TMP/r7-wt" && sh "$HOOK" 2>&1 ); rc=$?
[ $rc -eq 0 ] && ok "pre-commit with MERGE_HEAD and a take lock — allowed" || bad "MERGE_HEAD with lock" "$out"
rm -f "$(git -C "$TMP/r7-wt" rev-parse --git-path MERGE_HEAD)"
out=$( cd "$TMP/r7-wt" && CLAUDE_CODE_SESSION_ID=s2 bash "$GL" drop 2>&1 ); rc=$?
[ $rc -ne 0 ] && [ -d "$R7/.git/monitorex-locks/commit" ] && ok "drop by another session — rejected" || bad "drop by another session" "$out"
out=$( cd "$TMP/r7-wt" && CLAUDE_CODE_SESSION_ID=s1 bash "$GL" drop 2>&1 ); rc=$?
[ $rc -eq 0 ] && [ ! -d "$R7/.git/monitorex-locks/commit" ] && ok "drop by own session — lock released" || bad "drop by own session" "$out"
mkdir -p "$R7/.git/monitorex-locks/commit"; printf 'actor=safe\npid=1\n' > "$R7/.git/monitorex-locks/commit/owner"
out=$( cd "$TMP/r7-wt" && CLAUDE_CODE_SESSION_ID=safe bash "$GL" drop 2>&1 ); rc=$?
[ $rc -ne 0 ] && ok "drop of a safe-commit lock (not take) — rejected" || bad "drop of non-take lock" "$out"
rm -rf "$R7/.git/monitorex-locks/commit"

echo "== one-off mark (git-confirm) =="
R9="$TMP/r9"; mkrepo "$R9"
CONF="$R9/.git/monitorex-locks/CONFIRM"
mkdir -p "$(dirname "$CONF")"
out=$( cd "$R9" && sh "$HOOK" 2>&1 ); rc=$?
[ $rc -ne 0 ] && ok "no mark — rejected" || bad "no mark — rejected"
printf 'target=commit\nts=x\n' > "$CONF"
out=$( cd "$R9" && sh "$HOOK" 2>&1 )
echo "$out" | grep -q 'forbidden' && bad "fresh mark — allowed" "$out" || ok "fresh mark — allowed"
[ ! -f "$CONF" ] && ok "mark consumed after use (single-use)" || bad "mark consumed"
printf 'target=push\nts=x\n' > "$CONF"
out=$( cd "$R9" && sh "$HOOK" 2>&1 )
echo "$out" | grep -q 'forbidden' && ok "mark with a DIFFERENT target does not apply" || bad "different target does not apply" "$out"
touch -t 202001010000 "$CONF"
out=$( cd "$R9" && sh "$HOOK" 2>&1 )
echo "$out" | grep -q 'forbidden' && ok "expired mark has no effect" || bad "expired mark" "$out"
rm -f "$CONF"

echo "== human confirmation: keyboard, empty input, --yes =="
# Running via `!` in Claude Code has no interactive stdin: read gets EOF.
# The script used to silently exit with rc=1 — the question is visible, no way to answer, no mark.
DEL="$R9/.git/monitorex-locks/delete-allow"
PUSHL="$R9/.git/monitorex-locks/push-allow"
R9SHA=$(git -C "$R9" rev-parse HEAD)
for spec in "git-confirm.sh|commit|$CONF" "git-allow-delete.sh|add a.txt|$DEL" "git-allow-push.sh|add $R9SHA|$PUSHL"; do
    s=${spec%%|*}; rest=${spec#*|}; args=${rest%%|*}; mark=${rest#*|}
    rm -f "$mark"
    out=$( cd "$R9" && bash "$ROOT/scripts/$s" $args < /dev/null 2>&1 ); rc=$?
    { [ $rc -ne 0 ] && echo "$out" | grep -q -- '--yes' && [ ! -s "$mark" ]; } \
        && ok "$s: empty input — rejected with a --yes hint, no mark" || bad "$s: empty input" "$out"
    out=$( cd "$R9" && echo no | bash "$ROOT/scripts/$s" $args 2>&1 ); rc=$?
    { [ $rc -ne 0 ] && [ ! -s "$mark" ]; } && ok "$s: answer \"no\" — no mark" || bad "$s: answer \"no\"" "$out"
    out=$( cd "$R9" && echo yes | bash "$ROOT/scripts/$s" $args 2>&1 ); rc=$?
    { [ $rc -eq 0 ] && [ -s "$mark" ]; } && ok "$s: answer \"yes\" — mark set" || bad "$s: answer \"yes\"" "$out"
    rm -f "$mark"
    out=$( cd "$R9" && bash "$ROOT/scripts/$s" $args --yes < /dev/null 2>&1 ); rc=$?
    { [ $rc -eq 0 ] && [ -s "$mark" ]; } && ok "$s: --yes without a keyboard — mark set" || bad "$s: --yes" "$out"
    rm -f "$mark"
done
out=$( cd "$R9" && bash "$ROOT/scripts/git-allow-delete.sh" add --yes a.txt b.txt < /dev/null 2>&1 )
[ "$(cat "$DEL" 2>/dev/null)" = "$(printf 'a.txt\nb.txt')" ] && ok "--yes does not end up in the path list" || bad "--yes in the path list" "$(cat "$DEL" 2>/dev/null)"
rm -f "$DEL"

echo "== pre-push: ref matrix =="
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

# deleting main
out=$(run_pp "refs/heads/main 0000000000000000000000000000000000000000 refs/heads/main $RSHA"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'Deleting protected' && ok "deleting main — rejected" || bad "deleting main — rejected" "$out"
# overwriting a tag
out=$(run_pp "refs/tags/v1 $RSHA refs/tags/v1 $RSHA"); rc=$?
[ $rc -ne 0 ] && ok "overwriting a tag — rejected" || bad "overwriting a tag — rejected" "$out"
# push to an unknown ref
out=$(run_pp "refs/notes/x $RSHA refs/notes/x 0000000000000000000000000000000000000000"); rc=$?
[ $rc -ne 0 ] && ok "refs/notes — fail-closed rejection" || bad "refs/notes — rejected" "$out"
# non-fast-forward
echo diverged > "$R8/a.txt"; git -C "$R8" add a.txt; git -C "$R8" commit -qm div
DIV=$(git -C "$R8" rev-parse HEAD)
git -C "$R8" reset -q --hard "$RSHA"
echo other > "$R8/a.txt"; git -C "$R8" add a.txt; git -C "$R8" commit -qm other
out=$(run_pp "refs/heads/main $DIV refs/heads/main $(git -C "$R8" rev-parse HEAD)"); rc=$?
[ $rc -ne 0 ] && ok "non-fast-forward — rejected" || bad "non-fast-forward — rejected" "$out"
# file deletion in a push to main
git -C "$R8" reset -q --hard "$RSHA"
git -C "$R8" rm -q b.txt; git -C "$R8" commit -qm "remove b.txt"
DELSHA=$(git -C "$R8" rev-parse HEAD)
mkdir -p "$R8GIT/monitorex-locks"; echo "$DELSHA" > "$R8GIT/monitorex-locks/push-allow"
out=$(run_pp "refs/heads/main $DELSHA refs/heads/main $RSHA"); rc=$?
rm -f "$R8GIT/monitorex-locks/push-allow"
[ $rc -ne 0 ] && echo "$out" | grep -q 'DELETES files' && ok "push deleting files in main — rejected" || bad "push with deletion — rejected" "$out"
# --- commit ownership ---
git -C "$R8" config core.hooksPath "$R8GIT/monitorex-hooks"
git -C "$R8" reset -q --hard "$RSHA"
printf 'own\n\nSession-Id: acme-session\n' > "$R8/.m"
echo own > "$R8/a.txt"; git -C "$R8" add a.txt
git -C "$R8" commit -q -F "$R8/.m" --no-verify
MINE=$(git -C "$R8" rev-parse HEAD)
out=$( cd "$R8" && printf '%s\n' "refs/heads/main $MINE refs/heads/main $RSHA" | CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=acme-session sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 ); rc=$?
if echo "$out" | grep -q 'did not create'; then bad "own commit (Session-Id matches) — allowed" "$out"; else ok "own commit (Session-Id matches) — allowed"; fi

printf 'foreign\n\nSession-Id: other-session\n' > "$R8/.m"
echo other > "$R8/b.txt"; git -C "$R8" add b.txt
git -C "$R8" commit -q -F "$R8/.m" --no-verify
FOREIGN=$(git -C "$R8" rev-parse HEAD)
out=$( cd "$R8" && printf '%s\n' "refs/heads/main $FOREIGN refs/heads/main $RSHA" | CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=acme-session sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 ); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'did not create' && ok "foreign Session-Id — rejected" || bad "foreign Session-Id — rejected" "$out"
echo "$out" | grep -q 'git-allow-push' && ok "rejection suggests the allowlist" || bad "allowlist hint"

mkdir -p "$R8GIT/monitorex-locks"; echo "$FOREIGN" > "$R8GIT/monitorex-locks/push-allow"
out=$( cd "$R8" && printf '%s\n' "refs/heads/main $FOREIGN refs/heads/main $RSHA" | CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=acme-session sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 ); rc=$?
if echo "$out" | grep -q 'did not create'; then bad "allowlisted commit — allowed" "$out"; else ok "allowlisted commit — allowed"; fi
rm -f "$R8GIT/monitorex-locks/push-allow"

out=$( cd "$R8" && printf '%s\n' "refs/heads/main $FOREIGN refs/heads/main $RSHA" | MONITOREX_ACTOR= CLAUDE_CODE_SESSION_ID= sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 ); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'MONITOREX_ACTOR' && ok "no identity — rejected with a hint to set ACTOR" || bad "no identity — rejected" "$out"
git -C "$R8" reset -q --hard "$RSHA"

# a foreign commit already present in ANOTHER remote branch (main) is not someone else's work
git -C "$R8" push -q --no-verify origin "$FOREIGN:refs/heads/shared" "$RSHA:refs/heads/feat" 2>/dev/null
git -C "$R8" fetch -q origin
git -C "$R8" reset -q --hard "$FOREIGN"
printf 'own on top of shared\n\nSession-Id: acme-session\n' > "$R8/.m"
echo mine2 > "$R8/a.txt"; git -C "$R8" add a.txt
git -C "$R8" commit -q -F "$R8/.m" --no-verify
MINE2=$(git -C "$R8" rev-parse HEAD)
out=$( cd "$R8" && printf '%s\n' "refs/heads/feat $MINE2 refs/heads/feat $RSHA" | CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=acme-session sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 ); rc=$?
if echo "$out" | grep -q 'did not create'; then bad "commit already in another remote branch — not foreign" "$out"; else ok "commit already in another remote branch — not foreign"; fi
git -C "$R8" push -q --no-verify origin --delete shared 2>/dev/null
git -C "$R8" fetch -q --prune origin
out=$( cd "$R8" && printf '%s\n' "refs/heads/feat $MINE2 refs/heads/feat $RSHA" | CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=acme-session sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 ); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'did not create' && ok "the same foreign commit, not on the remote — rejected" || bad "foreign commit not on remote — rejected" "$out"
git -C "$R8" reset -q --hard "$RSHA"

echo "== pre-push: release-gate =="
RG="$ROOT/scripts/release-gate.sh"
gate_pp() {   # $1 = directory to run in, $2 = sha, $3 = sha of the branch on the remote (default $RSHA)
    ( cd "$1" && printf '%s\n' "refs/heads/feat $2 refs/heads/feat ${3:-$RSHA}" \
        | CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=acme-session sh "$R8GIT/monitorex-hooks/pre-push" origin "$REMOTE" 2>&1 )
}
own_commit() {   # $1 = file, $2 = content
    printf 'gate\n\nSession-Id: acme-session\n' > "$R8/.m"
    echo "$2" > "$R8/$1"; git -C "$R8" add "$1"
    git -C "$R8" commit -q -F "$R8/.m" --no-verify
    git -C "$R8" rev-parse HEAD
}
G1=$(own_commit a.txt gate1)
out=$(gate_pp "$R8" "$G1")
echo "$out" | grep -q 'release-gate' && bad "gate disabled — silent" "$out" || ok "gate disabled — silent"

echo 'GG_RELEASE_GATE=1' > "$R8/.gitguards.conf"
out=$(gate_pp "$R8" "$G1"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'has not passed final review' && ok "code without a verdict — rejected" || bad "code without a verdict — rejected" "$out"
echo "$out" | grep -q 'release-gate.sh override' && ok "rejection names the human bypass" || bad "override hint"

echo "review report" > "$TMP/report.md"
( cd "$R8" && bash "$RG" pass --head HEAD --report "$TMP/report.md" >/dev/null 2>&1 ) && bad "--head HEAD (not a SHA) — rejected" || ok "--head HEAD (not a SHA) — rejected"
( cd "$R8" && bash "$RG" pass --head "$G1" --report "$TMP/report.md" >/dev/null 2>&1 ) && ok "pass records the verdict" || bad "pass records the verdict"
( cd "$R8" && bash "$RG" pass --head "$G1" >/dev/null 2>&1 ) && bad "pass without a report — rejected" || ok "pass without a report — rejected"
( cd "$R8" && bash "$RG" pass --report "$TMP/report.md" >/dev/null 2>&1 ) && bad "pass without --head — rejected" || ok "pass without --head — rejected"
out=$(gate_pp "$R8" "$G1")
echo "$out" | grep -q '✅ release-gate: pass' && ok "verdict exists — allowed" || bad "verdict exists — allowed" "$out"

# rebuilding a commit with the same tree keeps the verdict
git -C "$R8" commit -q --amend --no-verify -m "$(printf 'gate, new message\n\nSession-Id: acme-session')"
G1B=$(git -C "$R8" rev-parse HEAD)
out=$(gate_pp "$R8" "$G1B")
echo "$out" | grep -q '✅ release-gate' && ok "same tree, different SHA — verdict stands" || bad "same tree — verdict stands" "$out"

# a content change revokes the verdict
G2=$(own_commit a.txt gate2)
out=$(gate_pp "$R8" "$G2"); rc=$?
[ $rc -ne 0 ] && ok "change after verdict — rejected" || bad "change after verdict — rejected" "$out"

# HEAD moved during review — the verdict does not apply to unread content
( cd "$R8" && bash "$RG" pass --head "$G1B" --report "$TMP/report.md" >/dev/null 2>&1 ) \
    && bad "pass on a moved HEAD — rejected" || ok "pass on a moved HEAD — rejected"

# an empty verdict file written bypassing the script is not a verdict
G2T=$(git -C "$R8" rev-parse "$G2^{tree}")
touch "$R8GIT/monitorex-locks/release-gate/$G2T"
out=$(gate_pp "$R8" "$G2"); rc=$?
[ $rc -ne 0 ] && ok "empty verdict file — rejected" || bad "empty verdict file — rejected" "$out"
out=$( cd "$R8" && bash "$RG" status 2>&1 ); rc=$?
[ $rc -ne 0 ] && ! echo "$out" | grep -q '✅' && ok "status: empty file is not a verdict" || bad "status: empty file is not a verdict" "$out"
rm -f "$R8GIT/monitorex-locks/release-gate/$G2T"

# uncommitted change — no verdict is recorded
echo dirty > "$R8/a.txt"
out=$( cd "$R8" && bash "$RG" pass --head "$G2" --report "$TMP/report.md" 2>&1 ); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'uncommitted' && ok "pass with a dirty tree — rejected" || bad "pass with a dirty tree — rejected" "$out"
git -C "$R8" checkout -q -- a.txt

# renaming code to *.md deletes code — review is needed
git -C "$R8" reset -q --hard "$RSHA"
printf 'x\ny\nz\n' > "$R8/code.ts"; git -C "$R8" add code.ts; git -C "$R8" commit -qm code --no-verify
git -C "$R8" push -q --no-verify origin HEAD:main 2>/dev/null; git -C "$R8" fetch -q origin
RSHA_OLD=$RSHA; RSHA=$(git -C "$R8" rev-parse origin/main)
git -C "$R8" mv code.ts code.md
printf 'rename\n\nSession-Id: acme-session\n' > "$R8/.m"
git -C "$R8" commit -q -F "$R8/.m" --no-verify
RN=$(git -C "$R8" rev-parse HEAD)
out=$(gate_pp "$R8" "$RN"); rc=$?
[ $rc -ne 0 ] && ok "rename .ts → .md — review needed" || bad "rename .ts → .md — review needed" "$out"

# the flag on the remote main branch enables the gate even if it is set nowhere locally
rm -f "$R8/.gitguards.conf"
git -C "$R8" reset -q --hard "$RSHA"
echo 'GG_RELEASE_GATE=1' > "$R8/.gitguards.conf"; git -C "$R8" add .gitguards.conf
git -C "$R8" commit -qm conf --no-verify
git -C "$R8" push -q --no-verify origin HEAD:main 2>/dev/null; git -C "$R8" fetch -q origin
RSHA=$(git -C "$R8" rev-parse origin/main)
git -C "$R8" worktree add -q "$TMP/r8old" "$RSHA_OLD" 2>/dev/null
printf 'old base\n\nSession-Id: acme-session\n' > "$R8/.m"
echo old > "$TMP/r8old/a.txt"; git -C "$TMP/r8old" add a.txt
git -C "$TMP/r8old" commit -q -F "$R8/.m" --no-verify
OLD=$(git -C "$TMP/r8old" rev-parse HEAD)
git -C "$R8" rm -q --cached .gitguards.conf; rm -f "$R8/.gitguards.conf"
out=$(gate_pp "$TMP/r8old" "$OLD" 0000000000000000000000000000000000000000); rc=$?   # new branch
[ $rc -ne 0 ] && echo "$out" | grep -q 'has not passed final review' && ok "flag on origin/main — gate applies to an old base too" || bad "flag on origin/main — gate" "$out"
git -C "$R8" worktree remove -f "$TMP/r8old"
git -C "$R8" reset -q --hard "$RSHA"
echo 'GG_RELEASE_GATE=1' > "$R8/.gitguards.conf"

# docs only — gate not needed
git -C "$R8" reset -q --hard "$RSHA"
D1=$(own_commit README.md docs)
out=$(gate_pp "$R8" "$D1"); rc=$?
[ $rc -eq 0 ] && ! echo "$out" | grep -q 'release-gate' && ok "*.md only — gate not needed" || bad "*.md only — gate not needed" "$out"

# the main working tree's flag also applies in a worktree without its own config (fail-closed)
git -C "$R8" reset -q --hard "$RSHA"
G3=$(own_commit a.txt gate3)
git -C "$R8" worktree add -q "$TMP/r8wt" "$G3" 2>/dev/null
out=$(gate_pp "$TMP/r8wt" "$G3"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'has not passed final review' && ok "worktree without config — gate per main working tree policy" || bad "worktree without config — gate" "$out"
git -C "$R8" worktree remove -f "$TMP/r8wt"

# the SKIP mask is main's policy: a branch cannot set SKIP="*" for itself
git -C "$R8" worktree add -q "$TMP/r8skip" "$G3" 2>/dev/null
printf 'GG_RELEASE_GATE=1\nGG_RELEASE_GATE_SKIP="*"\n' > "$TMP/r8skip/.gitguards.conf"
out=$(gate_pp "$TMP/r8skip" "$G3"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'has not passed final review' && ok "SKIP=\"*\" in the branch config — gate stands" || bad "SKIP from branch config" "$out"
echo "$out" | grep -q 'has no scripts/release-gate.sh' && ok "tree without the script — hint to merge main" || bad "script hint" "$out"
out=$( cd "$TMP/r8skip" && bash "$RG" scope 2>&1 )
echo "$out" | grep -q 'files for review' && ok "scope: branch SKIP has no effect" || bad "scope: branch SKIP" "$out"
git -C "$R8" worktree remove -f "$TMP/r8skip"
rm -f "$R8/.gitguards.conf" "$R8/.m"
rm -rf "$R8GIT/monitorex-locks/release-gate"
git -C "$R8" reset -q --hard "$RSHA"

# non-canonical hooksPath
git -C "$R8" config core.hooksPath .husky/_
out=$(run_pp "refs/heads/main $RSHA refs/heads/main $RSHA"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'not canonical' && ok "non-canonical core.hooksPath — rejected" || bad "non-canonical hooksPath" "$out"

echo "== project gate (GG_PLAN_GATE) =="
RP="$TMP/rp"; mkrepo "$RP"; mkdir -p "$RP/scripts"
printf '#!/bin/sh\ngrep -q "^GATE-OK$" "$1" || { echo "project gate: no GATE-OK"; exit 1; }\n' > "$RP/scripts/gate.sh"
printf 'GG_PLAN_GATE="scripts/gate.sh"\n' > "$RP/.gitguards.conf"
git -C "$RP" add -A; git -C "$RP" commit -qm gate
echo v2 > "$RP/a.txt"
out=$(commit "$RP" "edit" a.txt); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'project gate' && ok "project gate refused — no commit" || bad "project gate refusal" "$out"
out=$(commit "$RP" "$(printf 'edit\n\nGATE-OK')" a.txt); rc=$?
[ $rc -eq 0 ] && ok "project gate let it through" || bad "project gate pass" "$out"
printf 'GG_PLAN_GATE="scripts/nope.sh"\n' > "$RP/.gitguards.conf"
echo v3 > "$RP/a.txt"
out=$(commit "$RP" "edit" a.txt); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'nonexistent' && ok "GG_PLAN_GATE pointing to a nonexistent file — rejected" || bad "GG_PLAN_GATE without file" "$out"

echo "== wt-new: the new branch's base is a fresh origin =="
WO="$TMP/wo.git"; git init -q --bare "$WO"
W="$TMP/w"; mkrepo "$W"; git -C "$W" branch -M main
git -C "$W" remote add origin "$WO"; git -C "$W" push -q origin main 2>/dev/null
mkdir -p "$W/scripts" "$W/githooks"
cp "$ROOT/scripts/wt-new.sh" "$ROOT/scripts/install-git-guards.sh" "$W/scripts/"
cp "$ROOT/githooks/pre-commit" "$ROOT/githooks/pre-push" "$W/githooks/"
WINIT=$(git -C "$W" rev-parse HEAD)
WN="$TMP/wn"; git clone -q "$WO" "$WN" 2>/dev/null
git -C "$WN" config user.email t@t; git -C "$WN" config user.name t
wn_push() { echo "$1" > "$WN/a.txt"; git -C "$WN" commit -qam "$1"; git -C "$WN" push -q origin HEAD:main 2>/dev/null; git -C "$WN" rev-parse HEAD; }
wcommit() { echo "$1" > "$W/b.txt"; git -C "$W" -c core.hooksPath=/dev/null commit -qam "$1"; git -C "$W" rev-parse HEAD; }

FRESH=$(wn_push "neighbor merged")                # GitHub is newer than the main folder
out=$(bash "$W/scripts/wt-new.sh" t1 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(git -C "$W" rev-parse wt/t1)" = "$FRESH" ] \
    && ok "main is behind — base is fresh origin/main" || bad "base is fresh origin/main" "$out"
[ -z "$(git -C "$W" config branch.wt/t1.merge)" ] \
    && ok "new branch has no upstream origin/main (--no-track)" || bad "--no-track" "$(git -C "$W" config branch.wt/t1.merge)"
echo "$out" | grep -q 'main folder is behind' \
    && ok "says the main folder is behind" || bad "behind warning" "$out"

git -C "$W" merge -q --ff-only origin/main
LOCALSHA=$(wcommit "local main commit")           # main is ahead of origin (not pushed)
out=$(bash "$W/scripts/wt-new.sh" t2 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(git -C "$W" rev-parse wt/t2)" = "$LOCALSHA" ] \
    && ok "local main is ahead — base is local (commits are not lost)" || bad "local ahead" "$out"

out=$(bash "$W/scripts/wt-new.sh" t3 "$WINIT" 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(git -C "$W" rev-parse wt/t3)" = "$WINIT" ] \
    && ok "explicit base wins over fresh origin" || bad "explicit base" "$out"

FRESH2=$(wn_push "neighbor merged again")         # now main and origin/main have diverged
out=$(bash "$W/scripts/wt-new.sh" t4 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(git -C "$W" rev-parse wt/t4)" = "$FRESH2" ] && echo "$out" | grep -q 'has diverged' \
    && ok "diverged — base is origin/main, with a warning" || bad "diverged" "$out"

git -C "$W" remote set-url origin "$TMP/nope.git"   # "no network"
out=$(bash "$W/scripts/wt-new.sh" t5 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'could not update' && git -C "$W" rev-parse -q --verify wt/t5 >/dev/null \
    && ok "no network — warning, and a tree from what is available" || bad "no network" "$out"

git -C "$W" remote remove origin                  # repository without origin
out=$(bash "$W/scripts/wt-new.sh" t6 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(git -C "$W" rev-parse wt/t6)" = "$LOCALSHA" ] \
    && ok "no origin — base is local main" || bad "no origin" "$out"

echo "== wt-new: dependencies, early fetch, fetch timeout =="
DO="$TMP/do.git"; git init -q --bare "$DO"
D="$TMP/d"; mkrepo "$D"; git -C "$D" branch -M main
echo '{"name":"t","version":"1.0.0"}' > "$D/package.json"; echo '{"lock":1}' > "$D/package-lock.json"
git -C "$D" add -A; git -C "$D" commit -qm deps
git -C "$D" remote add origin "$DO"; git -C "$D" push -q origin main 2>/dev/null
mkdir -p "$D/scripts" "$D/githooks"
cp "$ROOT/scripts/wt-new.sh" "$ROOT/scripts/install-git-guards.sh" "$ROOT/scripts/wt-status.sh" "$D/scripts/"
cp "$ROOT/githooks/pre-commit" "$ROOT/githooks/pre-push" "$D/githooks/"
# Install = a marker, so the test needs neither npm nor the network
printf 'GG_DEPS_INSTALL_CMD="mkdir -p node_modules && touch node_modules/.installed"\n' > "$D/.gitguards.conf"
mkdir -p "$D/node_modules"; echo main > "$D/node_modules/from-main"
touch "$D/node_modules/.package-lock.json"             # packages installed after the lockfile
DN="$TMP/dn"; git clone -q "$DO" "$DN" 2>/dev/null
git -C "$DN" config user.email t@t; git -C "$DN" config user.name t

out=$(bash "$D/scripts/wt-new.sh" d1 2>&1); rc=$?
[ $rc -eq 0 ] && [ -f "$TMP/d-wt/d1/node_modules/from-main" ] && [ ! -f "$TMP/d-wt/d1/node_modules/.installed" ] \
    && ok "fresh packages in main — node_modules cloned" || bad "clone of fresh packages" "$out"

touch -t 202001010000 "$D/node_modules/.package-lock.json"   # main pulled without reinstalling
out=$(bash "$D/scripts/wt-new.sh" d2 2>&1); rc=$?
[ $rc -eq 0 ] && [ -f "$TMP/d-wt/d2/node_modules/.installed" ] && [ ! -f "$TMP/d-wt/d2/node_modules/from-main" ] \
    && echo "$out" | grep -q 'outdated too' \
    && ok "main's packages older than its lockfile — fresh install in the tree" || bad "stale main packages" "$out"
touch "$D/node_modules/.package-lock.json"

echo '{"lock":2}' > "$DN/package-lock.json"; git -C "$DN" commit -qam "deps bump"; git -C "$DN" push -q origin HEAD:main 2>/dev/null
out=$(bash "$D/scripts/wt-new.sh" d3 2>&1); rc=$?
[ $rc -eq 0 ] && [ -f "$TMP/d-wt/d3/node_modules/.installed" ] && echo "$out" | grep -q 'differs between' \
    && ok "lockfile changed on GitHub — fresh install, not a clone" || bad "lockfile differs" "$out"

printf 'GG_DEPS_INSTALL_CMD="exit 3"\nGG_DEV_CMD="sleep 30"\n' > "$D/.gitguards.conf"
out=$(bash "$D/scripts/wt-new.sh" d4 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'package install failed' && echo "$out" | grep -q 'dev server not started' \
    && [ ! -f "$TMP/d-wt/d4/.wt-dev.pid" ] \
    && ok "install failed — said so, dev server not started" || bad "install failure" "$out"
printf 'GG_DEPS_INSTALL_CMD="mkdir -p node_modules && touch node_modules/.installed"\n' > "$D/.gitguards.conf"

# A branch already merged on GitHub must not block a new task with the same topic
git -C "$D" -c core.hooksPath=/dev/null checkout -q -b wt/payment-flow
echo pay > "$D/b.txt"; git -C "$D" -c core.hooksPath=/dev/null commit -qam pay
git -C "$D" -c core.hooksPath=/dev/null push -q origin wt/payment-flow 2>/dev/null; git -C "$D" checkout -q main
git -C "$DN" fetch -q origin; git -C "$DN" merge -q --no-edit origin/wt/payment-flow; git -C "$DN" push -q origin HEAD:main 2>/dev/null
out=$(bash "$D/scripts/wt-new.sh" payment-fix 2>&1); rc=$?
[ $rc -eq 0 ] && ! echo "$out" | grep -q 'already been started' \
    && ok "merged on GitHub — not \"already started\" (fetch runs before the check)" || bad "early fetch" "$out"

git -C "$D" config protocol.ext.allow always
git -C "$D" remote set-url origin "ext::sleep 30"     # a remote that hangs
printf 'GG_FETCH_TIMEOUT=2\nGG_DEPS_INSTALL_CMD="mkdir -p node_modules && touch node_modules/.installed"\n' > "$D/.gitguards.conf"
T0=$SECONDS; out=$(bash "$D/scripts/wt-new.sh" d5 2>&1); rc=$?; T=$((SECONDS-T0))
[ $rc -eq 0 ] && [ $T -lt 15 ] && echo "$out" | grep -q 'within 2s' \
    && ok "hanging fetch is cut off by the timeout (${T}s)" || bad "fetch timeout" "rc=$rc ${T}s $out"

# Project tests: scripts/git-guards/test-local-*.sh. They are added by the project
# itself, not by install.sh — so updating the kit does not overwrite them. All helpers are visible to them.
for t in "$ROOT"/scripts/git-guards/test-local-*.sh; do
    [ -f "$t" ] || continue
    . "$t"
done

echo
echo "=========================================="
echo "  passed: $PASS   failed: $FAIL"
[ $FAIL -gt 0 ] && { echo "  failures:"; printf '    - %s\n' "${FAILED[@]}"; exit 1; }
echo "=========================================="
exit 0
