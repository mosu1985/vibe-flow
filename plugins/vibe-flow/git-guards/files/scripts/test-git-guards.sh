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
# Plans for the plan gate live in a temporary directory: ~/.claude/plans is never touched.
export GG_PLANS_DIR="$TMP/plans"; mkdir -p "$GG_PLANS_DIR"

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

# ═════════════════════════════════════════════════════════════════════════════
# Plan gate, barrier protection, issue claims, tests after an edit (07.11.2026).
# Fixtures live here (heredocs / generated in $TMP): install.sh copies only
# files/scripts/*, so no extra fixture files in the repository.
# ═════════════════════════════════════════════════════════════════════════════

# Layout: the kit repository (files/claude/hooks, settings-merge.py one level up)
# or a project (.claude/hooks; settings-merge.py and detect.py are not copied there).
if [ -d "$ROOT/.claude/hooks" ]; then CH="$ROOT/.claude/hooks"; else CH="$ROOT/claude/hooks"; fi
KIT=""; [ -f "$ROOT/../settings-merge.py" ] && KIT="$(cd "$ROOT/.." && pwd)"

kit_copy() {     # $1 = repo: the kit in project layout
    mkdir -p "$1/githooks" "$1/scripts/git-guards" "$1/.claude/hooks"
    cp "$ROOT/githooks/pre-commit" "$ROOT/githooks/pre-push" "$ROOT/githooks/plan-gate.sh" "$1/githooks/"
    for s in git-safe-commit.sh install-git-guards.sh wt-new.sh wt-done.sh wt-status.sh git-lock.sh git-confirm.sh; do
        cp "$ROOT/scripts/$s" "$1/scripts/"
    done
    cp "$ROOT"/scripts/git-guards/*.py "$ROOT/scripts/git-guards/consumer-warn.sh" "$1/scripts/git-guards/"
    cp "$CH/monitorex-git-guard.sh" "$CH/monitorex_git_guard.py" "$1/.claude/hooks/"
}
sha_of() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }
NOW_TS=$(date +%s)
dead_pid() { sh -c 'exit 0' & local p=$!; wait "$p" 2>/dev/null; echo "$p"; }

echo "== plan gate: installer takes hooks from origin =="
PGO="$TMP/pg-origin.git"; git init -q --bare "$PGO"; git -C "$PGO" symbolic-ref HEAD refs/heads/main
PGR="$TMP/pg"; git init -q "$PGR"; git -C "$PGR" symbolic-ref HEAD refs/heads/main
git -C "$PGR" config user.email t@t; git -C "$PGR" config user.name t
kit_copy "$PGR"; mkdir -p "$PGR/supabase/migrations"
echo 1 > "$PGR/supabase/migrations/001_a.sql"; echo a > "$PGR/a.txt"
cat > "$PGR/.gitguards.conf" <<'CONF'
GG_PROTECTED="main"
GG_PLAN_REQUIRED_TYPES="feat"
GG_PLAN_REQUIRED_NEW="supabase/migrations/*.sql"
GG_PLAN_GATE="githooks/plan-gate.sh"
CONF
git -C "$PGR" add -A; git -C "$PGR" commit -qm init
git -C "$PGR" remote add origin "$PGO"; git -C "$PGR" push -q origin main 2>/dev/null; git -C "$PGR" fetch -q origin
git clone -q "$PGO" "$TMP/pg-adm" 2>/dev/null
PGH="$PGR/.git/monitorex-hooks"
out=$(bash "$PGR/scripts/install-git-guards.sh" 2>&1)
echo "$out" | grep -q 'source: origin/main' && ok "installer: source is origin/main" || bad "installer: source is origin/main" "$out"
grep -q '^origin@' "$PGH/.source" 2>/dev/null && ok "installer: .source = origin@<sha>" || bad "installer: .source" "$(cat "$PGH/.source" 2>&1)"
[ -x "$PGH/plan-gate.sh" ] && ok "installer: plan-gate.sh installed next to pre-push" || bad "installer: plan-gate.sh installed"
echo '# edited in the branch' >> "$PGR/githooks/pre-push"
bash "$PGR/scripts/install-git-guards.sh" >/dev/null 2>&1
git -C "$PGR" show origin/main:githooks/pre-push > "$TMP/pg-pp-origin"
cmp -s "$PGH/pre-push" "$TMP/pg-pp-origin" && ok "installer: a pre-push edited in the branch is NOT installed (origin's is)" \
    || bad "installer: branch edit not installed"
git -C "$PGR" checkout -q -- githooks/pre-push
PGB="$TMP/pg-norefs"; git clone -q "$PGO" "$PGB" 2>/dev/null
git -C "$PGB" update-ref -d refs/remotes/origin/main; git -C "$PGB" update-ref -d refs/remotes/origin/HEAD 2>/dev/null
out=$(bash "$PGB/scripts/install-git-guards.sh" 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'git fetch' && ok "installer: origin without fetched refs — refused with a git fetch hint" \
    || bad "installer: origin without refs" "$out"
PGO2="$TMP/pg-o2.git"; git init -q --bare "$PGO2"; git -C "$PGO2" symbolic-ref HEAD refs/heads/main
PGC="$TMP/pg-boot"; git init -q "$PGC"; git -C "$PGC" symbolic-ref HEAD refs/heads/main
git -C "$PGC" config user.email t@t; git -C "$PGC" config user.name t
echo x > "$PGC/x"; git -C "$PGC" add x; git -C "$PGC" commit -qm i
git -C "$PGC" remote add origin "$PGO2"; git -C "$PGC" push -q origin main 2>/dev/null; git -C "$PGC" fetch -q origin
kit_copy "$PGC"
out=$(bash "$PGC/scripts/install-git-guards.sh" 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'first install' && grep -q '^bootstrap@' "$PGC/.git/monitorex-hooks/.source" \
    && [ -x "$PGC/.git/monitorex-hooks/pre-push" ] \
    && ok "installer: origin/main without githooks/ — bootstrap from the tree, said out loud (C4)" || bad "installer: bootstrap (C4)" "$out"

echo "== plan gate: pre-push =="
pg_mc() {   # repo message file content [env...] → sha
    local r=$1 m=$2 f=$3 c=$4; shift 4
    mkdir -p "$(dirname "$r/$f")"; echo "$c" > "$r/$f"; git -C "$r" add -- "$f"
    printf '%s\n\nSession-Id: tst\n' "$m" > "$TMP/pg-msg"
    env "$@" git -C "$r" -c core.hooksPath=/dev/null commit -q -F "$TMP/pg-msg"; git -C "$r" rev-parse HEAD
}
pg_commit_staged() { printf '%s\n\nSession-Id: tst\n' "$2" > "$TMP/pg-msg"; git -C "$1" -c core.hooksPath=/dev/null commit -q -F "$TMP/pg-msg"; }
pg_push() { ( cd "$1" && env MONITOREX_ACTOR=tst CLAUDE_CODE_SESSION_ID= git push origin "HEAD:refs/heads/${2:-$PG_BR}" 2>&1 ); }
PG_N=0; PG_BR=wt/x0
pg_reset() { PG_N=$((PG_N+1)); PG_BR="${1:-wt/x$PG_N}"; git -C "$PGR" checkout -q -B "$PG_BR" origin/main; }
pg_main() {  # publish the local main of $PGR as origin/main (an "admin" merge)
    git -C "$TMP/pg-adm" fetch -q "$PGR" main && git -C "$TMP/pg-adm" push -q origin FETCH_HEAD:refs/heads/main 2>/dev/null \
        && git -C "$PGR" fetch -q origin
}
pg_mark() {  # name [ts]
    mkdir -p "$PGR/.git/monitorex-locks/plan-approved"
    printf 'ts=%s\nsha256=%s\nsession=s1\nplan=%s\n' "${2:-$(date +%s)}" "$(sha_of x)" "$1" > "$PGR/.git/monitorex-locks/plan-approved/$1"
}

pg_reset
pg_mc "$PGR" "[feat]: thing" a.txt v2 >/dev/null
out=$(pg_push "$PGR"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'plan gate: these commits need an approved plan' && echo "$out" | grep -q "no 'Plan: <file>.md' line" \
    && echo "$out" | grep -q 'why: commit type \[feat\]' && ok "[feat] without Plan: — rejected" || bad "[feat] without Plan:" "$out"
echo "$out" | grep -q 'saved to:' && bad "rejection does not print 'saved to:'" "$out" || ok "rejection does not print 'saved to:' (H6)"

# Policy comes from origin: an uncommitted config of the main working tree does nothing
for evil in 'exit 0' 'GG_PROTECTED="wt/x"' 'git(){ :; }' 'GG_PLAN_REQUIRED_TYPES="none"'; do
    cp "$PGR/.gitguards.conf" "$TMP/pg-conf.bak"; printf '%s\n' "$evil" > "$PGR/.gitguards.conf"
    out=$(pg_push "$PGR"); rc=$?; cp "$TMP/pg-conf.bak" "$PGR/.gitguards.conf"
    [ $rc -ne 0 ] && echo "$out" | grep -q 'plan gate' && ok "uncommitted main-tree config '$evil' has no effect" || bad "main-tree config '$evil'" "$out"
done
# … nor that of a linked worktree
PG_FEAT=$(git -C "$PGR" rev-parse HEAD)
git -C "$PGR" worktree add -q --detach "$TMP/pg-wt" "$PG_FEAT" 2>/dev/null
printf 'exit 0\nGG_PROTECTED="wt/x"\n' > "$TMP/pg-wt/.gitguards.conf"
out=$(pg_push "$TMP/pg-wt" wt/from-tree); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'plan gate' && ok "uncommitted linked-worktree config (exit 0, GG_PROTECTED) has no effect" || bad "worktree config" "$out"
git -C "$PGR" worktree remove -f "$TMP/pg-wt"
# … nor a weakened policy committed in the branch
pg_reset
printf 'GG_PLAN_REQUIRED_TYPES="none"\nGG_PLAN_REQUIRED_NEW=""\n' > "$PGR/.gitguards.conf"; git -C "$PGR" add .gitguards.conf
pg_commit_staged "$PGR" "[chore]: weaken"
pg_mc "$PGR" "[feat]: after weakening" a.txt w1 >/dev/null
out=$(pg_push "$PGR"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'why: commit type \[feat\]' && ok "GG_PLAN_REQUIRED_TYPES weakened in the branch's committed config — no effect" || bad "weakened types in branch" "$out"
git -C "$PGR" checkout -q -- . 2>/dev/null

for bad_plan in '../x.md' '/tmp/x.md' 'sub/x.md'; do
    pg_reset
    pg_mc "$PGR" "$(printf '[feat]: thing\n\nPlan: %s' "$bad_plan")" a.txt "p$PG_N" >/dev/null
    out=$(pg_push "$PGR"); rc=$?
    [ $rc -ne 0 ] && echo "$out" | grep -q 'invalid Plan: line' && ok "Plan: $bad_plan (a path) — rejected" || bad "Plan: $bad_plan" "$out"
done

pg_reset
pg_mc "$PGR" "$(printf '[feat]: thing\n\nPlan: p1.md')" a.txt v4 >/dev/null
out=$(pg_push "$PGR"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'plan file not found' && ok "Plan: names a missing file — rejected" || bad "missing plan file" "$out"
echo plan > "$GG_PLANS_DIR/p1.md"
out=$(pg_push "$PGR"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'no approval mark' && ok "plan without an approval mark — rejected" || bad "no approval mark" "$out"
pg_mark p1.md $(( NOW_TS - 31*86400 ))
out=$(pg_push "$PGR"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'expired' && ok "approval mark older than the TTL (30 days) — rejected" || bad "mark older than TTL" "$out"
pg_mark p1.md
out=$(pg_push "$PGR"); rc=$?
[ $rc -eq 0 ] && ok "plan + fresh approval mark — push goes through" || bad "plan + mark — push" "$out"

pg_reset
pg_mc "$PGR" "[Feat]: upper case type" a.txt u1 >/dev/null
out=$(pg_push "$PGR"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'why: commit type \[feat\]' && ok "[Feat] (upper case) — still needs a plan" || bad "[Feat] upper case" "$out"

# The date can be faked; only the exact SHA list exempts (C5-r2)
pg_reset
pg_mc "$PGR" "[feat]: old" a.txt v5 GIT_COMMITTER_DATE="2020-01-01T00:00:00" GIT_AUTHOR_DATE="2020-01-01T00:00:00" >/dev/null
out=$(pg_push "$PGR"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'plan gate' && ok "new [feat] with GIT_COMMITTER_DATE=2020 — rejected (C5-r2)" || bad "committer date 2020" "$out"
# A local remote on the repository itself exempts nothing (C1)
git -C "$PGR" remote add -f snapshot "$PGR" >/dev/null 2>&1
git -C "$PGR" rev-parse -q --verify "refs/remotes/snapshot/$PG_BR" >/dev/null || git -C "$PGR" fetch -q snapshot 2>/dev/null
out=$(pg_push "$PGR"); rc=$?
[ -z "$(git -C "$PGR" rev-list HEAD --not --remotes)" ] && [ $rc -ne 0 ] && echo "$out" | grep -q 'plan gate' \
    && ok "'git remote add -f snapshot .' (covers the commit for --remotes) does not exempt the [feat] (C1)" || bad "snapshot remote (C1)" "$out"
git -C "$PGR" remote remove snapshot
PG_EX=$(git -C "$PGR" rev-parse HEAD)
git -C "$PGR" checkout -q main
printf 'GG_PLAN_GATE_EXEMPT="%s"\n' "$PG_EX" >> "$PGR/.gitguards.conf"; git -C "$PGR" add .gitguards.conf
git -C "$PGR" -c core.hooksPath=/dev/null commit -qm "exempt"
pg_main
git -C "$PGR" checkout -q -B wt/exempt "$PG_EX"
out=$(pg_push "$PGR" wt/exempt); rc=$?
[ $rc -eq 0 ] && ok "SHA listed in GG_PLAN_GATE_EXEMPT — not checked (C5-r2)" || bad "GG_PLAN_GATE_EXEMPT" "$out"

pg_reset
pg_mc "$PGR" "[fix]: x" a.txt v6 >/dev/null
out=$(pg_push "$PGR"); rc=$?
[ $rc -eq 0 ] && ok "[fix] — no plan needed" || bad "[fix] — no plan" "$out"
pg_mc "$PGR" "[fix]: l5" a.txt l5 >/dev/null
cp "$PGR/.gitguards.conf" "$TMP/pg-conf.bak"
printf 'GG_REQUIRE_DEV_READY=1\nGG_DEV_READY_GLOBS=". -maxdepth 0 -exec touch %s ;"\n' "$TMP/pg-pwned" >> "$PGR/.gitguards.conf"
out=$(pg_push "$PGR" wt/l5); rc=$?; cp "$TMP/pg-conf.bak" "$PGR/.gitguards.conf"
[ $rc -eq 0 ] && [ ! -e "$TMP/pg-pwned" ] && ok "GG_DEV_READY_GLOBS with -exec in an uncommitted config — not executed (L5)" || bad "dev-ready globs from the tree (L5)" "$out"
pg_reset
pg_mc "$PGR" "[fix]: mig" supabase/migrations/002_b.sql 2 >/dev/null
out=$(pg_push "$PGR"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'why: new file supabase/migrations/002_b.sql' && ok "[fix] with a new migration — rejected" || bad "[fix] + new migration" "$out"
pg_reset
pg_mc "$PGR" "[fix]: mig edit" supabase/migrations/001_a.sql 1b >/dev/null
out=$(pg_push "$PGR"); rc=$?
[ $rc -eq 0 ] && ok "[fix] editing an existing migration — not 'new', passes" || bad "[fix] + edited migration" "$out"
pg_reset
git -C "$PGR" rm -q supabase/migrations/001_a.sql; pg_commit_staged "$PGR" "[fix]: drop mig"
out=$(pg_push "$PGR"); rc=$?
[ $rc -eq 0 ] && ok "[fix] deleting a migration — not 'new', passes" || bad "[fix] + deleted migration" "$out"
pg_reset
git -C "$PGR" mv supabase/migrations/001_a.sql supabase/migrations/003_a.sql; pg_commit_staged "$PGR" "[fix]: rename"
pre=$(git -C "$PGR" diff --name-only --diff-filter=A HEAD^ HEAD)    # with rename detection: nothing "added"
out=$(pg_push "$PGR"); rc=$?
[ -z "$pre" ] && [ $rc -ne 0 ] && echo "$out" | grep -q 'why: new file supabase/migrations/003_a.sql' && ok "migration renamed to a new number under [fix] — rejected (C2)" || bad "renamed migration (C2)" "$out"
pg_reset
pg_mc "$PGR" "[fix]: odd name" "supabase/migrations/010 ünï мигр.sql" 10 >/dev/null
out=$(pg_push "$PGR"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -qF 'why: new file supabase/migrations/010 ünï мигр.sql' && ok "new migration with a space and Unicode in the name — rejected, name shown as is" || bad "unicode migration name" "$out"

# Merges with main (H7)
pg_reset wt/m
pg_mc "$PGR" "[fix]: branch work" a.txt v7 >/dev/null
git -C "$PGR" checkout -q main; git -C "$PGR" reset -q --hard origin/main
echo 4 > "$PGR/supabase/migrations/004_main.sql"; git -C "$PGR" add -A
git -C "$PGR" -c core.hooksPath=/dev/null commit -qm "[feat]: main migration"
pg_main
git -C "$PGR" checkout -q wt/m
printf 'Merge main\n\nSession-Id: tst\n' > "$TMP/pg-msg"; git -C "$PGR" -c core.hooksPath=/dev/null merge -q --no-ff -F "$TMP/pg-msg" origin/main
pre=$(git -C "$PGR" diff --name-only --diff-filter=A HEAD^1 HEAD)   # what a first-parent check would see
out=$(pg_push "$PGR" wt/m); rc=$?
echo "$pre" | grep -q '004_main.sql' && [ $rc -eq 0 ] && ok "merge of main bringing a new migration into a [fix] branch — passes (H7)" || bad "merge main into [fix] (H7)" "$out"
git -C "$PGR" checkout -q -B wt/m2 "$(git -C "$PGR" rev-parse origin/main~1)"
pg_mc "$PGR" "[fix]: own mig" supabase/migrations/005_b.sql 5 >/dev/null
printf 'Merge main\n\nSession-Id: tst\n' > "$TMP/pg-msg"; git -C "$PGR" -c core.hooksPath=/dev/null merge -q --no-ff -F "$TMP/pg-msg" origin/main 2>/dev/null
out=$(pg_push "$PGR" wt/m2); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q '005_b.sql' && ok "own migration in the branch, then main merged in — rejected (H7)" || bad "own migration + merge main" "$out"

# The human bypass: one push
PGCONF="$PGR/.git/monitorex-locks/CONFIRM"
pg_reset
pg_mc "$PGR" "[feat]: bypass" a.txt v8 >/dev/null
printf 'target=feat\nts=x\n' > "$PGCONF"
out=$(pg_push "$PGR"); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'let through by a human mark' && [ ! -f "$PGCONF" ] \
    && ok "git-confirm.sh feat mark — one push goes through, the mark is used up" || bad "feat mark — one push" "$out"
pg_mc "$PGR" "[feat]: bypass2" a.txt v9 >/dev/null
out=$(pg_push "$PGR"); rc=$?
[ $rc -ne 0 ] && ok "next push without a mark — rejected" || bad "second push after the mark" "$out"
printf 'target=feat\n' > "$PGCONF"; touch -t 202001010000 "$PGCONF"
out=$(pg_push "$PGR"); rc=$?
[ $rc -ne 0 ] && ok "expired feat mark (older than 15 min) — rejected" || bad "expired feat mark" "$out"
rm -f "$PGCONF"

echo "== plan gate: barriers around it (PreToolUse guard) =="
gj() { python3 -c 'import json,sys; t,k,v,c=sys.argv[1:5]; print(json.dumps({"tool_name":t,"tool_input":{k:v},"cwd":c}))' "$@"; }
gcase() {   # label expect(deny|allow) project tool key value cwd
    local lbl="$1" exp="$2" proj="$3" o got; shift 3
    o=$(gj "$@" | CLAUDE_PROJECT_DIR="$proj" bash "$CH/monitorex-git-guard.sh" 2>/dev/null)
    case "$o" in *'"deny"'*) got=deny ;; *) got=allow ;; esac
    [ "$got" = "$exp" ] && ok "guard: $lbl — $exp" || bad "guard: $lbl — $exp" "got $got: $o"
}
PGL="$PGR/.git/monitorex-locks"
gcase "Write into .git/monitorex-locks/release-gate/<tree>" deny "$PGR" Write file_path "$PGL/release-gate/abc" "$PGR"
gcase "Write into monitorex-locks after cd /private/tmp (M5)" deny "$PGR" Write file_path "$PGL/release-gate/abc" /private/tmp
gcase "NotebookEdit via notebook_path into .git (M5)" deny "$PGR" NotebookEdit notebook_path "$PGL/x.ipynb" /private/tmp
gcase "Write of a plan-approved mark" deny "$PGR" Write file_path "$PGL/plan-approved/p1.md" "$PGR"
gcase "Bash echo > …/monitorex-locks/CONFIRM" deny "$PGR" Bash command "echo target=feat > $PGL/CONFIRM" "$PGR"
gcase "Bash rm in monitorex-locks/" deny "$PGR" Bash command "rm -rf .git/monitorex-locks/claims/issue-7" "$PGR"
gcase "git -c url.X.insteadOf=Y fetch origin (C1-r2)" deny "$PGR" Bash command "git -c url.X.insteadOf=Y fetch origin" "$PGR"
gcase "nice scripts/git-confirm.sh feat (L6)" deny "$PGR" Bash command "nice scripts/git-confirm.sh feat" "$PGR"
gcase "git remote set-head origin x" deny "$PGR" Bash command "git remote set-head origin x" "$PGR"
gcase "Write …/memory/x.md (H6: memory stays writable)" allow "$PGR" Write file_path "$TMP/home/.claude/projects/-p/memory/x.md" /private/tmp
gcase "Write lib/x.ts in the project" allow "$PGR" Write file_path "$PGR/lib/x.ts" "$PGR"
gcase "git push with installed hooks equal to origin" allow "$PGR" Bash command "git push origin HEAD" "$PGR"
echo '# rolled back by an old tree' >> "$PGH/pre-push"
gcase "git push with installed pre-push differing from origin (H4)" deny "$PGR" Bash command "git push origin HEAD" "$PGR"
bash "$PGR/scripts/install-git-guards.sh" >/dev/null 2>&1
gcase "git push after reinstalling from origin" allow "$PGR" Bash command "git push origin HEAD" "$PGR"

# Policy without any plan keys on origin → no gate at all (projects that never opted in)
{ grep -v '^GG_PLAN_' "$PGR/.gitguards.conf"
  printf 'GG_REQUIRE_DEV_READY=1\nGG_DEV_READY_GLOBS=". -maxdepth 0 -exec touch %s ;"\n' "$TMP/pg-pwned2"; } > "$TMP/pg-conf.new"
git -C "$PGR" checkout -q main; cp "$TMP/pg-conf.new" "$PGR/.gitguards.conf"; git -C "$PGR" add .gitguards.conf
git -C "$PGR" -c core.hooksPath=/dev/null commit -qm "no plan gate"; pg_main
pg_reset
pg_mc "$PGR" "[feat]: no gate configured" a.txt off1 >/dev/null
out=$(pg_push "$PGR"); rc=$?
[ $rc -eq 0 ] && ! echo "$out" | grep -q 'plan gate' && ok "no GG_PLAN_* keys in the policy — no plan check (backward compatible)" || bad "no plan keys — no check" "$out"
[ ! -e "$TMP/pg-pwned2" ] && echo "$out" | grep -q 'invalid GG_DEV_READY_GLOBS' && ok "GG_DEV_READY_GLOBS with -exec in origin's policy — rejected by the value check, not executed (L5)" || bad "dev-ready globs on origin (L5)" "$out"

echo "== plan gate: early check (safe-commit, message-file mode) =="
# back to a policy with the plan keys (one commit back), published as origin/main
git -C "$PGR" checkout -q main; git -C "$PGR" reset -q --hard "$(git -C "$PGR" rev-parse origin/main~1)"
git -C "$TMP/pg-adm" fetch -q "$PGR" main && git -C "$TMP/pg-adm" push -q -f origin FETCH_HEAD:refs/heads/main 2>/dev/null
git -C "$PGR" fetch -q origin
pg_reset
echo w > "$PGR/a.txt"; printf '[feat]: early\n' > "$TMP/pg-m1"
out=$( cd "$PGR" && MONITOREX_ACTOR=tst CLAUDE_CODE_SESSION_ID= MONITOREX_SKIP_TESTS=1 bash scripts/git-safe-commit.sh --message-file "$TMP/pg-m1" -- a.txt 2>&1 ); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'plan gate' && ok "safe-commit: [feat] without Plan: — refused early" || bad "safe-commit early [feat]" "$out"
printf '[fix]: early\n' > "$TMP/pg-m1"; echo 9 > "$PGR/supabase/migrations/009_x.sql"
out=$( cd "$PGR" && MONITOREX_ACTOR=tst CLAUDE_CODE_SESSION_ID= MONITOREX_SKIP_TESTS=1 bash scripts/git-safe-commit.sh --message-file "$TMP/pg-m1" -- supabase/migrations 2>&1 ); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'new file supabase/migrations/009_x.sql' && ok "safe-commit: new migration (directory pathspec, decided by HEAD, not the index) — refused" || bad "safe-commit new migration" "$out"
rm -f "$PGR/supabase/migrations/009_x.sql"
printf '[feat]: early\n\nPlan: p1.md\n' > "$TMP/pg-m1"
out=$( cd "$PGR" && MONITOREX_ACTOR=tst CLAUDE_CODE_SESSION_ID= MONITOREX_SKIP_TESTS=1 bash scripts/git-safe-commit.sh --message-file "$TMP/pg-m1" -- a.txt 2>&1 ); rc=$?
[ $rc -eq 0 ] && ok "safe-commit: plan + approval mark — committed" || bad "safe-commit with plan" "$out"

# Type parsing and masks — plan-gate.sh directly, policy from the main working tree (no origin)
PGT="$TMP/pgt"; mkrepo "$PGT"; mkdir -p "$PGT/supabase/migrations"
printf 'GG_PLAN_REQUIRED_TYPES="feat, perf"\nGG_PLAN_REQUIRED_NEW="supabase/migrations/*.sql"\n' > "$PGT/.gitguards.conf"
pgt() { printf '%s\n' "$1" > "$TMP/pgt-msg"; shift; ( cd "$PGT" && sh "$ROOT/githooks/plan-gate.sh" "$TMP/pgt-msg" "$@" ) >/dev/null 2>&1; }
for first in '[Feat]: x' ' feat: x' 'FEAT(ui)!: x' '[perf]: x' '  [feat] : x'; do
    pgt "$first"; rc=$?
    [ $rc -eq 1 ] && ok "type '$first' — needs a plan (case, spaces, scope, several types)" || bad "type '$first'" "rc=$rc"
done
for first in '[fix]: x' 'feature: x' 'docs: feat in text'; do
    pgt "$first"; rc=$?
    [ $rc -eq 0 ] && ok "type '$first' — no plan needed" || bad "type '$first' — no plan" "rc=$rc"
done
echo 1 > "$PGT/supabase/migrations/1 ünï.sql"
pgt '[fix]: x' supabase/migrations; rc=$?
[ $rc -eq 1 ] && ok "early: untracked migration with a space and Unicode — needs a plan" || bad "early unicode migration" "rc=$rc"
pgt "$(printf '[feat]: x\n\nPlan: /abs/p1.md')"; rc=$?
[ $rc -eq 1 ] && ok "early: absolute Plan: path — rejected" || bad "early absolute Plan:" "rc=$rc"
( cd "$PGT" && sh "$ROOT/githooks/plan-gate.sh" --get GG_PLAN_REQUIRED_TYPES ) 2>/dev/null | grep -qx 'feat, perf' \
    && ok "plan-gate.sh --get reads the policy" || bad "plan-gate.sh --get"
# GG_PLAN_GATE empty → safe-commit does not call any gate (backward compatibility)
PGE="$TMP/pge"; mkrepo "$PGE"; printf 'GG_PLAN_GATE=""\n' > "$PGE/.gitguards.conf"
echo v2 > "$PGE/a.txt"
out=$(commit "$PGE" "[feat]: no gate" a.txt); rc=$?
[ $rc -eq 0 ] && ! echo "$out" | grep -q 'plan gate' && ok "GG_PLAN_GATE empty — safe-commit runs no gate" || bad "GG_PLAN_GATE empty" "$out"
# The canonical plan-gate.sh plugs into the same GG_PLAN_GATE contract
PGK="$TMP/pgk"; mkrepo "$PGK"; mkdir -p "$PGK/githooks"; cp "$ROOT/githooks/plan-gate.sh" "$PGK/githooks/"
printf 'GG_PLAN_GATE="githooks/plan-gate.sh"\nGG_PLAN_REQUIRED_TYPES="feat"\n' > "$PGK/.gitguards.conf"
git -C "$PGK" add -A; git -C "$PGK" commit -qm gate
echo v2 > "$PGK/a.txt"
out=$(commit "$PGK" "[feat]: canonical" a.txt); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "no 'Plan: <file>.md' line" && ok "canonical plan-gate.sh through GG_PLAN_GATE — refuses [feat] without a plan" || bad "canonical gate via GG_PLAN_GATE" "$out"
out=$(commit "$PGK" "[fix]: canonical" a.txt); rc=$?
[ $rc -eq 0 ] && ok "canonical plan-gate.sh through GG_PLAN_GATE — lets [fix] through" || bad "canonical gate [fix]" "$out"

echo "== plan-approved.sh: the approval mark (PostToolUse ExitPlanMode) =="
PA="$TMP/pa"; git init -q "$PA"; git -C "$PA" config user.email t@t; git -C "$PA" config user.name t
PAM="$PA/.git/monitorex-locks/plan-approved"
mkdir -p "$TMP/pa-out"
PA_GOOD=$'# План\n\n## 🧑‍⚖️ Внешнее ревью Codex — раунд 1\n\nГейт: ✅ пройден — ok\n'
PA_EN=$'# Plan\n\n## External review Codex\n\nGate: ✅ passed\n'
pa_in() {   # name plan isAgent [extra-json] [filePath]
    python3 -c 'import json,sys
n,plan,ia,extra,fp=sys.argv[1:6]
d={"session_id":"sess-1","transcript_path":"/x.jsonl","cwd":"/tmp","hook_event_name":"PostToolUse",
   "permission_mode":"default","tool_name":"ExitPlanMode","tool_input":{},"tool_use_id":"toolu_1",
   "tool_response":{"filePath":fp,"plan":plan,"isAgent":ia=="true","hasTaskTool":True}}
d.update(json.loads(extra or "{}"))
print(json.dumps(d))' "$1" "$2" "$3" "${4:-}" "${5:-$GG_PLANS_DIR/$1}"
}
pa_run() { pa_in "$@" | CLAUDE_PROJECT_DIR="$PA" bash "$CH/plan-approved.sh"; }
pa_block() { python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("decision")=="block" else 1)' 2>/dev/null; }
for n in good.md en.md nocodex.md nogate.md agent.md agentid.md only.md; do echo plan > "$GG_PLANS_DIR/$n"; done
out=$(pa_run good.md "$PA_GOOD" false)
[ -z "$out" ] && grep -q '^ts=[0-9]*$' "$PAM/good.md" && grep -q '^session=sess-1$' "$PAM/good.md" \
    && grep -q "^sha256=$(sha_of "$PA_GOOD")$" "$PAM/good.md" && grep -q '^plan=good.md$' "$PAM/good.md" \
    && ok "approved plan with a Codex section and the gate line — mark written, sha256 of tool_response.plan" || bad "approved plan — mark" "$out $(cat "$PAM/good.md" 2>&1)"
out=$(pa_run en.md "$PA_EN" false)
[ -f "$PAM/en.md" ] && ok "English 'Gate: ✅ passed' — mark written" || bad "English gate line" "$out"
out=$(pa_run nocodex.md $'# P\n\nГейт: ✅ пройден\n' false)
[ ! -f "$PAM/nocodex.md" ] && echo "$out" | grep -q 'Codex' && echo "$out" | pa_block \
    && ok "no Codex section — no mark, the reason goes to the model" || bad "no Codex section" "$out"
out=$(pa_run nogate.md $'# P\n\n## Codex\n' false)
[ ! -f "$PAM/nogate.md" ] && echo "$out" | grep -q 'NOT written' && ok "no gate line — no mark" || bad "no gate line" "$out"
out=$(pa_run agent.md "$PA_GOOD" true)
[ ! -f "$PAM/agent.md" ] && echo "$out" | grep -q 'inside an agent' && ok "isAgent: true — no mark (M8)" || bad "isAgent: true" "$out"
out=$(pa_run agentid.md "$PA_GOOD" false '{"agent_id":"a1","agent_type":"x"}')
[ ! -f "$PAM/agentid.md" ] && ok "agent_id in the hook input — no mark (M8)" || bad "agent_id in input" "$out"
echo p > "$TMP/pa-out/evil.md"
out=$(pa_run evil.md "$PA_GOOD" false "" "$TMP/pa-out/evil.md")
[ ! -f "$PAM/evil.md" ] && echo "$out" | grep -q 'directly in' && ok "plan file outside the plans directory — no mark" || bad "outside plans dir" "$out"
ln -s "$TMP/pa-out/evil.md" "$GG_PLANS_DIR/link.md"
out=$(pa_run link.md "$PA_GOOD" false)
[ ! -f "$PAM/link.md" ] && [ ! -f "$PAM/evil.md" ] && ok "symlink in the plans directory pointing out — no mark" || bad "symlink out" "$out"
rm -f "$GG_PLANS_DIR/link.md"
out=$(python3 -c 'import json,sys; print(json.dumps({"session_id":"s","tool_name":"ExitPlanMode","tool_input":{"planFilePath":sys.argv[1],"plan":sys.argv[2]},"tool_response":{"isAgent":False}}))' \
      "$GG_PLANS_DIR/only.md" "$PA_GOOD" | CLAUDE_PROJECT_DIR="$PA" bash "$CH/plan-approved.sh")
[ ! -f "$PAM/only.md" ] && ok "only tool_input.planFilePath (set by the model) — no mark (M8)" || bad "planFilePath only" "$out"
out=$(printf 'not json' | CLAUDE_PROJECT_DIR="$PA" bash "$CH/plan-approved.sh"); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "broken JSON — exit 0, silent" || bad "broken JSON" "rc=$rc $out"
out=$(printf '{"tool_name":"Bash","tool_response":{}}' | CLAUDE_PROJECT_DIR="$PA" bash "$CH/plan-approved.sh")
[ -z "$out" ] && ok "another tool — silent" || bad "another tool" "$out"
mkdir -p "$TMP/pa-norepo"
out=$(pa_in good.md "$PA_GOOD" false | CLAUDE_PROJECT_DIR="$TMP/pa-norepo" bash "$CH/plan-approved.sh"); rc=$?
[ $rc -eq 0 ] && ok "project is not a git repository — exit 0" || bad "no repository" "rc=$rc $out"
git -C "$PA" commit -q --allow-empty -m i; git -C "$PA" worktree add -q "$TMP/pa-wt" -b w 2>/dev/null
echo p > "$GG_PLANS_DIR/wt.md"
out=$(pa_in wt.md "$PA_GOOD" false | CLAUDE_PROJECT_DIR="$TMP/pa-wt" bash "$CH/plan-approved.sh")
[ -f "$PAM/wt.md" ] && ok "session in a worktree — mark goes to the shared common dir" || bad "worktree session mark" "$out"
mkdir -p "$PA/githooks"; cp "$ROOT/githooks/plan-gate.sh" "$PA/githooks/"; printf 'GG_PLAN_REQUIRED_TYPES="feat"\n' > "$PA/.gitguards.conf"
printf '[feat]: x\n\nPlan: good.md\n' > "$TMP/pa-m"
( cd "$PA" && sh githooks/plan-gate.sh "$TMP/pa-m" ) >/dev/null 2>&1 && ok "end to end: plan-gate.sh accepts the hook's mark" || bad "end to end: hook mark accepted"
printf '[feat]: x\n\nPlan: nocodex.md\n' > "$TMP/pa-m"
out=$( cd "$PA" && sh githooks/plan-gate.sh "$TMP/pa-m" 2>&1 ); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q 'no approval mark' && ok "end to end: a plan the hook refused is rejected by plan-gate.sh" || bad "end to end: refused plan" "$out"

echo "== PreToolUse guard: unit cases (test_pretooluse_guard.py) =="
if [ -d "$ROOT/.claude/hooks" ]; then
    out=$(python3 -B "$ROOT/scripts/git-guards/test_pretooluse_guard.py" 2>&1); rc=$?
else                            # the kit: assemble the project layout the test expects
    GLY="$TMP/guard-layout"; mkdir -p "$GLY/.claude/hooks" "$GLY/scripts/git-guards"
    cp "$CH"/* "$GLY/.claude/hooks/"; cp "$ROOT"/scripts/git-guards/*.py "$ROOT"/scripts/git-guards/*.sh "$GLY/scripts/git-guards/"
    out=$(cd "$GLY" && python3 -B "$GLY/scripts/git-guards/test_pretooluse_guard.py" 2>&1); rc=$?
fi
summary=$(printf '%s\n' "$out" | grep -E 'passed: [0-9]+' | tail -1 | sed 's/^ *//')
[ $rc -eq 0 ] && ok "guard unit cases — $summary" || bad "guard unit cases" "$(printf '%s\n' "$out" | grep -E 'FAIL|passed' | head -20)"

echo "== wt-new --resume: an old branch brings old guards (M10) =="
RSO="$TMP/rs.git"; git init -q --bare "$RSO"; git -C "$RSO" symbolic-ref HEAD refs/heads/main
RS="$TMP/rs"; git init -q "$RS"; git -C "$RS" symbolic-ref HEAD refs/heads/main
git -C "$RS" config user.email t@t; git -C "$RS" config user.name t
kit_copy "$RS"; echo a > "$RS/a.txt"; git -C "$RS" add -A; git -C "$RS" commit -qm init
git -C "$RS" remote add origin "$RSO"; git -C "$RS" push -q origin main 2>/dev/null; git -C "$RS" fetch -q origin
git -C "$RS" branch wt/old
git -C "$RS" checkout -q wt/old; echo old > "$RS/b.txt"; git -C "$RS" add b.txt; git -C "$RS" commit -qm "old work"; git -C "$RS" checkout -q main
echo '# guards v2' >> "$RS/scripts/install-git-guards.sh"; git -C "$RS" commit -qam "guards v2"; git -C "$RS" push -q origin main 2>/dev/null
out=$(bash "$RS/scripts/wt-new.sh" --resume wt/old 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q 'carries outdated guards' && echo "$out" | grep -q 'scripts/install-git-guards.sh' \
    && [ ! -d "$TMP/rs-wt/old" ] && ok "--resume of a branch with an old installer — refused, no tree" || bad "--resume outdated guards" "$out"
out=$(bash "$RS/scripts/wt-new.sh" --resume wt/old --merge-main 2>&1); rc=$?
[ $rc -eq 0 ] && cmp -s "$TMP/rs-wt/old/scripts/install-git-guards.sh" "$RS/scripts/install-git-guards.sh" \
    && [ -f "$TMP/rs-wt/old/b.txt" ] && ok "--resume … --merge-main — origin/main merged in, tree created" || bad "--resume --merge-main" "$out"
out=$(bash "$RS/scripts/wt-new.sh" t-mm --merge-main 2>&1); rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q -- '--merge-main only works with --resume' && ok "--merge-main without --resume — usage error" || bad "--merge-main alone" "rc=$rc $out"

echo "== wt-new --issue: local claim of a GitHub issue =="
GHB="$TMP/ghbin"; mkdir -p "$GHB"
cat > "$GHB/gh" <<'STUB'
#!/bin/sh
# gh stub: `gh issue view N --repo R --json …`; behaviour from GH_STUB, title from GH_TITLE
echo "$*" >> "${GH_LOG:-/dev/null}"
case "${GH_STUB:-open}" in
    open)     printf '{"number":%s,"title":"%s","state":"OPEN"}\n' "$3" "${GH_TITLE:-Fix the login}" ;;
    closed)   printf '{"number":%s,"title":"Old one","state":"CLOSED"}\n' "$3" ;;
    notfound) echo "GraphQL: Could not resolve to an issue or pull request with the number of $3. (repository.issue)" >&2; exit 1 ;;
    noauth)   echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4 ;;
    hang)     sleep 30 ;;
esac
STUB
printf '#!/bin/sh\nexit 1\n' > "$GHB/orca"         # wt-done.sh must not touch a real Orca
chmod +x "$GHB/gh" "$GHB/orca"
ISO="$TMP/gh/acme/proj.git"; mkdir -p "$TMP/gh/acme"; git init -q --bare "$ISO"; git -C "$ISO" symbolic-ref HEAD refs/heads/main
IW="$TMP/iw"; git init -q "$IW"; git -C "$IW" symbolic-ref HEAD refs/heads/main
git -C "$IW" config user.email t@t; git -C "$IW" config user.name t
kit_copy "$IW"; echo a > "$IW/a.txt"; printf 'GG_ISSUE_TIMEOUT=2\n' > "$IW/.gitguards.conf"
git -C "$IW" add -A; git -C "$IW" commit -qm init
git -C "$IW" remote add origin "$ISO"; git -C "$IW" push -q origin main 2>/dev/null; git -C "$IW" fetch -q origin
CLM="$IW/.git/monitorex-locks/claims"
iw() { env PATH="$GHB:$PATH" GH_LOG="$TMP/gh.log" "$@"; }        # iw [VAR=…] bash wt-new.sh …

for badn in '07' '../5' '0' '12345678' '-5'; do
    out=$(iw bash "$IW/scripts/wt-new.sh" --issue "$badn" 2>&1); rc=$?
    [ $rc -eq 2 ] && echo "$out" | grep -q -- '--issue expects an issue number' && ok "--issue '$badn' — refused (L3)" || bad "--issue '$badn'" "rc=$rc $out"
done
out=$(iw bash "$IW/scripts/wt-new.sh" --issue 5 --resume wt/x 2>&1); rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q -- '--issue cannot be combined with --resume' && ok "--issue together with --resume — refused" || bad "--issue + --resume" "rc=$rc $out"

: > "$TMP/gh.log"
out=$(iw GH_STUB=open bash "$IW/scripts/wt-new.sh" --issue 5 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'issue #5 claimed → wt/5-fix-the-login' && git -C "$IW" rev-parse -q --verify wt/5-fix-the-login >/dev/null \
    && [ -d "$TMP/iw-wt/5-fix-the-login" ] && ok "open issue — claimed, branch wt/5-<title-slug>, tree created" || bad "open issue — claim" "$out"
own_ok=1; for k in issue branch tree time pid nonce title; do grep -q "^$k=" "$CLM/issue-5/owner" 2>/dev/null || own_ok=0; done
[ $own_ok = 1 ] && grep -qx 'branch=wt/5-fix-the-login' "$CLM/issue-5/owner" && ok "claim owner file has issue/branch/tree/time/pid/nonce/title" || bad "owner file" "$(cat "$CLM/issue-5/owner" 2>&1)"
grep -q -- '--repo acme/proj' "$TMP/gh.log" && ok "gh is asked with an explicit --repo from origin (L3)" || bad "gh --repo" "$(cat "$TMP/gh.log")"
out=$(iw GH_STUB=open bash "$IW/scripts/wt-new.sh" --issue 5 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q 'issue #5 is already taken:' && echo "$out" | grep -q -- '--resume wt/5-fix-the-login' \
    && ok "second claim of the same issue — refused with a --resume hint (living tree without commits is not taken over)" || bad "second claim" "$out"
out=$(bash "$IW/scripts/wt-status.sh" 2>&1)
echo "$out" | grep -q '#5' && echo "$out" | grep -q 'wt/5-fix-the-login' && ok "wt-status shows the claimed issue" || bad "wt-status claims" "$out"

out=$(iw GH_STUB=closed bash "$IW/scripts/wt-new.sh" --issue 6 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q 'issue #6 is closed' && [ ! -e "$CLM/issue-6" ] && ok "closed issue — refused, nothing claimed" || bad "closed issue" "$out"
out=$(iw GH_STUB=notfound bash "$IW/scripts/wt-new.sh" --issue 6 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q 'not found in acme/proj' && [ ! -e "$CLM/issue-6" ] && ok "issue not found — refused" || bad "issue not found" "$out"
out=$(iw GH_STUB=noauth bash "$IW/scripts/wt-new.sh" --issue 6 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q 'gh is not authenticated' && ok "gh not authenticated — refused with gh auth login" || bad "gh noauth" "$out"
T0=$SECONDS; out=$(iw GH_STUB=hang bash "$IW/scripts/wt-new.sh" --issue 6 2>&1); rc=$?; T=$((SECONDS-T0))
[ $rc -eq 1 ] && [ $T -lt 12 ] && echo "$out" | grep -q 'did not answer within 2s' && ok "hanging gh — cut off by GG_ISSUE_TIMEOUT (${T}s)" || bad "hanging gh" "rc=$rc ${T}s $out"
NOGH="$TMP/nogh"; mkdir -p "$NOGH"
for t in git python3; do ln -sf "$(command -v $t)" "$NOGH/$t"; done
out=$(env PATH="$NOGH:/usr/bin:/bin:/usr/sbin:/sbin" bash "$IW/scripts/wt-new.sh" --issue 6 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q 'gh (GitHub CLI) not found' && ok "no gh in PATH — refused with an install hint" || bad "no gh" "$out"

out=$(iw GH_STUB=open GH_TITLE='Исправить вход 🚀 Login page' bash "$IW/scripts/wt-new.sh" --issue 20 2>&1); rc=$?
[ $rc -eq 0 ] && git -C "$IW" rev-parse -q --verify wt/20-login-page >/dev/null && ok "title with Cyrillic and emoji — slug keeps [a-z0-9-] only" || bad "cyrillic slug" "$out"
out=$(iw GH_STUB=open GH_TITLE='Только кириллица 🚀' bash "$IW/scripts/wt-new.sh" --issue 21 2>&1); rc=$?
[ $rc -eq 0 ] && git -C "$IW" rev-parse -q --verify wt/21-issue >/dev/null && ok "title without Latin letters — slug 'issue'" || bad "empty slug" "$out"
LONGT='A very long issue title that goes on and on well past forty characters'
out=$(iw GH_STUB=open GH_TITLE="$LONGT" bash "$IW/scripts/wt-new.sh" --issue 22 2>&1); rc=$?
LB=$(git -C "$IW" for-each-ref --format='%(refname:short)' 'refs/heads/wt/22-*')
[ $rc -eq 0 ] && [ -n "$LB" ] && [ ${#LB} -le $((6 + 40)) ] && ! echo "$LB" | grep -q -- '-$' && ok "long title — slug at most 40 characters ($LB)" || bad "long slug" "$LB $out"

# Two claims at once — exactly one wins
for i in 1 2; do ( iw GH_STUB=open GH_TITLE=Race bash "$IW/scripts/wt-new.sh" --issue 8 > "$TMP/race$i.log" 2>&1; echo $? > "$TMP/race$i.rc" ) & done; wait
wins=0; for i in 1 2; do [ "$(cat "$TMP/race$i.rc")" = 0 ] && wins=$((wins+1)); done
[ $wins -eq 1 ] && ok "two parallel claims of one issue — exactly one succeeds" || bad "parallel claims" "wins=$wins $(cat "$TMP/race1.log" "$TMP/race2.log")"

# A stale claim (owner gone, no tree, no branch) — two takeovers at once, exactly one wins
stale_claim() {   # N branch
    mkdir -p "$CLM/issue-$1"
    printf 'issue=%s\nbranch=%s\ntree=%s\ntime=1\npid=%s\nnonce=dead%s\ntitle=x\n' "$1" "$2" "$TMP/nowhere" "$(dead_pid)" "$1" > "$CLM/issue-$1/owner"
    touch -t 202001010000 "$CLM/issue-$1"
}
stale_claim 9 wt/9-gone
for i in 1 2; do ( iw GH_STUB=open GH_TITLE=Nine bash "$IW/scripts/wt-new.sh" --issue 9 > "$TMP/to$i.log" 2>&1; echo $? > "$TMP/to$i.rc" ) & done; wait
wins=0; for i in 1 2; do [ "$(cat "$TMP/to$i.rc")" = 0 ] && wins=$((wins+1)); done
[ $wins -eq 1 ] && grep -q 'stale claim of issue #9 taken over' "$TMP/to1.log" "$TMP/to2.log" \
    && ok "two parallel takeovers of a stale claim — exactly one succeeds (M7)" || bad "parallel takeovers" "wins=$wins $(cat "$TMP/to1.log" "$TMP/to2.log")"

# The tree of a claim removed → the claim is stale and taken over
git -C "$IW" worktree remove --force "$TMP/iw-wt/5-fix-the-login"
out=$(iw GH_STUB=open bash "$IW/scripts/wt-new.sh" --issue 5 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'stale claim of issue #5 taken over' && [ -d "$TMP/iw-wt/5-fix-the-login" ] \
    && ok "claim whose tree was removed — taken over, branch recreated" || bad "removed tree takeover" "$out"

# git worktree add fails → the claim is released
git -C "$IW" branch wt/10-ten main; git -C "$IW" checkout -q wt/10-ten
echo ten > "$IW/ten.txt"; git -C "$IW" add ten.txt; git -C "$IW" -c core.hooksPath=/dev/null commit -qm ten; git -C "$IW" checkout -q main
out=$(iw GH_STUB=open GH_TITLE=Ten bash "$IW/scripts/wt-new.sh" --issue 10 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q 'claim of issue #10 released (the tree was not created)' && [ ! -e "$CLM/issue-10" ] \
    && ok "git worktree add fails — the claim is released" || bad "worktree add failure releases claim" "$out"

# An abandoned takeover mutex (dead pid, old) is removed (L7); a live one blocks
stale_claim 11 wt/11-gone
mkdir -p "$CLM/issue-11.takeover"; echo "$$" > "$CLM/issue-11.takeover/pid"
out=$(iw GH_STUB=open GH_TITLE=Eleven bash "$IW/scripts/wt-new.sh" --issue 11 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q 'a takeover of issue #11 is already in progress' && ok "takeover mutex held by a live process — refused" || bad "live takeover mutex" "$out"
dead_pid > "$CLM/issue-11.takeover/pid"; touch -t 202001010000 "$CLM/issue-11.takeover"
out=$(iw GH_STUB=open GH_TITLE=Eleven bash "$IW/scripts/wt-new.sh" --issue 11 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'removed an abandoned takeover lock' && [ ! -e "$CLM/issue-11.takeover" ] \
    && ok "takeover mutex with a dead pid — removed, takeover proceeds (L7)" || bad "dead takeover mutex" "$out"

# wt-done releases only its own claim
out=$(iw GH_STUB=open GH_TITLE=Twelve bash "$IW/scripts/wt-new.sh" --issue 12 2>&1)
mkdir -p "$CLM/issue-13"; printf 'issue=13\nbranch=wt/someone-else\ntree=x\ntime=1\npid=1\nnonce=n\ntitle=x\n' > "$CLM/issue-13/owner"
out=$(iw bash "$IW/scripts/wt-done.sh" 12-twelve 2>&1); rc=$?
[ $rc -eq 0 ] && [ ! -e "$CLM/issue-12" ] && [ -d "$CLM/issue-13" ] && echo "$out" | grep -q 'issue #12 released' \
    && ok "wt-done releases its own claim and leaves someone else's" || bad "wt-done claim release" "$out"

echo "== post-edit-tests: related tests right after an edit (PostToolUse) =="
PE="$TMP/pe"; mkrepo "$PE"; mkdir -p "$PE/lib" "$PE/dir x"
echo 'export const a = 1' > "$PE/lib/a.ts"; echo 'b' > "$PE/dir x/a b.ts"; echo md > "$PE/notes.md"
git -C "$PE" add -A; git -C "$PE" commit -qm src
PESTUB="$TMP/pe-stub.sh"; PECALLS="$TMP/pe-calls"; PEMODE="$TMP/pe-mode"
cat > "$PESTUB" <<STUB
#!/bin/sh
# test-runner stub: logs every call, behaviour from \$PEMODE
printf 'CALL %s\n' "\$#" >> "$PECALLS"; for a in "\$@"; do printf 'ARG %s\n' "\$a" >> "$PECALLS"; done
case "\$(cat "$PEMODE" 2>/dev/null)" in
    red) i=1; while [ \$i -le 60 ]; do echo "line \$i"; i=\$((i+1)); done
         printf '\033[31mFAIL\033[0m key sk-abcdefghijklmnopqrstuv sb_secret_AbCd1234 ghp_abcdefghijklmnopqrstu end-of-run\n'; exit 1 ;;
    notests) echo "No test files found, exiting with code 1"; exit 1 ;;
    sleep) sleep 30 & echo \$! > "$TMP/pe-child"; wait; exit 1 ;;
    *) echo "all green"; exit 0 ;;
esac
STUB
pe_conf() {   # extra lines for .gitguards.conf of the main working tree (no origin → policy from it)
    { printf 'GG_POST_EDIT_TESTS=1\nGG_TEST_CMD="sh %s"\nGG_POST_EDIT_DEBOUNCE=0\nGG_POST_EDIT_REPO_GAP=0\n' "$PESTUB"; printf '%s\n' "$@"; } > "$PE/.gitguards.conf"
}
pe_in() { python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[3] if len(sys.argv)>3 else "Edit","tool_input":{"file_path":sys.argv[1]},"cwd":sys.argv[2]}))' "$@"; }
pe_run() {    # file [cwd] [project]
    pe_in "$1" "${2:-$PE}" | CLAUDE_PROJECT_DIR="${3:-$PE}" bash "$CH/post-edit-tests.sh"
}
pe_calls() { grep -c '^CALL' "$PECALLS" 2>/dev/null || true; }
pe_reset() { : > "$PECALLS"; rm -rf "$PE/.git/post-edit-tests" "$PE/.git/monitorex-locks/post-edit-run" "$PE/.git/monitorex-locks/post-edit-last"; }
PEQ="$PE/.git/post-edit-tests/pending"

pe_conf; pe_reset; echo red > "$PEMODE"
out=$(pe_run "$PE/lib/a.ts"); rc=$?
tl=$(printf '%s' "$out" | python3 -c 'import json,sys
d=json.load(sys.stdin); r=d["reason"]
assert d["decision"]=="block"
n=sum(1 for l in r.split("\n") if l.startswith("line "))
print(n, "line 60" in r, "line 20\n" in r, "sk-abc" in r or "sb_secret_Ab" in r or "ghp_abc" in r, "\x1b" in r, "end-of-run" in r)' 2>/dev/null)
[ $rc -eq 0 ] && [ "$(pe_calls)" = 1 ] && [ "$tl" = "39 True False False False True" ] \
    && ok "red run — block with the last 40 lines, secrets masked, ANSI removed (L4)" || bad "red run block" "tail=[$tl] rc=$rc $out"
pe_reset; echo green > "$PEMODE"
out=$(pe_run "$PE/lib/a.ts")
[ -z "$out" ] && [ "$(pe_calls)" = 1 ] && grep -qx 'ARG lib/a.ts' "$PECALLS" && ok "green run — silent, the file passed as an argument" || bad "green run" "$out $(cat "$PECALLS")"
pe_reset; echo notests > "$PEMODE"
out=$(pe_run "$PE/lib/a.ts")
[ -z "$out" ] && [ "$(pe_calls)" = 1 ] && ok "'No test files found' with rc≠0 — silent" || bad "no test files" "$out"
echo green > "$PEMODE"
pe_conf 'GG_POST_EDIT_TESTS=0'; pe_reset; out=$(pe_run "$PE/lib/a.ts")
[ "$(pe_calls)" = 0 ] && ok "GG_POST_EDIT_TESTS=0 — runner not called" || bad "flag off"
printf 'GG_POST_EDIT_TESTS=1\nGG_TEST_CMD=""\nGG_POST_EDIT_DEBOUNCE=0\n' > "$PE/.gitguards.conf"; pe_reset; out=$(pe_run "$PE/lib/a.ts")
[ "$(pe_calls)" = 0 ] && ok "empty test command — runner not called" || bad "empty command"
pe_conf; pe_reset
out=$(pe_run "$PE/notes.md")
[ "$(pe_calls)" = 0 ] && ok "file outside the mask (*.md) — runner not called" || bad "outside mask"
mkdir -p "$TMP/pe-elsewhere"; echo x > "$TMP/pe-elsewhere/x.ts"
out=$(pe_run "$TMP/pe-elsewhere/x.ts")
[ "$(pe_calls)" = 0 ] && ok "file outside the project's trees — runner not called" || bad "outside tree"
PEF="$TMP/pe-foreign"; mkrepo "$PEF"; echo x > "$PEF/f.ts"
printf 'GG_POST_EDIT_TESTS=1\nGG_TEST_CMD="sh %s"\n' "$PESTUB" > "$PEF/.gitguards.conf"
out=$(pe_run "$PEF/f.ts" "$PEF")
[ "$(pe_calls)" = 0 ] && ok "file in a foreign repository (its own config names a command) — no run (H2)" || bad "foreign repo"
out=$(pe_run "$PE/dir x/a b.ts")
[ "$(pe_calls)" = 1 ] && grep -qx 'ARG dir x/a b.ts' "$PECALLS" && ok "path with a space — passed as ONE argument" || bad "path with space" "$(cat "$PECALLS")"

pe_conf 'GG_POST_EDIT_DEBOUNCE=20'; pe_reset
pe_run "$PE/lib/a.ts" >/dev/null; pe_run "$PE/dir x/a b.ts" >/dev/null
[ "$(pe_calls)" = 1 ] && grep -qx 'dir x/a b.ts' "$PEQ" 2>/dev/null && ok "second edit inside the pause — only queued, no run" || bad "debounce" "$(pe_calls) $(cat "$PEQ" 2>&1)"
pe_conf; pe_reset
mkdir -p "$PE/.git/post-edit-tests"; printf 'gone.ts\nlib/a.ts\n' > "$PEQ"
pe_run "$PE/lib/a.ts" >/dev/null
[ "$(pe_calls)" = 1 ] && ! grep -q 'gone.ts' "$PECALLS" && grep -qx 'ARG lib/a.ts' "$PECALLS" && ok "deleted file in the queue — not passed to the runner" || bad "deleted file in queue" "$(cat "$PECALLS")"

PELOCK="$PE/.git/monitorex-locks/post-edit-run"
pe_reset; mkdir -p "$PELOCK"; printf 'pid=%s\ntime=%s\n' "$$" "$(date +%s)" > "$PELOCK/owner"
pe_run "$PE/lib/a.ts" >/dev/null
[ "$(pe_calls)" = 0 ] && [ -d "$PELOCK" ] && grep -qx 'lib/a.ts' "$PEQ" && ok "run lock held by a live pid — no run, the path waits in the queue" || bad "live lock" "$(pe_calls)"
# two worktrees of one repository: own queues, one shared lock
git -C "$PE" worktree add -q "$TMP/pe-wt2" -b pe2 2>/dev/null
pe_run "$TMP/pe-wt2/lib/a.ts" "$TMP/pe-wt2" >/dev/null
PEQ2="$PE/.git/worktrees/pe-wt2/post-edit-tests/pending"
[ "$(pe_calls)" = 0 ] && grep -qx 'lib/a.ts' "$PEQ2" 2>/dev/null && [ "$(grep -c . "$PEQ")" = 1 ] \
    && ok "two worktrees — separate queues, the lock is shared (no run in the second tree)" || bad "two worktrees" "$(pe_calls) q2=$(cat "$PEQ2" 2>&1)"
printf 'pid=%s\ntime=%s\n' "$(dead_pid)" "$(date +%s)" > "$PELOCK/owner"
pe_run "$PE/lib/a.ts" >/dev/null
[ "$(pe_calls)" = 1 ] && [ ! -d "$PELOCK" ] && ok "run lock of a dead pid — removed, the run happens" || bad "dead lock" "$(pe_calls)"

pe_conf 'GG_POST_EDIT_MAX=1'; pe_reset; echo sleep > "$PEMODE"; rm -f "$TMP/pe-child"
T0=$SECONDS; out=$(pe_run "$PE/lib/a.ts"); T=$((SECONDS-T0))
child=$(cat "$TMP/pe-child" 2>/dev/null); sleep 1
{ [ -z "$out" ] && [ $T -lt 15 ] && [ -n "$child" ] && ! kill -0 "$child" 2>/dev/null && [ ! -d "$PELOCK" ]; } \
    && ok "GG_POST_EDIT_MAX=1 — the whole process group killed (${T}s), lock released, no block" || bad "ceiling" "out=$out T=$T child=$child"
[ -n "$child" ] && kill "$child" 2>/dev/null
echo green > "$PEMODE"

out=$(printf 'not json {' | CLAUDE_PROJECT_DIR="$PE" bash "$CH/post-edit-tests.sh"); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "broken JSON — exit 0, silent" || bad "broken JSON" "rc=$rc $out"
NOPY="$TMP/nopy"; mkdir -p "$NOPY"; for t in cat dirname; do ln -sf "$(command -v $t)" "$NOPY/$t"; done
pe_reset
out=$(pe_in "$PE/lib/a.ts" "$PE" | env PATH="$NOPY" CLAUDE_PROJECT_DIR="$PE" /bin/bash "$CH/post-edit-tests.sh"); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && [ "$(pe_calls)" = 0 ] && ok "no python3 — exit 0, silent" || bad "no python3" "rc=$rc $out"

if [ -n "$KIT" ]; then
    echo "== settings-merge.py, detect.py, install.sh: idempotent =="
    SM="$TMP/sm"; mkrepo "$SM"; mkdir -p "$SM/.claude/hooks"
    cat > "$SM/.claude/settings.json" <<'JSON'
{
  "permissions": {"allow": ["Bash(ls:*)"]},
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo mine"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "echo stop"}]}]
  }
}
JSON
    out=$(python3 "$KIT/settings-merge.py" "$SM" 2>&1); rc=$?
    reg=$(python3 - "$SM/.claude/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
h = d["hooks"]
def cmds(ev, m): return [x.get("command", "") for g in h.get(ev, []) if g.get("matcher") == m for x in g.get("hooks", [])]
print(int(any("monitorex-git-guard.sh" in c for c in cmds("PreToolUse", "Bash"))),
      int(any("monitorex-git-guard.sh" in c for c in cmds("PreToolUse", "Write|Edit|MultiEdit|NotebookEdit"))),
      len(cmds("PostToolUse", "ExitPlanMode")), len(cmds("PostToolUse", "Edit|Write|MultiEdit")),
      int("echo mine" in cmds("PreToolUse", "Bash")), int("Stop" in h), int(d["permissions"]["allow"] == ["Bash(ls:*)"]))
PY
)
    [ $rc -eq 0 ] && [ "$reg" = "1 1 0 0 1 1 1" ] && echo "$out" | grep -q 'skipped' \
        && ok "settings-merge: guard registered for Bash and Write|Edit; PostToolUse skipped without hook files; foreign hooks kept" || bad "settings-merge first run" "$reg $out"
    touch "$SM/.claude/hooks/plan-approved.sh" "$SM/.claude/hooks/post-edit-tests.sh"
    python3 "$KIT/settings-merge.py" "$SM" >/dev/null 2>&1
    cp "$SM/.claude/settings.json" "$TMP/sm.1"
    out=$(python3 "$KIT/settings-merge.py" "$SM" 2>&1); rc=$?
    reg2=$(python3 -c 'import json,sys
h=json.load(open(sys.argv[1]))["hooks"]["PostToolUse"]
c=[(g["matcher"],x["command"],x.get("timeout")) for g in h for x in g["hooks"]]
print(len(c), sum(1 for m,cm,t in c if m=="Edit|Write|MultiEdit" and t==120))' "$SM/.claude/settings.json")
    [ $rc -eq 0 ] && cmp -s "$SM/.claude/settings.json" "$TMP/sm.1" && [ "$reg2" = "2 1" ] \
        && ok "settings-merge: hook files present — PostToolUse registered once (timeout 120); a rerun changes nothing" || bad "settings-merge rerun" "$reg2 $out"
    printf '{ "hooks": [broken' > "$SM/.claude/settings.json"; cp "$SM/.claude/settings.json" "$TMP/sm.broken"
    out=$(python3 "$KIT/settings-merge.py" "$SM" 2>&1); rc=$?
    [ $rc -eq 1 ] && cmp -s "$SM/.claude/settings.json" "$TMP/sm.broken" && ok "settings-merge: broken settings.json — refused, file untouched" || bad "settings-merge broken" "rc=$rc $out"

    DT="$TMP/dt"; mkrepo "$DT"; mkdir -p "$DT/supabase/migrations"
    echo '{"devDependencies":{"vitest":"1"}}' > "$DT/package.json"
    out=$(python3 "$KIT/detect.py" "$DT")
    { echo "$out" | grep -qx 'GG_PLAN_GATE="githooks/plan-gate.sh"' && echo "$out" | grep -qx 'GG_PLAN_REQUIRED_TYPES="feat"' \
      && echo "$out" | grep -qx 'GG_PLAN_REQUIRED_NEW="supabase/migrations/\*.sql"' && echo "$out" | grep -qx 'GG_POST_EDIT_TESTS=1'; } \
        && ok "detect: new config gets GG_PLAN_GATE, GG_PLAN_REQUIRED_TYPES/NEW and GG_POST_EDIT_TESTS (vitest)" || bad "detect keys" "$out"
    rm -rf "$DT/supabase"; echo '{}' > "$DT/package.json"
    out=$(python3 "$KIT/detect.py" "$DT")
    ! echo "$out" | grep -q '^GG_POST_EDIT_TESTS=' && ! echo "$out" | grep -q '^GG_PLAN_REQUIRED_NEW=' \
        && echo "$out" | grep -qx 'GG_PLAN_GATE="githooks/plan-gate.sh"' && ok "detect: no test runner / no migrations — no GG_POST_EDIT_TESTS / GG_PLAN_REQUIRED_NEW" || bad "detect without runner" "$out"

    # install.sh itself: a copy of the kit with a stub acceptance (the real one is this file)
    FK="$TMP/fakekit"; mkdir -p "$FK"
    cp -R "$KIT/files" "$FK/files"; cp "$KIT/detect.py" "$KIT/settings-merge.py" "$FK/"
    sed "s#/tmp/gg-accept.log#$TMP/gg-accept.log#g" "$KIT/install.sh" > "$FK/install.sh"
    printf '#!/usr/bin/env bash\necho "  passed: 1   failed: 0"\n' > "$FK/files/scripts/test-git-guards.sh"
    IT="$TMP/it"; mkrepo "$IT"; echo '{"devDependencies":{"vitest":"1"}}' > "$IT/package.json"
    out=$(GG_EMBEDDED=1 bash "$FK/install.sh" "$IT" 2>&1); rc=$?
    [ $rc -eq 0 ] && grep -qx 'GG_POST_EDIT_TESTS=1' "$IT/.gitguards.conf" && grep -q 'post-edit-tests.sh' "$IT/.claude/settings.json" \
        && [ -x "$IT/.git/monitorex-hooks/plan-gate.sh" ] && ok "install.sh: new project — config with the new keys, hooks registered, plan-gate installed" || bad "install.sh first run" "$out"
    printf '# edited by a human\nGG_TEST_CMD=""\n' > "$IT/.gitguards.conf"; cp "$IT/.claude/settings.json" "$TMP/it.settings"
    out=$(GG_EMBEDDED=1 bash "$FK/install.sh" "$IT" 2>&1); rc=$?
    [ $rc -eq 0 ] && [ "$(head -1 "$IT/.gitguards.conf")" = "# edited by a human" ] && cmp -s "$IT/.claude/settings.json" "$TMP/it.settings" \
        && ok "install.sh rerun — existing .gitguards.conf not overwritten, settings.json unchanged" || bad "install.sh rerun" "$out"
fi

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
