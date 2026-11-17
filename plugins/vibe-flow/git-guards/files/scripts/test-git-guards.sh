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

case "${GG_SUITE_ONLY:-}" in
    ""|guard) ;;
    *) echo "GG_SUITE_ONLY: unknown value '${GG_SUITE_ONLY}' (allowed: guard)" >&2; exit 2 ;;
esac
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) IS_WIN=1 ;; *) IS_WIN=0 ;; esac

# N/A: a case that cannot run on this machine. Allowed ONLY on native Windows and
# only for three reasons; anywhere else an N/A is a failure, so macOS and Linux
# always run everything. Windows-only cases are not N/A on POSIX: they do not run.
NA=0; NA_LIST=()
na() {   # $1 = case, $2 = reason
    NA=$((NA+1)); NA_LIST+=("$1 ($2)"); echo "  n/a  - $1: $2"
    if [ "$IS_WIN" != 1 ]; then bad "N/A outside native Windows: $1" "$2"; return; fi
    case "$2" in
        "ln -s made a copy"|"no shasum"|"noexec") ;;
        *) bad "N/A for a reason that is not allowed: $1" "$2" ;;
    esac
}
# Git Bash without symlink rights makes `ln -s` a COPY: cases about symlinks go N/A there.
mkdir -p "$TMP/ln-probe"; : > "$TMP/ln-probe/t"; ln -s "$TMP/ln-probe/t" "$TMP/ln-probe/l" 2>/dev/null
if [ -L "$TMP/ln-probe/l" ]; then REAL_SYMLINKS=1; else REAL_SYMLINKS=0; fi

# The real interpreter, resolved before any case puts stubs first on PATH.
PYBIN=$(command -v python3)
REALPY=$(python3 -c 'import sys; print(sys.executable)')
if [ "$IS_WIN" = 1 ] && command -v cygpath >/dev/null 2>&1; then REALPY=$(cygpath -u "$REALPY"); fi
# Per-case ceiling around cases that kill processes or wait on a watchdog: a hang
# there must fail one case, not eat the CI job. GNU timeout only (macOS has none).
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 300"

# A tiny exec wrapper standing in for a tool in a trimmed PATH. Not `ln -s`:
# Git Bash copies instead of linking, and a copied .exe loses its DLLs.
mkwrap() {   # $1 = dir, $2 = name, $3 = absolute path of the real tool
    mkdir -p "$1"; printf '#!/bin/sh\nexec "%s" "$@"\n' "$3" > "$1/$2"; chmod +x "$1/$2"
}

# Shims placed first in PATH reproduce another platform's tools (GNU vs BSD,
# Git Bash) on any machine. The body comes on stdin; @REAL_MKTEMP@, @REAL_CP@ and
# @REAL_GIT@ are replaced with the real binaries so a shim can pass calls through.
REAL_MKTEMP=$(command -v mktemp); REAL_CP=$(command -v cp); REAL_GIT=$(command -v git)
mkshim() {   # $1 = shim set name, $2 = tool name; body on stdin → $TMP/shim-$1/$2
    # (not used inside $(...): bash 3.2 misparses a heredoc with `case` or `'` there)
    local d="$TMP/shim-$1"; mkdir -p "$d"
    { echo '#!/bin/sh'; sed -e "s#@REAL_MKTEMP@#$REAL_MKTEMP#g" -e "s#@REAL_CP@#$REAL_CP#g" \
        -e "s#@REAL_GIT@#$REAL_GIT#g"; } > "$d/$2"
    chmod +x "$d/$2"
}

mkrepo() {                     # $1 = path
    # The branch is named explicitly: the fixtures must not depend on the
    # machine's init.defaultBranch (git's own default is still `master`).
    mkdir -p "$1"; git -C "$1" init -q; git -C "$1" symbolic-ref HEAD refs/heads/main
    git -C "$1" config user.email t@t; git -C "$1" config user.name t
    echo v1 > "$1/a.txt"; echo v1 > "$1/b.txt"
    printf '#!/bin/sh\necho hi\n' > "$1/s.sh"; chmod +x "$1/s.sh"
    mkdir -p "$1/dír"; echo "ünï" > "$1/dír/fïle with space.txt"
    git -C "$1" add -A
    # The exec bit through the index: with core.filemode=false (Git for Windows)
    # chmod never reaches git, and the mode cases would test nothing.
    git -C "$1" update-index --chmod=+x s.sh
    git -C "$1" commit -qm init
}

# Layout: the kit repository (files/claude/hooks, settings-merge.py one level up)
# or a project (.claude/hooks; settings-merge.py and detect.py are not copied there).
if [ -d "$ROOT/.claude/hooks" ]; then CH="$ROOT/.claude/hooks"; else CH="$ROOT/claude/hooks"; fi
KIT=""; [ -f "$ROOT/../settings-merge.py" ] && KIT="$(cd "$ROOT/.." && pwd)"

# ── The PreToolUse guard: payload, decision, runners ─────────────────────────
gj() { python3 -c 'import json,sys; t,k,v,c=sys.argv[1:5]; print(json.dumps({"tool_name":t,"tool_input":{k:v},"cwd":c}))' "$@"; }
# The hook protocol (K3): deny ⇔ rc 2, or rc 0 and stdout is JSON with
# hookSpecificOutput.permissionDecision "deny"; allow ⇔ rc 0 and stdout empty or
# JSON without a deny. Anything else (rc 1, garbage on stdout) is an ERROR — a
# crashed guard is never counted as an allow.
decide() {   # $1 = rc; stdin = the hook's stdout → deny | allow | error
    "$PYBIN" -c 'import json,sys
rc = int(sys.argv[1]); out = sys.stdin.read().strip()
if rc == 2: print("deny"); sys.exit(0)
if rc != 0: print("error"); sys.exit(0)
if not out: print("allow"); sys.exit(0)
try:
    d = json.loads(out)
except ValueError:
    print("error"); sys.exit(0)
h = d.get("hookSpecificOutput") if isinstance(d, dict) else None
print("deny" if isinstance(h, dict) and h.get("permissionDecision") == "deny" else "allow")' "$1"
}
gcase() {   # label expect(deny|allow) project tool key value cwd
    local lbl="$1" exp="$2" proj="$3" o rc got; shift 3
    o=$(gj "$@" | CLAUDE_PROJECT_DIR="$proj" bash "$CH/monitorex-git-guard.sh" 2>/dev/null); rc=$?
    got=$(printf '%s' "$o" | decide "$rc")
    [ "$got" = "$exp" ] && ok "guard: $lbl — $exp" || bad "guard: $lbl — $exp" "got $got (rc $rc): $o"
}
gwrap() {   # label expect project VAR=value… -- tool key value cwd: the wrapper under an environment
    local lbl="$1" exp="$2" proj="$3" o rc got envs=(); shift 3
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
    o=$(gj "$@" | env ${envs[@]+"${envs[@]}"} CLAUDE_PROJECT_DIR="$proj" "$BASH" "$CH/monitorex-git-guard.sh" 2>"$TMP/gwrap.err"); rc=$?
    got=$(printf '%s' "$o" | decide "$rc")
    [ "$got" = "$exp" ] && ok "guard: $lbl — $exp" || bad "guard: $lbl — $exp" "got $got (rc $rc): $o $(head -3 "$TMP/gwrap.err")"
}
gbytes() {  # label expect project payload-file VAR=value…: raw payload bytes through the wrapper
    local lbl="$1" exp="$2" proj="$3" f="$4" o rc got; shift 4
    o=$(env "$@" CLAUDE_PROJECT_DIR="$proj" "$BASH" "$CH/monitorex-git-guard.sh" < "$f" 2>"$TMP/gwrap.err"); rc=$?
    got=$(printf '%s' "$o" | decide "$rc")
    [ "$got" = "$exp" ] && ok "guard: $lbl — $exp" || bad "guard: $lbl — $exp" "got $got (rc $rc): $o $(head -3 "$TMP/gwrap.err")"
}

# ── The guard as Claude Code runs it: encodings, interpreters, closed stdout ──
# vibe-flow 1.3.0. Every case goes through the hook WRAPPER (what settings.json
# registers), because that is where a missing / too old / fake Python decides
# whether a deny ever reaches Claude Code. Also run alone: GG_SUITE_ONLY=guard.
guard_wrapper_cases() {
    echo "== guard through its wrapper: encodings, interpreters, closed stdout =="
    local GM="$TMP/gw-main" GWT="$TMP/gw-main-wt" f p o rc err line
    mkrepo "$GM"; mkdir -p "$GM/src" "$GM/.git/monitorex-locks"
    git -C "$GM" worktree add -q "$GWT" -b wt/gw >/dev/null 2>&1
    gcase "git add in the main tree (fixture)" deny "$GM" Bash command "git add a.txt" "$GM"
    gcase "git add in a linked worktree (fixture)" allow "$GM" Bash command "git add a.txt" "$GWT"

    # Windows' cp1252 stdio, reproduced: the deny must still be valid JSON
    gwrap "PYTHONIOENCODING=cp1252: git add in the main tree" deny "$GM" PYTHONIOENCODING=cp1252 -- Bash command "git add a.txt" "$GM"
    gwrap "PYTHONIOENCODING=cp1252: Cyrillic commit message" deny "$GM" PYTHONIOENCODING=cp1252 -- Bash command 'git commit -m "исправление"' "$GM"
    gwrap "Cyrillic commit message (UTF-8)" deny "$GM" GG_T=1 -- Bash command 'git commit -m "исправление"' "$GM"
    f="$TMP/gw-badutf8.json"
    "$PYBIN" -c 'import json,sys; h=json.dumps({"tool_name":"Bash","cwd":sys.argv[1]}).encode()[:-1]
sys.stdout.buffer.write(h + b", \"tool_input\": {\"command\": \"git add a.txt # \xff\xfe\xc3\"}}")' "$GM" > "$f"
    gbytes "invalid UTF-8 bytes in the payload — no crash" deny "$GM" "$f" GG_T=1
    gbytes "invalid UTF-8 bytes under cp1252 — no crash" deny "$GM" "$f" PYTHONIOENCODING=cp1252
    # … and the guard run directly (a human, no wrapper): the code-level backstop
    o=$(PYTHONIOENCODING=cp1252 CLAUDE_PROJECT_DIR="$GM" "$PYBIN" -B "$CH/monitorex_git_guard.py" < "$f" 2>/dev/null); rc=$?
    [ "$(printf '%s' "$o" | decide "$rc")" = deny ] && ok "guard run directly, cp1252 + invalid UTF-8 — deny" \
        || bad "guard run directly, cp1252 + invalid UTF-8 — deny" "rc $rc: $o"

    # Python 3.9 is the floor (macOS /usr/bin/python3 is 3.9.6 and may come first)
    local py39="" c
    for c in "${GG_TEST_PY39:-}" /usr/bin/python3 python3.9 python3; do
        [ -n "$c" ] || continue
        c=$(command -v "$c" 2>/dev/null) || continue
        case "$("$c" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" in 3.9) py39=$c; break ;; esac
    done
    if [ -n "$py39" ]; then
        mkwrap "$TMP/gw-py39" python3 "$py39"
        gwrap "Python 3.9 first on PATH ($py39) — a deny is still a deny" deny "$GM" PATH="$TMP/gw-py39:$PATH" -- Bash command "git add a.txt" "$GM"
        gwrap "Python 3.9 first on PATH — git status still allowed" allow "$GM" PATH="$TMP/gw-py39:$PATH" -- Bash command "git status" "$GM"
    else
        echo "  note - no Python 3.9 on this machine: the 3.9 cases run in the CI floor job"
    fi

    # A candidate that is not a usable Python is skipped, the next one runs (K1/K2)
    mkwrap "$TMP/gw-realpy" python "$REALPY"
    mkdir -p "$TMP/gw-py86"; printf '#!/bin/sh\nexit 86\n' > "$TMP/gw-py86/python3"; chmod +x "$TMP/gw-py86/python3"
    gwrap "python3 below the floor (exit 86), a supported python next — deny (Codex C2)" deny "$GM" PATH="$TMP/gw-py86:$TMP/gw-realpy:$PATH" -- Bash command "git add a.txt" "$GM"
    p="$TMP/gw-wa/WindowsApps"; mkdir -p "$p"
    printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$TMP/gw-wa-ran" > "$p/python3"; chmod +x "$p/python3"
    rm -f "$TMP/gw-wa-ran"
    gwrap "python3 under */WindowsApps/* is skipped unrun — the next interpreter denies" deny "$GM" PATH="$p:$TMP/gw-realpy:$PATH" -- Bash command "git add a.txt" "$GM"
    [ ! -e "$TMP/gw-wa-ran" ] && ok "guard: the WindowsApps candidate was never executed" || bad "guard: the WindowsApps candidate was executed" ""

    # stdout closed: the deny cannot be printed → exit 2 with an ASCII reason (K4)
    err="$TMP/gw-closed.err"
    gj Bash command "git add a.txt" "$GM" | CLAUDE_PROJECT_DIR="$GM" "$BASH" "$CH/monitorex-git-guard.sh" >&- 2>"$err"; rc=$?
    line=$(grep 'vibe-flow guard: DENY:' "$err" | head -1)
    { [ "$rc" = 2 ] && [ -n "$line" ] && [ -z "$(printf '%s' "$line" | LC_ALL=C tr -d '\011\040-\176')" ]; } \
        && ok "guard: wrapper with stdout closed — rc 2, ASCII reason on stderr" || bad "guard: wrapper with stdout closed" "rc $rc: $(head -3 "$err")"
    gj Bash command "git add a.txt" "$GM" | CLAUDE_PROJECT_DIR="$GM" "$PYBIN" -B "$CH/monitorex_git_guard.py" >&- 2>"$err"; rc=$?
    line=$(grep 'vibe-flow guard: DENY:' "$err" | head -1)
    { [ "$rc" = 2 ] && [ -n "$line" ] && [ -z "$(printf '%s' "$line" | LC_ALL=C tr -d '\011\040-\176')" ]; } \
        && ok "guard: run directly with stdout closed — rc 2, ASCII reason on stderr" || bad "guard: run directly with stdout closed" "rc $rc: $(head -3 "$err")"
}

guard_unit_cases() {
    echo "== PreToolUse guard: unit cases (test_pretooluse_guard.py) =="
    local out rc summary GLY
    if [ -d "$ROOT/.claude/hooks" ]; then
        out=$(python3 -B "$ROOT/scripts/git-guards/test_pretooluse_guard.py" 2>&1); rc=$?
    else                            # the kit: assemble the project layout the test expects
        GLY="$TMP/guard-layout"; rm -rf "$GLY"; mkdir -p "$GLY/.claude/hooks" "$GLY/scripts/git-guards"
        cp "$CH"/* "$GLY/.claude/hooks/"; cp "$ROOT"/scripts/git-guards/*.py "$ROOT"/scripts/git-guards/*.sh "$GLY/scripts/git-guards/"
        out=$(cd "$GLY" && python3 -B "$GLY/scripts/git-guards/test_pretooluse_guard.py" 2>&1); rc=$?
    fi
    summary=$(printf '%s\n' "$out" | grep -E 'passed: [0-9]+' | tail -1 | sed 's/^ *//')
    # No FAIL/passed line = the runner itself crashed: show its last lines (the traceback).
    [ $rc -eq 0 ] && ok "guard unit cases — $summary" \
        || bad "guard unit cases" "rc=$rc $(printf '%s\n' "$out" | grep -E 'FAIL|passed' | head -40)
$(printf '%s\n' "$out" | grep -qE 'FAIL|passed' || printf '%s\n' "$out" | tail -15)"
}

finish() {
    echo
    echo "=========================================="
    echo "  passed: $PASS   failed: $FAIL   n/a: $NA"
    if [ "$NA" -gt 0 ]; then echo "  not applicable here:"; printf '    - %s\n' "${NA_LIST[@]}"; fi
    [ $FAIL -gt 0 ] && { echo "  failures:"; printf '    - %s\n' "${FAILED[@]}"; exit 1; }
    echo "=========================================="
    exit 0
}

if [ "${GG_SUITE_ONLY:-}" = guard ]; then
    guard_wrapper_cases
    guard_unit_cases
    finish
fi

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
IDXF=$(mktemp "${TMPDIR:-/tmp}/idx.XXXXXX"); GIT_INDEX_FILE="$IDXF" git -C "$R6" read-tree "$A"
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
REMOTE="$TMP/remote.git"; git init -q --bare "$REMOTE"; git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
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
WO="$TMP/wo.git"; git init -q --bare "$WO"; git -C "$WO" symbolic-ref HEAD refs/heads/main
W="$TMP/w"; mkrepo "$W"; git -C "$W" branch -M main
git -C "$W" remote add origin "$WO"; git -C "$W" push -q origin main 2>/dev/null
mkdir -p "$W/scripts/git-guards" "$W/githooks"
cp "$ROOT/scripts/wt-new.sh" "$ROOT/scripts/install-git-guards.sh" "$W/scripts/"
cp "$ROOT"/scripts/git-guards/*.sh "$W/scripts/git-guards/"
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
DO="$TMP/do.git"; git init -q --bare "$DO"; git -C "$DO" symbolic-ref HEAD refs/heads/main
D="$TMP/d"; mkrepo "$D"; git -C "$D" branch -M main
echo '{"name":"t","version":"1.0.0"}' > "$D/package.json"; echo '{"lock":1}' > "$D/package-lock.json"
git -C "$D" add -A; git -C "$D" commit -qm deps
git -C "$D" remote add origin "$DO"; git -C "$D" push -q origin main 2>/dev/null
mkdir -p "$D/scripts/git-guards" "$D/githooks"
cp "$ROOT/scripts/wt-new.sh" "$ROOT/scripts/install-git-guards.sh" "$ROOT/scripts/wt-status.sh" "$D/scripts/"
cp "$ROOT"/scripts/git-guards/*.sh "$D/scripts/git-guards/"
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
# GNU cp has no clonefile flag: `cp -Rc` may copy part of the tree and then fail.
# The fallback copy must start clean, not nest node_modules/node_modules.
mkshim cp-partial cp <<'EOF'
if [ "$1" = -Rc ]; then mkdir -p "$3"; echo partial > "$3/partial"; exit 1; fi
exec @REAL_CP@ "$@"
EOF
CP_PART="$TMP/shim-cp-partial"
out=$(PATH="$CP_PART:$PATH" bash "$D/scripts/wt-new.sh" cpfall 2>&1); rc=$?
[ $rc -eq 0 ] && [ -f "$TMP/d-wt/cpfall/node_modules/from-main" ] && [ ! -e "$TMP/d-wt/cpfall/node_modules/node_modules" ] \
    && [ ! -e "$TMP/d-wt/cpfall/node_modules/partial" ] \
    && ok "clone fails half-way (GNU cp -Rc) — clean regular copy, no nested node_modules" || bad "partial cp -Rc" "$out"

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
T0=$SECONDS; out=$($TO bash "$D/scripts/wt-new.sh" d5 2>&1); rc=$?; T=$((SECONDS-T0))
[ $rc -eq 0 ] && [ $T -lt 15 ] && echo "$out" | grep -q 'within 2s' \
    && ok "hanging fetch is cut off by the timeout (${T}s)" || bad "fetch timeout" "rc=$rc ${T}s $out"

# ═════════════════════════════════════════════════════════════════════════════
# Plan gate, barrier protection, issue claims, tests after an edit (07.11.2026).
# Fixtures live here (heredocs / generated in $TMP): install.sh copies only
# files/scripts/*, so no extra fixture files in the repository.
# ═════════════════════════════════════════════════════════════════════════════

kit_copy() {     # $1 = repo: the kit in project layout
    mkdir -p "$1/githooks" "$1/scripts/git-guards" "$1/.claude/hooks"
    cp "$ROOT/githooks/pre-commit" "$ROOT/githooks/pre-push" "$ROOT/githooks/plan-gate.sh" "$ROOT/githooks/prepare-commit-msg" "$1/githooks/"
    for s in git-safe-commit.sh install-git-guards.sh wt-new.sh wt-done.sh wt-status.sh git-lock.sh git-confirm.sh; do
        cp "$ROOT/scripts/$s" "$1/scripts/"
    done
    # every library file: the scripts source the shell helpers (conf.sh and, from
    # 1.3.0, the path / interpreter helpers) and import the Python ones
    cp "$ROOT"/scripts/git-guards/*.py "$ROOT"/scripts/git-guards/*.sh "$1/scripts/git-guards/"
    cp "$CH/monitorex-git-guard.sh" "$CH/monitorex_git_guard.py" "$1/.claude/hooks/"
}
sha_of() { { printf '%s' "$1" | sha256sum 2>/dev/null || printf '%s' "$1" | shasum -a 256; } | cut -d' ' -f1; }
NOW_TS=$(date +%s)
dead_pid() { sh -c 'exit 0' & local p=$!; wait "$p" 2>/dev/null; echo "$p"; }
# Pids as a NATIVE program sees them (post-edit-tests.py writes os.getpid() into its
# lock and checks liveness with OpenProcess). Git Bash numbers its processes itself:
# the Windows pid of an MSYS pid is /proc/<pid>/winpid. Elsewhere the same number.
native_pid() { if [ "$IS_WIN" = 1 ]; then cat "/proc/$1/winpid"; else echo "$1"; fi; }
dead_native_pid() {   # a process of the native kind that has already exited
    if [ "$IS_WIN" = 1 ]; then "$PYBIN" -c 'import os; print(os.getpid())'; else dead_pid; fi
}

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
[ -x "$PGH/prepare-commit-msg" ] && ok "installer: prepare-commit-msg installed next to pre-push" || bad "installer: prepare-commit-msg installed"
echo '# edited in the branch' >> "$PGR/githooks/pre-push"
bash "$PGR/scripts/install-git-guards.sh" >/dev/null 2>&1
git -C "$PGR" show origin/main:githooks/pre-push > "$TMP/pg-pp-origin"
cmp -s "$PGH/pre-push" "$TMP/pg-pp-origin" && ok "installer: a pre-push edited in the branch is NOT installed (origin's is)" \
    || bad "installer: branch edit not installed"
git -C "$PGR" checkout -q -- githooks/pre-push
PGB="$TMP/pg-norefs"; git clone -q "$PGO" "$PGB" 2>/dev/null
git -C "$PGB" update-ref -d refs/remotes/origin/main; git -C "$PGB" update-ref -d refs/remotes/origin/HEAD 2>/dev/null
mkdir -p "$PGB/.git/monitorex-hooks"; printf '#!/bin/sh\n# installed earlier\n' > "$PGB/.git/monitorex-hooks/pre-push"
# MSYS_NO_PATHCONV: Git Bash would rewrite the literal /some/where into C:/Program Files/Git/some/where.
# It switches off EVERY argument's conversion, so no `-C <msys path>` next to it: git.exe
# would get /tmp/… literally and fail with "cannot change to" — a cd in a subshell instead.
( cd "$PGB" && MSYS_NO_PATHCONV=1 git config core.hooksPath /some/where )
out=$(bash "$PGB/scripts/install-git-guards.sh" 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'hooks left untouched' && grep -q 'installed earlier' "$PGB/.git/monitorex-hooks/pre-push" \
    && [ "$(cd "$PGB" && MSYS_NO_PATHCONV=1 git config core.hooksPath)" = /some/where ] && [ ! -f "$PGB/.git/monitorex-hooks/.source" ] \
    && ok "installer: origin without fetched refs — rc 0, warning, hooks and hooksPath untouched (no tree fallback)" \
    || bad "installer: origin without refs" "rc=$rc $out"
# CI checkout of a PR: only refs/remotes/pull/N/merge, depth 1, no origin/main
PGCI="$TMP/pg-ci"; git init -q "$PGCI"; git -C "$PGCI" symbolic-ref HEAD refs/heads/main; git -C "$PGCI" remote add origin "$PGO"
git -C "$PGCI" fetch -q --depth=1 origin "+$(git -C "$PGR" rev-parse origin/main):refs/remotes/pull/1/merge" 2>/dev/null
git -C "$PGCI" checkout -q --detach refs/remotes/pull/1/merge 2>/dev/null
out=$(bash "$PGCI/scripts/install-git-guards.sh" 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'hooks left untouched' && [ ! -e "$PGCI/.git/monitorex-hooks" ] \
    && [ -z "$(git -C "$PGCI" config core.hooksPath)" ] \
    && ok "installer: CI PR checkout (pull/1/merge, depth 1) — rc 0, nothing installed, npm ci survives" \
    || bad "installer: CI PR checkout" "rc=$rc $out"
# no origin remote at all — bootstrap from the tree, never a failure
PGNO="$TMP/pg-noorigin"; git clone -q "$PGO" "$PGNO" 2>/dev/null; git -C "$PGNO" remote remove origin
out=$(bash "$PGNO/scripts/install-git-guards.sh" 2>&1); rc=$?
[ $rc -eq 0 ] && grep -q '^bootstrap@' "$PGNO/.git/monitorex-hooks/.source" 2>/dev/null \
    && ok "installer: no origin remote — rc 0, bootstrap from the tree" || bad "installer: no origin remote" "rc=$rc $out"
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

echo "== plan gate: the project's plans directory (plansDirectory) =="
# GG_PLANS_DIR unset, HOME swapped: the real ~/.claude/plans never takes part.
PGHOME="$TMP/pg-home"; mkdir -p "$PGHOME"
pg_push_nd() { ( cd "$1" && env -u GG_PLANS_DIR HOME="$PGHOME" MONITOREX_ACTOR=tst CLAUDE_CODE_SESSION_ID= git push origin "HEAD:refs/heads/${2:-$PG_BR}" 2>&1 ); }
pg_reset
pg_mc "$PGR" "$(printf '[feat]: pd1\n\nPlan: pd1.md')" a.txt pd1 >/dev/null; pg_mark pd1.md
out=$(pg_push_nd "$PGR"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'plan file not found' && echo "$out" | grep -q "$PGHOME/.claude/plans" && echo "$out" | grep -q '\.plans' \
    && ok "pd: the plan is nowhere — rejected, the message lists every checked directory" || bad "pd: nowhere" "$out"
mkdir -p "$PGR/.plans"; echo plan > "$PGR/.plans/pd1.md"
out=$(pg_push_nd "$PGR"); rc=$?
[ $rc -eq 0 ] && ok "pd: plan in <tree>/.plans (default plansDirectory) — goes through" || bad "pd: .plans" "$out"
pg_reset
pg_mc "$PGR" "$(printf '[feat]: pd2\n\nPlan: pd2.md')" a.txt pd2 >/dev/null; pg_mark pd2.md
echo plan > "$PGR/.plans/pd2.md"
git -C "$PGR" worktree add -q --detach "$TMP/pd-wt" "$(git -C "$PGR" rev-parse HEAD)" 2>/dev/null
out=$(pg_push_nd "$TMP/pd-wt" "$PG_BR"); rc=$?
[ $rc -eq 0 ] && ok "pd: plan in the MAIN tree's .plans, push from a linked worktree — goes through" || bad "pd: main tree .plans from worktree" "$out"
git -C "$PGR" worktree remove -f "$TMP/pd-wt"
pg_reset
mkdir -p "$PGR/.claude"; printf '{"plansDirectory": "planning"}\n' > "$PGR/.claude/settings.json"
pg_mc "$PGR" "$(printf '[feat]: pd3\n\nPlan: pd3.md')" a.txt pd3 >/dev/null; pg_mark pd3.md
echo plan > "$PGR/.plans/pd3.md"
out=$(pg_push_nd "$PGR"); rc=$?
[ $rc -ne 0 ] && ok "pd: own plansDirectory 'planning' — .plans no longer counts" || bad "pd: own dir, .plans" "$out"
mkdir -p "$PGR/planning"; echo plan > "$PGR/planning/pd3.md"
out=$(pg_push_nd "$PGR"); rc=$?
[ $rc -eq 0 ] && ok "pd: own plansDirectory 'planning' — counts" || bad "pd: own dir" "$out"
mkdir -p "$(dirname "$PGR")/pd-out"; echo plan > "$(dirname "$PGR")/pd-out/pd4.md"
for v in '../pd-out' "$(dirname "$PGR")/pd-out" 'planning/../../pd-out'; do
    pg_reset
    printf '{"plansDirectory": "%s"}\n' "$v" > "$PGR/.claude/settings.json"
    pg_mc "$PGR" "$(printf '[feat]: pd4\n\nPlan: pd4.md')" a.txt "pd4$PG_N" >/dev/null; pg_mark pd4.md
    out=$(pg_push_nd "$PGR"); rc=$?
    [ $rc -ne 0 ] && ok "pd: plansDirectory '$v' (outside / absolute / ..) — not used" || bad "pd: bad plansDirectory '$v'" "$out"
done
rm -f "$PGR/.claude/settings.json"
pg_reset
pg_mc "$PGR" "$(printf '[feat]: pd5\n\nPlan: pd5.md')" a.txt pd5 >/dev/null; pg_mark pd5.md
mkdir -p "$PGHOME/.claude/plans"; echo plan > "$PGHOME/.claude/plans/pd5.md"
out=$(pg_push_nd "$PGR"); rc=$?
[ $rc -eq 0 ] && ok "pd: plan only in the old ~/.claude/plans — still goes through" || bad "pd: legacy dir" "$out"
rm -rf "$PGR/.plans" "$PGR/planning"

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
PGL="$PGR/.git/monitorex-locks"
gcase "Write into .git/monitorex-locks/release-gate/<tree>" deny "$PGR" Write file_path "$PGL/release-gate/abc" "$PGR"
# A cwd outside the repository, resolved: /private/tmp on macOS, /tmp on Linux.
OUTSIDE=$(cd /tmp && pwd -P)
gcase "Write into monitorex-locks after cd /tmp (M5)" deny "$PGR" Write file_path "$PGL/release-gate/abc" "$OUTSIDE"
gcase "NotebookEdit via notebook_path into .git (M5)" deny "$PGR" NotebookEdit notebook_path "$PGL/x.ipynb" "$OUTSIDE"
gcase "Write of a plan-approved mark" deny "$PGR" Write file_path "$PGL/plan-approved/p1.md" "$PGR"
gcase "Bash echo > …/monitorex-locks/CONFIRM" deny "$PGR" Bash command "echo target=feat > $PGL/CONFIRM" "$PGR"
gcase "Bash rm in monitorex-locks/" deny "$PGR" Bash command "rm -rf .git/monitorex-locks/claims/issue-7" "$PGR"
gcase "git -c url.X.insteadOf=Y fetch origin (C1-r2)" deny "$PGR" Bash command "git -c url.X.insteadOf=Y fetch origin" "$PGR"
gcase "nice scripts/git-confirm.sh feat (L6)" deny "$PGR" Bash command "nice scripts/git-confirm.sh feat" "$PGR"
gcase "git remote set-head origin x" deny "$PGR" Bash command "git remote set-head origin x" "$PGR"
gcase "Write …/memory/x.md (H6: memory stays writable)" allow "$PGR" Write file_path "$TMP/home/.claude/projects/-p/memory/x.md" "$OUTSIDE"
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
! echo "$out" | grep -q 'ignoring invalid' && ok "GG_PLAN_GATE empty — no false 'ignoring invalid' warning" || bad "GG_PLAN_GATE empty warns" "$out"
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
PA="$TMP/pa"; git init -q "$PA"; git -C "$PA" symbolic-ref HEAD refs/heads/main; git -C "$PA" config user.email t@t; git -C "$PA" config user.name t
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
if [ "$REAL_SYMLINKS" = 1 ]; then
    ln -s "$TMP/pa-out/evil.md" "$GG_PLANS_DIR/link.md"
    out=$(pa_run link.md "$PA_GOOD" false)
    [ ! -f "$PAM/link.md" ] && [ ! -f "$PAM/evil.md" ] && ok "symlink in the plans directory pointing out — no mark" || bad "symlink out" "$out"
    rm -f "$GG_PLANS_DIR/link.md"
else na "symlink in the plans directory pointing out — no mark" "ln -s made a copy"; fi
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

echo "== plan-approved.py: the gate without Codex (decide / codex_found) =="
# The «no Codex» branch is tested on pure functions, never through the machine's
# environment: the hook always checks the standard Codex locations, so on a machine
# with Codex installed an environment-based test would be red (plan C1/C3).
pa_py() {   # pa_py <python expression over module m> [args…] — prints the result
    # utf-8 stdout: a helper of the suite, not the product — on Windows a pipe is cp1252,
    # and printing a refusal reason with a dash or Cyrillic raised UnicodeEncodeError.
    PYTHONIOENCODING=utf-8 python3 -B - "$CH/plan-approved.py" "$@" <<'PY2'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pa", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
expr, args = sys.argv[2], sys.argv[3:]
print(eval(expr))
PY2
}
pa_decide() {   # pa_decide <plan text> <codex found: 0|1> → "OK <kind>" | "NO <reason>"
    pa_py '(lambda r: ("OK " + r[1]) if r[0] else ("NO " + r[2]))(m.decide(args[0], args[1] == "1"))' "$1" "$2"
}
PG_EN='Gate: ✅ passed'; PG_RU='Гейт: ✅ пройден'
pd_case() {   # pd_case <expect OK|NO> <label> <plan> <found>
    local out; out=$(pa_decide "$3" "$4" 2>&1)
    case "$out" in "$1"*) ok "decide: $2" ;; *) bad "decide: $2" "$out" ;; esac
}
pd_case OK "(а) row '⚪️ not installed', Codex absent — accepted" "$(printf '| Codex (external critic) | — | ⚪️ not installed |\n\n%s' "$PG_EN")" 0
out=$(pa_decide "$(printf '| Codex (external critic) | — | ⚪️ not installed |\n\n%s' "$PG_EN")" 1 2>&1)
case "$out" in NO*codex-plan-critic*) ok "decide: (б) row '⚪️ not installed' but Codex IS installed — refused, points to codex-plan-critic" ;; *) bad "decide: (б) installed Codex" "$out" ;; esac
pd_case OK "(в) row '❌ unavailable — user's decision' — accepted" "$(printf "| Codex (external critic) | — | ❌ unavailable — user's decision |\n\n%s" "$PG_EN")" 0
pd_case OK "(г) agent form '⚪️ Critic not installed' — accepted" "$(printf '| Codex | — | ⚪️ Critic not installed |\n%s' "$PG_EN")" 0
pd_case NO "(д) 'not installed' in prose, no table row — refused" "$(printf 'The critic is not installed here.\n\n%s' "$PG_EN")" 0
pd_case NO "(е) marker row, but no gate line — refused" "$(printf '| Codex | — | ⚪️ not installed |\n')" 0
pd_case OK "(ж) '## … Codex' section with Codex installed — accepted (Bomond path untouched)" "$(printf '## External review Codex\n\n%s' "$PG_EN")" 1
pd_case OK "(з) user's decision with Codex installed — accepted" "$(printf "| Codex | — | ❌ unavailable — user's decision |\n%s" "$PG_EN")" 1
pd_case OK "(и) Russian '⚪️ не установлен' — accepted" "$(printf '| Codex (внешний критик) | — | ⚪️ не установлен |\n%s' "$PG_RU")" 0
pd_case OK "(и) Russian '❌ недоступен — решение пользователя' — accepted" "$(printf '| Codex | — | ❌ недоступен — решение пользователя |\n%s' "$PG_RU")" 0
pd_case OK "(к) '⚪️ Not Installed' (case) — accepted" "$(printf '| Codex | — | ⚪️ Not Installed |\n%s' "$PG_EN")" 0
pd_case OK "(л) typographic apostrophe 'user’s decision' — accepted" "$(printf '| Codex | — | ❌ unavailable — user’s decision |\n%s' "$PG_EN")" 0
pd_case NO "(м) markers only in prose/backticks — refused" "$(printf 'Without Codex write `⚪️ not installed` or `❌ unavailable — user'"'"'s decision`.\n\n%s' "$PG_EN")" 0
pd_case NO "(н) user's decision in prose, Codex installed — refused" "$(printf "Risk: ❌ unavailable — user's decision may be copied.\n\n%s" "$PG_EN")" 1
pd_case OK "(о) Codex section + '⚪️ not installed' quoted in prose, Codex installed — accepted" "$(printf '## 🧑‍⚖️ External Codex review\n\nquote: `⚪️ not installed`\n\n%s' "$PG_EN")" 1
pd_case OK "(п) dash '-' in the row — accepted" "$(printf "| Codex | — | ❌ unavailable - user's decision |\n%s" "$PG_EN")" 0
pd_case OK "(п) dash '–' in the row — accepted" "$(printf "| Codex | — | ❌ unavailable – user's decision |\n%s" "$PG_EN")" 0
pd_case OK "(п) '⚪️ (Critic) not installed' — accepted" "$(printf '| Codex | — | ⚪️ (Critic) not installed |\n%s' "$PG_EN")" 0
pd_case OK "(п) '⚪️ Codex not installed' — accepted" "$(printf '| Codex | — | ⚪️ Codex not installed |\n%s' "$PG_EN")" 0
pd_case OK "(п) '⚪' without U+FE0F — accepted" "$(printf '| Codex | — | ⚪ not installed |\n%s' "$PG_EN")" 0
pd_case NO "(с) marker in the paragraph BELOW the Codex row — refused (C2)" "$(printf '| Codex (external critic) | — | ❌ unavailable |\n\n❌ unavailable — решение пользователя — later\n\n%s' "$PG_EN")" 1
pd_case NO "(т) escaped '\\|' example in the side cell, blocking status — refused (C5)" "$(printf '| Codex (пример \\| ❌ недоступен — решение пользователя) | — | ❌ недоступен, решения пользователя ещё нет |\n%s' "$PG_RU")" 1
pd_case NO "(ф) '❌ недоступен — решение пользователя не получено' — refused (marker must end the cell)" "$(printf '| Codex | — | ❌ недоступен — решение пользователя не получено |\n%s' "$PG_RU")" 0
pd_case NO "(ф) '⚪️ not installed yet, installing' — refused" "$(printf '| Codex | — | ⚪️ not installed yet, installing |\n%s' "$PG_EN")" 0
pd_case OK "(ф) trailing dot '⚪️ not installed.' — accepted" "$(printf '| Codex | — | ⚪️ not installed. |\n%s' "$PG_EN")" 0
pd_case OK "(у) indented row '  | Codex | … |' — accepted" "$(printf '  | Codex | — | ⚪️ not installed |\n%s' "$PG_EN")" 0
out=$(pa_decide "$(printf '# P\n\n%s\n' "$PG_RU")" 0 2>&1)
case "$out" in NO*Codex*) ok "decide: no Codex section and no marker — refused, the reason names Codex" ;; *) bad "decide: plain refusal" "$out" ;; esac
mkdir -p "$TMP/pc-empty" "$TMP/pc-has" "$TMP/pc-noexec"
printf '#!/bin/sh\n' > "$TMP/pc-has/codex"; chmod +x "$TMP/pc-has/codex"; printf 'x\n' > "$TMP/pc-noexec/codex"
[ "$(pa_py 'm.codex_found(args[0], [args[1]])' "" "$TMP/pc-empty")" = False ] && ok "codex_found: empty PATH, empty search dir — False" || bad "codex_found empty" ""
[ "$(pa_py 'm.codex_found(args[0], [args[1]])' "" "$TMP/pc-has")" = True ] && ok "codex_found: executable codex in a search dir — True (not on PATH)" || bad "codex_found search dir" ""
[ "$(pa_py 'm.codex_found(args[0], [])' "$TMP/pc-has")" = True ] && ok "codex_found: codex on PATH — True" || bad "codex_found PATH" ""
[ "$(pa_py 'm.codex_found(args[0], [args[1]])' "" "$TMP/pc-noexec")" = False ] && ok "codex_found: non-executable file — False" || bad "codex_found noexec" ""
# HOME as the interpreter got it: Git Bash hands a native Python /h and /extra/bin
# rewritten to C:/Program Files/Git/h…; POSIX sees /h, and the check is the literal one.
out=$(HOME=/h pa_py '(m.os.environ["HOME"] == "/h" or m.WINDOWS) and set(m.search_dirs(args[0])) >= {"/opt/homebrew/bin", "/usr/local/bin", m.os.environ["HOME"] + "/.local/bin"}' "")
[ "$out" = True ] && ok "search_dirs: GG_CODEX_SEARCH_PATHS='' does NOT drop the standard locations (C3)" || bad "search_dirs C3" "$out"
out=$(pa_py '(lambda s: args[0] in s and set(m.search_dirs("")) <= set(s))(m.search_dirs(args[0]))' "/extra/bin")
[ "$out" = True ] && ok "search_dirs: GG_CODEX_SEARCH_PATHS only adds directories" || bad "search_dirs extra" "$out"
# Integration, deterministic in both environments:
mkdir -p "$TMP/pa-bin-codex"
for t in python3 git; do mkwrap "$TMP/pa-bin-codex" "$t" "$(command -v "$t")"; done
cp "$TMP/pc-has/codex" "$TMP/pa-bin-codex/codex"
for n in ni.md ud.md; do echo plan > "$GG_PLANS_DIR/$n"; done
# On Windows the hook is native Python: its subprocess git needs a real git.exe,
# which a sh wrapper without .exe is not. The real git's directory holds no codex.
PA_CODEX_PATH="$TMP/pa-bin-codex"
[ "$IS_WIN" = 1 ] && PA_CODEX_PATH="$PA_CODEX_PATH:$(dirname "$(command -v git)")"
out=$(pa_in ni.md "$(printf '| Codex | — | ⚪️ not installed |\n%s' "$PG_EN")" false | PATH="$PA_CODEX_PATH" CLAUDE_PROJECT_DIR="$PA" "$BASH" "$CH/plan-approved.sh")
[ ! -f "$PAM/ni.md" ] && echo "$out" | grep -q 'codex-plan-critic' && echo "$out" | pa_block \
    && ok "hook: '⚪️ not installed' while codex is on PATH — no mark, block" || bad "hook: not installed + codex on PATH" "$out"
out=$(pa_run ud.md "$(printf "| Codex | — | ❌ unavailable — user's decision |\n%s" "$PG_EN")" false)
[ -f "$PAM/ud.md" ] && echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "systemMessage" in d and "decision" not in d else 1)' \
    && ok "hook: user's decision — mark written and the user is told (systemMessage)" || bad "hook: user's decision mark + systemMessage" "$out"

echo "== plan-approved.py: marks in the repositories the plan names (Репозиторий:) =="
# The plan's header (above the first `## `) names target repositories, one per line; the
# hook writes the mark into each one's common dir too — only main working trees inside
# $HOME with the kit installed (monitorex-hooks/plan-gate.sh). HOME is swapped ONLY in
# pa_run_h; the real ~ is never touched. `pwd -P`: on macOS $TMP is /var/… → /private/var/….
mkdir -p "$TMP/pahome"; PAH=$(cd "$TMP/pahome" && pwd -P)
pr_repo() {   # pr_repo <path> [nokit] — a main tree with the kit installed (unless nokit)
    mkdir -p "$1"; git -C "$1" init -q; git -C "$1" config user.email t@t; git -C "$1" config user.name t
    git -C "$1" commit -q --allow-empty -m i
    if [ "${2:-}" != nokit ]; then
        mkdir -p "$1/.git/monitorex-hooks" "$1/githooks"
        cp "$ROOT/githooks/plan-gate.sh" "$1/.git/monitorex-hooks/plan-gate.sh"
        cp "$ROOT/githooks/plan-gate.sh" "$1/githooks/plan-gate.sh"
        printf 'GG_PLAN_REQUIRED_TYPES="feat"\n' > "$1/.gitguards.conf"
    fi
}
for r in a b c d e f g; do pr_repo "$PAH/dev/$r"; done
pr_repo "$PAH/dev/nokit" nokit; printf 'GG_PLAN_REQUIRED_TYPES="feat"\n' > "$PAH/dev/nokit/.gitguards.conf"
pr_repo "$TMP/outside-repo"
mkdir -p "$PAH/dev/plain"
git -C "$PAH/dev/a" worktree add -q "$PAH/dev/a-wt" -b wta 2>/dev/null
ln -s "$PAH/dev/b" "$PAH/dev/b-link"
pr_repo "$PAH/dev/fake"; rm -rf "$PAH/dev/fake/.git"; printf 'gitdir: %s/dev/c/.git\n' "$PAH" > "$PAH/dev/fake/.git"
pr_repo "$PAH/dev/lockln"; mkdir -p "$PAH/dev/d/.git/monitorex-locks"; ln -s "$PAH/dev/d/.git/monitorex-locks" "$PAH/dev/lockln/.git/monitorex-locks"
pr_repo "$PAH/dev/b2"   # $HOME prefix trap lives in the unit case below
pa_run_h() { pa_in "$@" | HOME="$PAH" CLAUDE_PROJECT_DIR="${PA_SESSION:-$PA}" bash "$CH/plan-approved.sh"; }
# A path in the hook's words. POSIX: the exact string, as before. Native Windows: the
# hook speaks native paths (C:\Users\runneradmin\…), the suite MSYS ones (/tmp/… =
# C:/Users/RUNNER~1/…) — both sides go through realpath + normcase there, nothing else.
pa_msg_count() {   # stdin = hook JSON; $1 = path → how many times systemMessage names it
    python3 -c 'import json, os, sys
m = json.load(sys.stdin)["systemMessage"]; p = sys.argv[1]
if os.name == "nt":
    m, p = os.path.normcase(m), os.path.normcase(os.path.realpath(p))
print(m.count(p))' "$1"
}
same_path() {      # A B → 0 when they name one directory (see pa_msg_count)
    if [ "$IS_WIN" != 1 ]; then [ "$1" = "$2" ]; return; fi
    "$PYBIN" -c 'import os, sys
n = lambda p: os.path.normcase(os.path.realpath(p))
sys.exit(0 if sys.argv[1] and n(sys.argv[1]) == n(sys.argv[2]) else 1)' "$1" "$2"
}
mk() { printf '%s/.git/monitorex-locks/plan-approved/%s' "$1" "$2"; }
pr_plan() { printf '# P\n\n%s\n\n## 🧑‍⚖️ External review Codex\n\nГейт: ✅ пройден\n' "$1"; }

# Pure functions
tr_py() { pa_py 'm.target_repos(args[0])' "$1"; }
[ "$(tr_py "$(printf '# T\n\nРепозиторий: `~/dev/x` (комментарий, `~/dev/y` не трогаем)\n\n## A\n')")" = "['~/dev/x']" ] \
    && ok "target_repos: path is the first token, the rest of the line is a comment (M2)" || bad "target_repos first token" "$(tr_py "$(printf 'Репозиторий: `~/dev/x` (комментарий, `~/dev/y`)\n')")"
[ "$(tr_py "$(printf 'Repository: /abs/y\nРепозиторий: ~/dev/z, ~/dev/w\nРепозиторий: /abs/y\n')")" = "['/abs/y', '~/dev/z']" ] \
    && ok "target_repos: English form, one repository per line, comma is not a separator, duplicates collapsed" || bad "target_repos lines" "$(tr_py "$(printf 'Repository: /abs/y\nРепозиторий: ~/dev/z, ~/dev/w\n')")"
[ "$(tr_py "$(printf '# T\n\n## Раздел\n\nРепозиторий: ~/dev/x\n')")" = "[]" ] \
    && ok "target_repos: below the first '## ' (reviewer sections) — ignored" || bad "target_repos below ##"
[ "$(tr_py "$(printf '# T\n### Под\nРепозиторий: ~/dev/x\n## A\n')")" = "['~/dev/x']" ] \
    && ok "target_repos: '### ' does not end the header" || bad "target_repos ###"
for line in '  Репозиторий: ~/dev/x' '> Репозиторий: ~/dev/x' '- Репозиторий: ~/dev/x' '**Репозиторий:** ~/dev/x' 'текст Репозиторий: ~/dev/x' 'репозиторий: ~/dev/x' 'Репозиторий ~/dev/x' 'Репозиторий:' 'Репозиторий: ,,'; do
    [ "$(tr_py "$(printf '# T\n%s\n' "$line")")" = "[]" ] && ok "target_repos: '$line' — ignored" || bad "target_repos '$line'" "$(tr_py "$(printf '%s\n' "$line")")"
done
[ "$(tr_py "$(printf 'Репозиторий: ~/dev/x\r\n## A\r\n')")" = "['~/dev/x']" ] && ok "target_repos: CRLF — no trailing \\r" || bad "target_repos CRLF"
[ "$(pa_py 'm.header_hidden(args[0])' "$(printf '# T\n<!-- Репозиторий: ~/dev/x -->\n## A\n')")" = True ] \
    && [ "$(pa_py 'm.header_hidden(args[0])' "$(printf '# T\n```\nРепозиторий: ~/dev/x\n```\n## A\n')")" = True ] \
    && [ "$(pa_py 'm.header_hidden(args[0])' "$(printf '# T\nРепозиторий: ~/dev/x\n## A\n```\ncode\n```\n')")" = False ] \
    && ok "header_hidden: '<!--' or a code fence in the header — True; fence below the header — False" || bad "header_hidden"
for hid in $'# T\nРепозиторий: ~/dev/x\rРепозиторий: ~/dev/y\n## A' $'# T\n\e[2KРепозиторий: ~/dev/x\n## A' $'# T\n<details>\nРепозиторий: ~/dev/x\n</details>\n## A'; do
    [ "$(pa_py 'm.header_hidden(args[0])' "$hid")" = True ] && ok "header_hidden: lone \\r / ANSI escape / <details> — True" || bad "header_hidden extra" "$hid"
done
[ "$(tr_py "$(printf '# T\n  ## Indented\nРепозиторий: ~/dev/x\n')")" = "[]" ] && ok "target_repos: an indented '  ## ' still ends the header" || bad "target_repos indented ##"
ar() { pa_py '(lambda r: "OK" if r[0] else "NO " + r[1])(m.accept_repo(args[0], args[1]))' "$1" "$PAH"; }
case "$(ar "$PAH/dev/a")" in OK) ok "accept_repo: main tree with the kit inside HOME — OK" ;; *) bad "accept_repo main tree" "$(ar "$PAH/dev/a")" ;; esac
case "$(ar '~/dev/a' )" in OK) ok "accept_repo: '~' is HOME" ;; *) bad "accept_repo tilde" "$(ar '~/dev/a')" ;; esac
for c in "dev/a|relative" "$TMP/outside-repo|outside" "$PAH/dev/nokit|kit" "$PAH/dev/plain|repository" "$PAH/dev/missing|exist" \
         "$PAH/dev/a-wt|main" "$PAH/dev/b-link|symlink" "$PAH/dev/fake|main" "$PAH/dev/../../outside-repo|outside" "$PAH/dev/a/a.txt|exist"; do
    path=${c%%|*}; want=${c##*|}
    if [ "$want" = symlink ] && [ "$REAL_SYMLINKS" != 1 ]; then na "accept_repo: $(basename "$path") — refused ($want)" "ln -s made a copy"; continue; fi
    out=$(ar "$path")
    case "$out" in NO*"$want"*) ok "accept_repo: $(basename "$path") — refused ($want)" ;; *) bad "accept_repo $path" "$out" ;; esac
done
out=$(pa_py '(lambda r: "OK" if r[0] else "NO " + r[1])(m.accept_repo(args[0], args[1]))' "$PAH/dev/b2" "$PAH/dev/b")
case "$out" in NO*outside*) ok "accept_repo: HOME prefix trap (/h/u vs /h/u2) — commonpath, not startswith" ;; *) bad "accept_repo prefix" "$out" ;; esac
out=$(HOME= pa_py '(lambda r: "OK" if r[0] else "NO " + r[1])(m.accept_repo(args[0], args[1]))' "$PAH/dev/a" "")
case "$out" in NO*) ok "accept_repo: empty HOME — refused (fail-closed)" ;; *) bad "accept_repo empty HOME" "$out" ;; esac

# Integration
for n in rp1.md rp2.md rp3.md rp4.md rp5.md rp6.md rp7.md rp8.md; do echo plan > "$GG_PLANS_DIR/$n"; done
out=$(pa_run_h rp1.md "$(pr_plan "Репозиторий: \`$PAH/dev/a\` (основной)")" false)
[ -f "$(mk "$PAH/dev/a" rp1.md)" ] && [ -f "$PAM/rp1.md" ] \
    && [ "$(grep -c '^source=' "$(mk "$PAH/dev/a" rp1.md)")" = 1 ] && same_path "$(sed -n 's/^source=//p' "$(mk "$PAH/dev/a" rp1.md)")" "$PA" \
    && grep -q '^ts=[0-9]*$' "$(mk "$PAH/dev/a" rp1.md)" && grep -q '^critic=section$' "$(mk "$PAH/dev/a" rp1.md)" \
    && [ "$(printf '%s' "$out" | pa_msg_count "$PAH/dev/a")" -ge 1 ] \
    && echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "decision" not in d else 1)' \
    && ok "hook: named repository — mark there (source=, same format) and in the session repo; the user is told where" || bad "hook: named repository" "$out"
# Without real symlinks (Git Bash copies) the symlinked monitorex-locks target is N/A, the rest still runs.
RP2_LN="$PAH/dev/lockln"; RP2_SYM=symlink
if [ "$REAL_SYMLINKS" != 1 ]; then RP2_LN="$PAH/dev/b"; RP2_SYM=outside; na "hook: symlinked monitorex-locks target refused" "ln -s made a copy"; fi
out=$(pa_run_h rp2.md "$(pr_plan "$(printf 'Репозиторий: %s\nРепозиторий: %s\nРепозиторий: %s\nРепозиторий: %s\nРепозиторий: %s' "$TMP/outside-repo" "$PAH/dev/nokit" "$PAH/dev/a-wt" "$RP2_LN" "$PAH/dev/b")")" false)
[ ! -f "$(mk "$TMP/outside-repo" rp2.md)" ] && [ ! -f "$(mk "$PAH/dev/nokit" rp2.md)" ] && [ ! -f "$(mk "$PAH/dev/a" rp2.md)" ] \
    && [ ! -f "$PAH/dev/d/.git/monitorex-locks/plan-approved/rp2.md" ] && [ -f "$(mk "$PAH/dev/b" rp2.md)" ] \
    && echo "$out" | grep -q 'outside' && echo "$out" | grep -q "$RP2_SYM" && echo "$out" | grep -q 'main' \
    && ok "hook: refused targets (outside HOME, no kit, worktree, symlinked monitorex-locks) get no mark and a reason; the good one still does" || bad "hook: refused targets" "$out"
out=$(pa_run_h rp3.md "$(pr_plan "$(for r in a b c d e f g; do printf 'Репозиторий: %s\n' "$PAH/dev/$r"; done)")" false)
[ -f "$(mk "$PAH/dev/e" rp3.md)" ] && [ ! -f "$(mk "$PAH/dev/f" rp3.md)" ] && [ ! -f "$(mk "$PAH/dev/g" rp3.md)" ] && echo "$out" | grep -q '5' \
    && ok "hook: more than 5 targets — the first five, the rest refused" || bad "hook: limit 5" "$out"
out=$(pa_run_h rp4.md "$(printf '# P\n<!-- note -->\nРепозиторий: %s\n\n## External review Codex\n\nГейт: ✅ пройден\n' "$PAH/dev/a")" false)
[ ! -f "$(mk "$PAH/dev/a" rp4.md)" ] && [ -f "$PAM/rp4.md" ] && echo "$out" | grep -q '<!--' \
    && ok "hook: hidden text in the header — no foreign marks, session mark kept, reason told" || bad "hook: hidden header" "$out"
out=$(pa_run_h rp5.md "$(printf '# P\nРепозиторий: %s\n\n## P\n\nГейт: ✅ пройден\n' "$PAH/dev/a")" false)
[ ! -f "$(mk "$PAH/dev/a" rp5.md)" ] && [ ! -f "$PAM/rp5.md" ] && echo "$out" | pa_block \
    && ok "hook: plan refused by the gate (no Codex) — no mark anywhere" || bad "hook: refused plan" "$out"
out=$(pa_run_h rp6.md "$(pr_plan "Репозиторий: $PAH/dev/a")" true)
[ ! -f "$(mk "$PAH/dev/a" rp6.md)" ] && ok "hook: isAgent — no foreign mark" || bad "hook: agent foreign" "$out"
out=$(PA_SESSION="$TMP/pa-norepo" pa_run_h rp7.md "$(pr_plan "Репозиторий: $PAH/dev/c")" false); rc=$?
[ $rc -eq 0 ] && [ -f "$(mk "$PAH/dev/c" rp7.md)" ] && echo "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' \
    && ok "hook: session outside any repository — the named repository still gets the mark" || bad "hook: session not a repo" "rc=$rc $out"
out=$(pa_run_h rp8.md "$(printf '# P\nРепозиторий: %s\nРепозиторий: %s\n\n| Codex | — | ❌ unavailable — user'"'"'s decision |\n\nГейт: ✅ пройден\n' "$PA" "$PAH/dev/a")" false)
n=$(printf '%s' "$out" | python3 -c 'import json,sys; t=sys.stdin.read(); d=json.JSONDecoder(); o,i=d.raw_decode(t); print(1 if not t[i:].strip() else 2)' 2>/dev/null)
[ "$n" = 1 ] && echo "$out" | grep -q 'without' && [ -f "$(mk "$PAH/dev/a" rp8.md)" ] \
    && ok "hook: critic skipped + named repositories (one is the session repo) — ONE JSON object, both messages" || bad "hook: one JSON" "$out"
out=$(pa_run good.md "$PA_GOOD" false)
[ -z "$out" ] && ok "hook: plan without 'Репозиторий:' — silent, as before" || bad "hook: silent without targets" "$out"
echo plan > "$GG_PLANS_DIR/rp9.md"
out=$(PA_SESSION="$TMP/pa-norepo" pa_run_h rp9.md "$(printf '# P\nРепозиторий: %s\nРепозиторий: %s\n\n| Codex | — | ❌ unavailable — user'"'"'s decision |\n\nГейт: ✅ пройден\n' "$PAH/dev/a" "~/dev/a")" false)
[ "$(printf '%s' "$out" | pa_msg_count "$PAH/dev/a")" = 1 ] && echo "$out" | grep -q 'WITHOUT' \
    && ok "hook: same repository written twice — listed once; critic notice when a named repo got the mark" || bad "hook: dedup list" "$out"
echo plan > "$GG_PLANS_DIR/rp10.md"
out=$(PA_SESSION="$TMP/pa-norepo" pa_run_h rp10.md "$(printf '# P\n\n| Codex | — | ❌ unavailable — user'"'"'s decision |\n\nГейт: ✅ пройден\n')" false)
[ -z "$out" ] && ok "hook: no mark written anywhere — no false 'was written WITHOUT the critic' notice" || bad "hook: false notice" "$out"
echo plan > "$GG_PLANS_DIR/rp11.md"
# Header control characters → hidden header (no foreign marks); a refusal text is cleaned anyway.
[ "$(pa_py 'm.header_hidden(args[0])' "$(printf '# T\nРепозиторий: ~/dev/evil \b\b\b\n## A')")" = True ] \
    && ok "header_hidden: any control character (backspace) — True" || bad "header_hidden backspace"
out=$(pa_py '(lambda r: r)(m._CTRL.sub(" ", args[0]))' "$(printf 'a\033]0;x\007b')")
[ "$out" = "a ]0;x b" ] && ok "refusal text: control characters replaced before reaching the user" || bad "refusal text cleaning" "$out"
printf '[feat]: x\n\nPlan: rp1.md\n' > "$TMP/pr-m"
( cd "$PAH/dev/a" && sh githooks/plan-gate.sh "$TMP/pr-m" ) >/dev/null 2>&1 && ok "end to end: plan-gate.sh in the named repository accepts [feat] with Plan:" || bad "end to end: named repo gate"
out=$( cd "$PAH/dev/g" && sh githooks/plan-gate.sh "$TMP/pr-m" 2>&1 ); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q 'no approval mark' && ok "end to end: a repository the plan did not name — still rejected" || bad "end to end: unnamed repo" "$out"

echo "== plan-approved.py: the project's plans directory (plansDirectory) =="
# GG_PLANS_DIR unset, HOME = $PAH: only the project's directory and $PAH/.claude/plans count.
pa_run_nd() { pa_in "$@" | env -u GG_PLANS_DIR HOME="$PAH" CLAUDE_PROJECT_DIR="${PA_SESSION:-$PA}" bash "$CH/plan-approved.sh"; }
PAP=$(cd "$PA" && pwd -P)
mkdir -p "$PAP/.plans"; echo plan > "$PAP/.plans/pd1.md"
out=$(pa_run_nd pd1.md "$PA_GOOD" false "" "$PAP/.plans/pd1.md")
[ -f "$PAM/pd1.md" ] && ok "pd hook: plan in <project>/.plans — mark written" || bad "pd hook: .plans" "$out"
if [ "$REAL_SYMLINKS" = 1 ]; then
    ln -s "$TMP/pa-out/evil.md" "$PAP/.plans/pdlink.md"
    out=$(pa_run_nd pdlink.md "$PA_GOOD" false "" "$PAP/.plans/pdlink.md")
    [ ! -f "$PAM/pdlink.md" ] && [ ! -f "$PAM/evil.md" ] && ok "pd hook: symlink in .plans pointing out — no mark" || bad "pd hook: symlink" "$out"
else na "pd hook: symlink in .plans pointing out — no mark" "ln -s made a copy"; fi
echo p > "$TMP/pa-out/pd2.md"
out=$(pa_run_nd pd2.md "$PA_GOOD" false "" "$TMP/pa-out/pd2.md")
[ ! -f "$PAM/pd2.md" ] && echo "$out" | grep -q 'directly in' && ok "pd hook: plan outside every plans directory — no mark" || bad "pd hook: outside" "$out"
mkdir -p "$PAP/.claude" "$PAP/planning"; printf '{"plansDirectory": "planning"}\n' > "$PAP/.claude/settings.json"
echo plan > "$PAP/planning/pd3.md"; echo plan > "$PAP/.plans/pd4.md"
out=$(pa_run_nd pd3.md "$PA_GOOD" false "" "$PAP/planning/pd3.md")
[ -f "$PAM/pd3.md" ] && ok "pd hook: own plansDirectory 'planning' — mark written" || bad "pd hook: own dir" "$out"
out=$(pa_run_nd pd4.md "$PA_GOOD" false "" "$PAP/.plans/pd4.md")
[ ! -f "$PAM/pd4.md" ] && ok "pd hook: own plansDirectory — .plans no longer counts" || bad "pd hook: own dir, .plans" "$out"
printf '{"plansDirectory": "../pa-out"}\n' > "$PAP/.claude/settings.json"; echo p > "$TMP/pa-out/pd5.md"
out=$(pa_run_nd pd5.md "$PA_GOOD" false "" "$TMP/pa-out/pd5.md")
[ ! -f "$PAM/pd5.md" ] && ok "pd hook: plansDirectory '../pa-out' — not used" || bad "pd hook: .. dir" "$out"
rm -f "$PAP/.claude/settings.json"
# A plan for several repositories: the plan file is copied into each target's plans directory
# — only targets that switched it on (plansDirectory in their settings.json)
for t in e f; do mkdir -p "$PAH/dev/$t/.claude"; printf '{"plansDirectory": ".plans"}\n' > "$PAH/dev/$t/.claude/settings.json"; done
echo plan > "$PAP/.plans/pd6.md"
out=$(pa_run_nd pd6.md "$(pr_plan "Репозиторий: $PAH/dev/e")" false "" "$PAP/.plans/pd6.md")
[ -f "$(mk "$PAH/dev/e" pd6.md)" ] && [ -f "$PAH/dev/e/.plans/pd6.md" ] && grep -q 'Репозиторий' "$PAH/dev/e/.plans/pd6.md" \
    && ok "pd hook: target repository gets the mark AND the plan text in its .plans" || bad "pd hook: target copy" "$out"
printf '[feat]: x\n\nPlan: pd6.md\n' > "$TMP/pd-m"
( cd "$PAH/dev/e" && env -u GG_PLANS_DIR HOME="$PAH" sh githooks/plan-gate.sh "$TMP/pd-m" ) >/dev/null 2>&1 \
    && ok "pd end to end: [feat] in the target repository passes without GG_PLANS_DIR" || bad "pd end to end: target repo"
mkdir -p "$PAH/dev/f/.plans"; echo "someone else's plan" > "$PAH/dev/f/.plans/pd7.md"; echo plan > "$PAP/.plans/pd7.md"
out=$(pa_run_nd pd7.md "$(pr_plan "Репозиторий: $PAH/dev/f")" false "" "$PAP/.plans/pd7.md")
grep -qx "someone else's plan" "$PAH/dev/f/.plans/pd7.md" && echo "$out" | grep -q 'pd7.md' \
    && ok "pd hook: a different plan with the same name in the target — not overwritten, the user is told" || bad "pd hook: target conflict" "$out"
echo plan > "$PAP/.plans/pd8.md"
out=$(pa_run_nd pd8.md "$(pr_plan "Репозиторий: $PAH/dev/c")" false "" "$PAP/.plans/pd8.md")
[ -f "$(mk "$PAH/dev/c" pd8.md)" ] && [ ! -e "$PAH/dev/c/.plans" ] \
    && ok "pd hook: target without plansDirectory — mark written, no stray .plans folder created there" || bad "pd hook: target not switched on" "$out"
mkdir -p "$PAH/.claude/plans"; echo plan > "$PAH/.claude/plans/pd9.md"
out=$(pa_run_nd pd9.md "$(pr_plan "Репозиторий: $PAH/dev/e")" false "" "$PAH/.claude/plans/pd9.md")
[ -f "$(mk "$PAH/dev/e" pd9.md)" ] && [ ! -e "$PAH/dev/e/.plans/pd9.md" ] \
    && ok "pd hook: plan in the old ~/.claude/plans — the target finds it there, no copy" || bad "pd hook: legacy source copy" "$out"
rm -rf "$PAP/.plans" "$PAP/planning"

guard_unit_cases

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
# Blob ids, not bytes: a Windows checkout (core.autocrlf=true) has CRLF on disk for the same blob.
RSB=$(git -C "$RS" hash-object scripts/install-git-guards.sh)
[ $rc -eq 0 ] && [ -n "$RSB" ] && [ "$(git -C "$TMP/rs-wt/old" hash-object scripts/install-git-guards.sh 2>/dev/null)" = "$RSB" ] \
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
T0=$SECONDS; out=$(iw GH_STUB=hang $TO bash "$IW/scripts/wt-new.sh" --issue 6 2>&1); rc=$?; T=$((SECONDS-T0))
[ $rc -eq 1 ] && [ $T -lt 12 ] && echo "$out" | grep -q 'did not answer within 2s' && ok "hanging gh — cut off by GG_ISSUE_TIMEOUT (${T}s)" || bad "hanging gh" "rc=$rc ${T}s $out"
# PATH = the existing directories minus every one that holds gh. CI runners and
# some distros keep gh in /usr/bin itself: the other tools of such a directory get
# exec wrappers (no symlink farm — Git Bash copies symlinks, and copied .exe files
# lose their DLLs; on Windows gh lives in a directory of its own).
NOGH="$TMP/nogh"; mkdir -p "$NOGH"; NOGH_PATH=""
NOGH_IFS=$IFS; IFS=:
for d in $PATH; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    if [ -e "$d/gh" ] || [ -e "$d/gh.exe" ]; then
        for f in "$d"/*; do
            n=${f##*/}; [ "$IS_WIN" = 1 ] && n=${n%.exe}
            case "$n" in gh|*\'*|*'"'*) continue ;; esac
            [ -f "$f" ] && [ -x "$f" ] && [ ! -e "$NOGH/$n" ] && mkwrap "$NOGH" "$n" "$f"
        done
    else
        NOGH_PATH="${NOGH_PATH:+$NOGH_PATH:}$d"
    fi
done
IFS=$NOGH_IFS
out=$(env PATH="$NOGH:$NOGH_PATH" bash "$IW/scripts/wt-new.sh" --issue 6 2>&1); rc=$?
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

echo "== wt-new / wt-done: the project's plans directory =="
mkdir -p "$IW/.claude"; printf '{"plansDirectory": ".plans"}\n' > "$IW/.claude/settings.json"
grep -qx '/.plans/' "$IW/.git/info/exclude" 2>/dev/null || printf '/.plans/\n/.claude/\n' >> "$IW/.git/info/exclude"
out=$(iw bash "$IW/scripts/wt-new.sh" pd-plans 2>&1); rc=$?
PDW=$(git -C "$IW" worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/wt\/pd-plans$/{print p}')
[ $rc -eq 0 ] && [ -n "$PDW" ] && [ -d "$PDW/.plans" ] && ok "wt-new: the new tree gets the plans directory (plansDirectory)" || bad "wt-new: plans directory" "$out"
echo "plan A" > "$PDW/.plans/pda.md"
mkdir -p "$IW/.plans"; echo "plan B" > "$IW/.plans/pdb.md"; echo "plan B, other text" > "$PDW/.plans/pdb.md"
out=$(iw bash "$IW/scripts/wt-done.sh" pd-plans 2>&1); rc=$?
[ $rc -ne 0 ] && [ -d "$PDW" ] && [ -f "$PDW/.plans/pda.md" ] && echo "$out" | grep -q 'pdb.md' \
    && ok "wt-done: a different plan with the same name in the main tree — nothing moved, the tree is NOT removed" || bad "wt-done: plan conflict" "$out"
out=$(iw bash "$IW/scripts/wt-done.sh" pd-plans --force 2>&1); rc=$?
[ -d "$PDW" ] && ok "wt-done --force: the plan conflict still keeps the tree" || bad "wt-done --force: plan conflict" "$out"
echo "plan B" > "$PDW/.plans/pdb.md"     # now the same text as in the main tree
out=$(iw bash "$IW/scripts/wt-done.sh" pd-plans 2>&1); rc=$?
[ $rc -eq 0 ] && [ ! -d "$PDW" ] && grep -qx "plan A" "$IW/.plans/pda.md" && grep -qx "plan B" "$IW/.plans/pdb.md" \
    && ok "wt-done: plans moved into the main tree (identical one deduplicated), tree removed" || bad "wt-done: plans moved" "$out"
# A plans folder the project keeps in git is the project's own business: not moved
out=$(iw bash "$IW/scripts/wt-new.sh" pd-tracked 2>&1)
PDT=$(git -C "$IW" worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/wt\/pd-tracked$/{print p}')
printf '{"plansDirectory": "docs/plans"}\n' > "$IW/.claude/settings.json"
mkdir -p "$PDT/docs/plans"; echo "tracked plan" > "$PDT/docs/plans/t.md"
git -C "$PDT" add docs/plans/t.md; git -C "$PDT" -c core.hooksPath=/dev/null commit -qm "tracked plan"
out=$(iw bash "$IW/scripts/wt-done.sh" pd-tracked --force 2>&1); rc=$?
[ ! -e "$IW/docs/plans/t.md" ] && ok "wt-done: a plans folder tracked in git is not moved" || bad "wt-done: tracked plans moved" "$out"
rm -rf "$IW/.plans" "$IW/.claude" "$IW/docs"

echo "== wt-new / wt-done: Claude config kept out of git =="
grep -qx '/CLAUDE.md' "$IW/.git/info/exclude" 2>/dev/null || printf '/CLAUDE.md\n/.claude/\n' >> "$IW/.git/info/exclude"
echo "project rules" > "$IW/CLAUDE.md"; echo "not ignored" > "$IW/CLAUDE.local.md"
mkdir -p "$IW/.claude/agents"; echo "own agent" > "$IW/.claude/agents/rev.md"
out=$(iw bash "$IW/scripts/wt-new.sh" lc-link 2>&1); rc=$?
LCW=$(git -C "$IW" worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^branch refs\/heads\/wt\/lc-link$/{print p}')
[ $rc -eq 0 ] && [ -n "$LCW" ] && grep -qx "project rules" "$LCW/CLAUDE.md" 2>/dev/null \
    && grep -qx "own agent" "$LCW/.claude/agents/rev.md" 2>/dev/null && [ -d "$LCW/.claude/agents" ] && [ ! -L "$LCW/.claude/agents" ] \
    && ok "wt-new: ignored CLAUDE.md and .claude/agents/* reach the tree, the folder is real" || bad "wt-new: local Claude config" "$out"
[ -n "$LCW" ] && [ ! -e "$LCW/CLAUDE.local.md" ] && ok "wt-new: a file git does not ignore is not linked" || bad "wt-new: unignored file linked" "$out"
[ -n "$LCW" ] && [ -z "$(git -C "$LCW" status --porcelain -- CLAUDE.md .claude)" ] \
    && ok "wt-new: the linked config leaves git status clean" || bad "wt-new: linked config in status" "$(git -C "$LCW" status --porcelain 2>&1)"
out=$(iw bash "$IW/scripts/wt-done.sh" lc-link 2>&1); rc=$?
[ $rc -eq 0 ] && [ ! -d "$LCW" ] && grep -qx "project rules" "$IW/CLAUDE.md" && grep -qx "own agent" "$IW/.claude/agents/rev.md" \
    && ok "wt-done: the tree with linked config is removed, the main folder's files survive" || bad "wt-done: linked config" "$out"
rm -rf "$IW/CLAUDE.md" "$IW/CLAUDE.local.md" "$IW/.claude"

if [ -n "$KIT" ]; then
echo "== settings-merge.py: plansDirectory and the plans folder =="
SM="$TMP/sm"; mkrepo "$SM"
python3 "$KIT/settings-merge.py" "$SM" >/dev/null 2>&1
smv() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("plansDirectory"))' "$1/.claude/settings.json"; }
[ "$(smv "$SM")" = ".plans" ] && [ -d "$SM/.plans" ] && grep -qx '/.plans/' "$SM/.gitignore" && grep -qx '/.plans/' "$SM/.git/info/exclude" \
    && ok "settings-merge: plansDirectory '.plans', the folder, .gitignore and info/exclude" || bad "settings-merge: plans" "$(cat "$SM/.claude/settings.json" "$SM/.gitignore" 2>&1)"
python3 "$KIT/settings-merge.py" "$SM" >/dev/null 2>&1
[ "$(grep -c '^/\.plans/$' "$SM/.gitignore")" = 1 ] && [ "$(grep -c '^/\.plans/$' "$SM/.git/info/exclude")" = 1 ] \
    && ok "settings-merge: a re-run duplicates nothing" || bad "settings-merge: rerun" "$(cat "$SM/.gitignore")"
SM2="$TMP/sm2"; mkrepo "$SM2"; mkdir -p "$SM2/.claude"; printf '{"plansDirectory": "planning", "x": 1}\n' > "$SM2/.claude/settings.json"
python3 "$KIT/settings-merge.py" "$SM2" >/dev/null 2>&1
[ "$(smv "$SM2")" = "planning" ] && [ -d "$SM2/planning" ] && grep -qx '/planning/' "$SM2/.gitignore" && [ ! -d "$SM2/.plans" ] \
    && ok "settings-merge: the project's own plansDirectory is kept and set up" || bad "settings-merge: own dir" "$(cat "$SM2/.claude/settings.json")"
SM3="$TMP/sm3"; mkrepo "$SM3"; mkdir -p "$SM3/.claude"; printf '{"plansDirectory": "../out"}\n' > "$SM3/.claude/settings.json"
out=$(python3 "$KIT/settings-merge.py" "$SM3" 2>&1)
[ "$(smv "$SM3")" = "../out" ] && [ ! -d "$TMP/out" ] && echo "$out" | grep -qi 'plansDirectory' \
    && ok "settings-merge: plansDirectory outside the project — left alone, nothing created, said out loud" || bad "settings-merge: bad dir" "$out"
SM4="$TMP/sm4"; mkrepo "$SM4"; mkdir -p "$SM4/.claude" "$SM4/docs/plans"; printf '{"plansDirectory": "docs/plans"}\n' > "$SM4/.claude/settings.json"
echo plan > "$SM4/docs/plans/p.md"; git -C "$SM4" add docs/plans/p.md; git -C "$SM4" commit -qm plans
out=$(python3 "$KIT/settings-merge.py" "$SM4" 2>&1)
! grep -q 'docs/plans' "$SM4/.gitignore" 2>/dev/null && ! grep -q 'docs/plans' "$SM4/.git/info/exclude" \
    && ok "settings-merge: a plans folder the project keeps in git — not ignored" || bad "settings-merge: tracked dir ignored" "$out"
fi

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
pe_reset; mkdir -p "$PELOCK"; printf 'pid=%s\ntime=%s\n' "$(native_pid $$)" "$(date +%s)" > "$PELOCK/owner"
pe_run "$PE/lib/a.ts" >/dev/null
[ "$(pe_calls)" = 0 ] && [ -d "$PELOCK" ] && grep -qx 'lib/a.ts' "$PEQ" && ok "run lock held by a live pid — no run, the path waits in the queue" || bad "live lock" "$(pe_calls)"
# two worktrees of one repository: own queues, one shared lock
git -C "$PE" worktree add -q "$TMP/pe-wt2" -b pe2 2>/dev/null
pe_run "$TMP/pe-wt2/lib/a.ts" "$TMP/pe-wt2" >/dev/null
PEQ2="$PE/.git/worktrees/pe-wt2/post-edit-tests/pending"
[ "$(pe_calls)" = 0 ] && grep -qx 'lib/a.ts' "$PEQ2" 2>/dev/null && [ "$(grep -c . "$PEQ")" = 1 ] \
    && ok "two worktrees — separate queues, the lock is shared (no run in the second tree)" || bad "two worktrees" "$(pe_calls) q2=$(cat "$PEQ2" 2>&1)"
printf 'pid=%s\ntime=%s\n' "$(dead_native_pid)" "$(date +%s)" > "$PELOCK/owner"
pe_run "$PE/lib/a.ts" >/dev/null
[ "$(pe_calls)" = 1 ] && [ ! -d "$PELOCK" ] && ok "run lock of a dead pid — removed, the run happens" || bad "dead lock" "$(pe_calls)"

pe_conf 'GG_POST_EDIT_MAX=1'; pe_reset; echo sleep > "$PEMODE"; rm -f "$TMP/pe-child"
T0=$SECONDS; out=$(pe_run "$PE/lib/a.ts"); T=$((SECONDS-T0))
child=$(cat "$TMP/pe-child" 2>/dev/null); sleep 1
{ [ -z "$out" ] && [ $T -lt 15 ] && [ -n "$child" ] && ! kill -0 "$child" 2>/dev/null && [ ! -d "$PELOCK" ]; } \
    && ok "GG_POST_EDIT_MAX=1 — the whole process group killed (${T}s), lock released, no block" \
    || bad "ceiling" "out=$out T=$T child=$child alive=$(kill -0 "$child" 2>/dev/null && echo yes || echo no) lock=$([ -d "$PELOCK" ] && echo held || echo free)"
[ -n "$child" ] && kill "$child" 2>/dev/null
echo green > "$PEMODE"

out=$(printf 'not json {' | CLAUDE_PROJECT_DIR="$PE" bash "$CH/post-edit-tests.sh"); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "broken JSON — exit 0, silent" || bad "broken JSON" "rc=$rc $out"
NOPY="$TMP/nopy"; mkdir -p "$NOPY"; for t in cat dirname; do mkwrap "$NOPY" "$t" "$(command -v $t)"; done
pe_reset
out=$(pe_in "$PE/lib/a.ts" "$PE" | env PATH="$NOPY" CLAUDE_PROJECT_DIR="$PE" /bin/bash "$CH/post-edit-tests.sh"); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && [ "$(pe_calls)" = 0 ] && ok "no python3 — exit 0, silent" || bad "no python3" "rc=$rc $out"

# The runner is missing (a tree whose package install failed): infrastructure, not a red test
printf 'GG_POST_EDIT_TESTS=1\nGG_TEST_CMD="%s/no-such-runner"\nGG_POST_EDIT_DEBOUNCE=0\nGG_POST_EDIT_REPO_GAP=0\n' "$TMP" > "$PE/.gitguards.conf"
pe_reset; out=$(pe_run "$PE/lib/a.ts"); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "runner not found (rc 127) — silent, no block" || bad "runner not found" "rc=$rc $out"
printf 'GG_POST_EDIT_TESTS=1\nGG_TEST_CMD="no-such-runner-xyz"\nGG_POST_EDIT_DEBOUNCE=0\nGG_POST_EDIT_REPO_GAP=0\n' > "$PE/.gitguards.conf"
pe_reset; out=$(pe_run "$PE/lib/a.ts")
[ -z "$out" ] && ok "runner not on PATH ('command not found') — silent" || bad "command not found" "$out"
pe_conf; pe_reset; echo red > "$PEMODE"; out=$(pe_run "$PE/lib/a.ts")
printf '%s' "$out" | grep -q '"decision": "block"' && ok "red run after that — still a block" || bad "red after missing runner" "$out"
echo green > "$PEMODE"

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
    # Every top-level file of the kit travels along (detect.py, settings-merge.py and,
    # from 1.3.0, attributes.py and selftest.sh): install.sh calls them by path.
    fake_kit() {   # $1 = directory → a copy of the kit, acceptance stubbed
        mkdir -p "$1"; cp -R "$KIT/files" "$1/files"
        for f in "$KIT"/*; do [ -f "$f" ] && [ "${f##*/}" != install.sh ] && cp "$f" "$1/"; done
        sed "s#/tmp/gg-accept.log#$TMP/gg-accept.log#g" "$KIT/install.sh" > "$1/install.sh"
        printf '#!/usr/bin/env bash\necho "  passed: 1   failed: 0"\n' > "$1/files/scripts/test-git-guards.sh"
    }
    FK="$TMP/fakekit"; fake_kit "$FK"
    IT="$TMP/it"; mkrepo "$IT"; echo '{"devDependencies":{"vitest":"1"}}' > "$IT/package.json"
    out=$(GG_EMBEDDED=1 bash "$FK/install.sh" "$IT" 2>&1); rc=$?
    [ $rc -eq 0 ] && grep -qx 'GG_POST_EDIT_TESTS=1' "$IT/.gitguards.conf" && grep -q 'post-edit-tests.sh' "$IT/.claude/settings.json" \
        && [ -x "$IT/.git/monitorex-hooks/plan-gate.sh" ] && ok "install.sh: new project — config with the new keys, hooks registered, plan-gate installed" || bad "install.sh first run" "$out"
    printf '# edited by a human\nGG_TEST_CMD=""\n' > "$IT/.gitguards.conf"; cp "$IT/.claude/settings.json" "$TMP/it.settings"
    out=$(GG_EMBEDDED=1 bash "$FK/install.sh" "$IT" 2>&1); rc=$?
    [ $rc -eq 0 ] && [ "$(head -1 "$IT/.gitguards.conf")" = "# edited by a human" ] && cmp -s "$IT/.claude/settings.json" "$TMP/it.settings" \
        && ok "install.sh rerun — existing .gitguards.conf not overwritten, settings.json unchanged" || bad "install.sh rerun" "$out"
fi

echo "== prepare-commit-msg: Session-Id on commits git itself creates =="
# 11.11.2026: merging origin/main into a lagging branch (conflicts → `git commit
# --no-edit`, as the rules say) gave a commit without Session-Id, and pre-push
# called it someone else's work. The hook stamps the actor; an existing id stays.
PM="$TMP/pcm"; mkrepo "$PM"; mkdir -p "$PM/hk"; cp "$ROOT/githooks/prepare-commit-msg" "$PM/hk/"; chmod +x "$PM/hk/prepare-commit-msg"
git -C "$PM" config core.hooksPath "$PM/hk"
sid() { git -C "$PM" log -1 --format='%(trailers:key=Session-Id,valueonly,separator=%x2C)' "${1:-HEAD}"; }
pmc() { ( cd "$PM" && env -u CLAUDE_CODE_SESSION_ID MONITOREX_ACTOR="$1" git "${@:2}" ) >/dev/null 2>&1; }
B0=$(git -C "$PM" symbolic-ref --short HEAD)
git -C "$PM" checkout -qb side; echo side > "$PM/a.txt"; pmc s0 commit -qam side
git -C "$PM" checkout -q "$B0"; echo base > "$PM/a.txt"; pmc s0 commit -qam base
git -C "$PM" checkout -q side
pmc s1 merge "$B0"; [ -f "$PM/.git/MERGE_HEAD" ] && ok "fixture: merge stopped on a conflict" || bad "fixture: conflict expected"
echo resolved > "$PM/a.txt"; git -C "$PM" add a.txt; pmc s1 commit -q --no-edit
[ "$(git -C "$PM" log -1 --format=%P | wc -w | tr -d ' ')" = "2" ] && [ "$(sid)" = "s1" ] \
    && ok "conflicted merge + commit --no-edit → Session-Id of the actor" || bad "conflicted merge trailer" "$(git -C "$PM" log -1 --format=%B)"
git -C "$PM" checkout -q "$B0"; echo n > "$PM/b.txt"; pmc s0 commit -qam more; git -C "$PM" checkout -q side
pmc s1 merge -q --no-edit "$B0"
[ "$(git -C "$PM" log -1 --format=%P | wc -w | tr -d ' ')" = "2" ] && [ "$(sid)" = "s1" ] \
    && ok "clean git merge --no-edit (wt-new --merge-main) → Session-Id of the actor" || bad "clean merge trailer" "$(git -C "$PM" log -1 --format=%B)"
printf 'neighbor work\n\nSession-Id: other\n' > "$PM/.m"; echo x > "$PM/s.sh"; git -C "$PM" add s.sh
pmc other commit -q -F .m; pmc s1 commit -q --amend --no-edit
[ "$(sid)" = "other" ] && ok "amend of a neighbor's commit keeps the neighbor's id (not stolen)" || bad "foreign id kept" "$(sid)"
# Rewrites never stamp a commit that had NO id (a human without MONITOREX_ACTOR).
git -C "$PM" checkout -q -b hum "$B0"; echo h1 > "$PM/h1.txt"; git -C "$PM" add h1.txt; pmc "" commit -qm human1
echo h2 > "$PM/h2.txt"; git -C "$PM" add h2.txt; pmc "" commit -qm human2; H2=$(git -C "$PM" rev-parse HEAD)
pmc s1 commit -q --amend --no-edit
[ -z "$(sid)" ] && ok "amend of a commit without an id → still no id" || bad "amend no-id" "$(sid)"
git -C "$PM" checkout -q -b pick "$B0"; pmc s1 cherry-pick hum
[ -n "$(git -C "$PM" log -1 --format=%s | grep human2)" ] && [ -z "$(sid)" ] \
    && ok "cherry-pick of a commit without an id → still no id" || bad "cherry-pick no-id" "$(git -C "$PM" log -1 --format='%s / %(trailers:key=Session-Id,valueonly)')"
git -C "$PM" checkout -q "$B0"; echo r > "$PM/rb.txt"; git -C "$PM" add rb.txt; pmc s0 commit -qm base2
git -C "$PM" checkout -q hum; pmc s1 rebase -q "$B0"
[ "$(git -C "$PM" log -2 --format='%(trailers:key=Session-Id,valueonly)' | tr -d '\n')" = "" ] && [ "$(git -C "$PM" merge-base HEAD "$B0")" = "$(git -C "$PM" rev-parse "$B0")" ] \
    && ok "rebase of commits without an id → still no id" || bad "rebase no-id" "$(git -C "$PM" log -2 --format='%s / %(trailers:key=Session-Id,valueonly)')"
git -C "$PM" checkout -q -b sq "$B0"; pmc s1 merge -q --squash hum; pmc s1 commit -q --no-edit
[ -z "$(sid)" ] && ok "merge --squash → no id stamped (neighbor trailers are invisible there)" || bad "squash" "$(sid)"
git -C "$PM" checkout -q side
printf 'own\n' > "$PM/.m"; echo y > "$PM/s.sh"; git -C "$PM" add s.sh; pmc s1 commit -q -F .m
[ "$(sid)" = "s1" ] && ok "plain commit in a worktree → Session-Id of the actor (one, not duplicated)" || bad "plain commit trailer" "$(sid)"
echo z > "$PM/b.txt"; git -C "$PM" add b.txt; pmc "" commit -qm noactor
[ -z "$(sid)" ] && ok "no actor → message untouched" || bad "no actor" "$(sid)"

# ═════════════════════════════════════════════════════════════════════════════
# .gitguards.conf is READ as text — from the protected branch — and never
# executed (13.11.2026). The five kit scripts used to `source` it: any line added
# to an uncommitted copy ran inside a script the guard trusts by name, and a
# branch's GG_PROTECTED moved the release-gate base.
# ═════════════════════════════════════════════════════════════════════════════
echo "== .gitguards.conf: read from the protected branch, never executed =="
EV="$TMP/cf-evidence"; mkdir -p "$EV"
CFH="$TMP/cf-home"; mkdir -p "$CFH"
ev_clear() { rm -f "$EV"/*; }
ev_none()  { [ -z "$(ls -A "$EV")" ]; }
ev_list()  { ls "$EV" | tr '\n' ' '; }
nh() { git -c core.hooksPath=/dev/null "$@"; }
CL="$ROOT/scripts/git-guards/conf.sh"

# Unit: the parser. Values come back exactly as the shell would see them inside
# the quotes — and nothing is evaluated on the way.
cv() {   # $1 = key, $2 = config text → value (rc 1 = absent, 2 = invalid); stderr to $TMP/cv.err
    ( [ -f "$CL" ] || exit 9; . "$CL"; printf '%s\n' "$2" | HOME=/h gg_conf_value "$1" ) 2>"$TMP/cv.err"
}
cvis() { # $1 = label, $2 = key, $3 = text, $4 = expected
    local got; got=$(cv "$2" "$3"); [ $? -eq 0 ] && [ "$got" = "$4" ] && ok "parser: $1" || bad "parser: $1" "got [$got] $(cat "$TMP/cv.err")"
}
cvbad() { # $1 = label, $2 = key, $3 = text → rejected with a warning that names the key
    cv "$2" "$3" >/dev/null; local rc=$?
    [ $rc -eq 2 ] && grep -q "ignoring invalid $2" "$TMP/cv.err" && ok "parser: $1 — rejected out loud" || bad "parser: $1" "rc=$rc $(cat "$TMP/cv.err")"
}
cvis 'GG_WT_DIR="$HOME/x" — $HOME expanded' GG_WT_DIR 'GG_WT_DIR="$HOME/x"' '/h/x'
cvis 'GG_WT_DIR=~/x — ~ expanded' GG_WT_DIR 'GG_WT_DIR=~/x' '/h/x'
cvis 'GG_WT_DIR="${HOME}/x y" — braces, spaces kept' GG_WT_DIR 'GG_WT_DIR="${HOME}/x y"' '/h/x y'
cvis 'relative GG_WT_DIR kept as is' GG_WT_DIR 'GG_WT_DIR="../p-wt"' '../p-wt'
cvbad 'GG_WT_DIR with `…` after $HOME' GG_WT_DIR "GG_WT_DIR=\"\$HOME/\`touch $EV/u0\`\""
cvbad 'GG_WT_DIR with $(…)' GG_WT_DIR 'GG_WT_DIR="$(pwd)/x"'
cvis 'Automall: \$PORT in double quotes → $PORT' GG_DEV_CMD \
    'GG_DEV_CMD="cd frontend && { [ -d node_modules ] || npm ci --silent; } && exec npm run dev -- --port \$PORT --strictPort"' \
    'cd frontend && { [ -d node_modules ] || npm ci --silent; } && exec npm run dev -- --port $PORT --strictPort'
cvis "cloudcheff: single quotes are literal" GG_DEV_CMD "GG_DEV_CMD='npm run dev -- --port \$PORT'" 'npm run dev -- --port $PORT'
cvis 'escaped quote inside double quotes' GG_DEV_CMD 'GG_DEV_CMD="echo \"a b\" done"' 'echo "a b" done'
cvis 'escaped backslash; other \x kept' GG_DEV_CMD 'GG_DEV_CMD="a\\b \n c"' 'a\b \n c'
cvis 'a command substitution stays text' GG_DEV_CMD "GG_DEV_CMD=\"\\\$(touch $EV/u1)\"" "\$(touch $EV/u1)"
cvis 'unquoted value: comment cut, spaces trimmed' GG_DEV_PORT_BASE 'GG_DEV_PORT_BASE=3020   # dev port' '3020'
cvis 'the last line wins' GG_DEV_PORT_BASE "$(printf 'GG_DEV_PORT_BASE=3000\nGG_DEV_PORT_BASE=3010')" '3010'
cvis 'CRLF line endings' GG_DEV_PORT_BASE "$(printf 'GG_DEV_PORT_BASE=3000\r')" '3000'
cvis 'GG_DEV_PROC_MATCH with a space' GG_DEV_PROC_MATCH 'GG_DEV_PROC_MATCH="next dev"' 'next dev'
cvis 'empty value is a value' GG_BRANCH_PREFIX 'GG_BRANCH_PREFIX=""' ''
cvbad 'unterminated quote' GG_DEV_CMD 'GG_DEV_CMD="npm run dev'
cvbad 'GG_DEV_PORT_BASE=3e3' GG_DEV_PORT_BASE 'GG_DEV_PORT_BASE=3e3'
cvbad 'GG_DEV_PORT_ENV="A;B"' GG_DEV_PORT_ENV 'GG_DEV_PORT_ENV="A;B"'
cvbad 'GG_BRANCH_PREFIX="-x"' GG_BRANCH_PREFIX 'GG_BRANCH_PREFIX="-x"'
cvbad 'GG_PROTECTED with ..' GG_PROTECTED 'GG_PROTECTED="a..b"'
cvbad 'empty GG_PROTECTED' GG_PROTECTED 'GG_PROTECTED=""'
cvbad 'GG_FETCH_TIMEOUT=forever' GG_FETCH_TIMEOUT 'GG_FETCH_TIMEOUT=forever'
cvbad 'GG_RELEASE_GATE_SKIP with $(…)' GG_RELEASE_GATE_SKIP 'GG_RELEASE_GATE_SKIP="$(id)"'
cv GG_DEV_PORT_BASE 'XGG_DEV_PORT_BASE=1' >/dev/null; rc=$?
[ $rc -eq 1 ] && [ ! -s "$TMP/cv.err" ] && ok "parser: an absent key is silent (rc 1)" || bad "parser: absent key" "rc=$rc $(cat "$TMP/cv.err")"
ev_none && ok "parser: nothing was executed while parsing" || bad "parser executed something" "$(ev_list)"
# Code lines only (comments explain the rules and name the forbidden words)
cl_code() { grep -v '^[[:space:]]*#' "$CL" | grep -nE '(^|[^A-Za-z_])(eval|source)([^A-Za-z_]|$)|printf[^|]*%b|\bread +[^-]|\$\{!'; }
if [ -f "$CL" ] && ! cl_code >/dev/null; then
    ok "conf.sh has no eval / source / printf %b / read without -r / \${!var}"
else bad "conf.sh static check" "$(cl_code 2>&1)"; fi
# The hooks' parser (pre-push conf_raw) and the library agree on values without backslashes
eval "$(sed -n '/^conf_raw() {/,/^}/p' "$ROOT/githooks/pre-push")"
agree=1
for line in 'K="main"' "K='x y'" 'K=1 # c' 'K=""' 'K=plain' "$(printf 'K="crlf"\r')" 'K=  spaced  '; do
    a=$(printf '%s\n' "$line" | conf_raw K); b=$( ( . "$CL" 2>/dev/null; printf '%s\n' "$line" | gg_conf_raw K ) 2>/dev/null )
    [ "$a" = "$b" ] || { agree=0; bad "parser agrees with pre-push conf_raw on: $line" "[$a] vs [$b]"; }
done
[ $agree = 1 ] && ok "parser agrees with pre-push conf_raw on values without backslashes"
unset -f conf_raw

# A project with the kit committed and a HOSTILE policy on origin: the hostile
# lines must not run even though this text IS the trusted, parsed one.
CFO="$TMP/cf-origin.git"; git init -q --bare "$CFO"; git -C "$CFO" symbolic-ref HEAD refs/heads/main
CF="$TMP/cf"; mkrepo "$CF"; git -C "$CF" branch -M main
kit_copy "$CF"; cp "$ROOT/scripts/release-gate.sh" "$CF/scripts/"
cat > "$CF/.gitguards.conf" <<CONF
touch "$EV/o1"
GG_WT_DIR="\$HOME/cfwt"
GG_BRANCH_PREFIX="\$(touch "$EV/o2")"
GG_DEV_PROC_MATCH=\`touch "$EV/o3"\`
CONF
nh -C "$CF" add -A; nh -C "$CF" commit -qm kit
git -C "$CF" remote add origin "$CFO"; nh -C "$CF" push -q origin main 2>/dev/null; git -C "$CF" fetch -q origin
# …and the main working tree adds its own lines on top, uncommitted
cat >> "$CF/.gitguards.conf" <<CONF
touch "$EV/m1"
GG_WT_DIR="$TMP/cf-evil-wt"
GG_PROTECTED="wt/x"
GG_BRANCH_PREFIX="evil/"
CONF
ev_clear
out=$(HOME="$CFH" bash "$CF/scripts/wt-new.sh" cf1 2>&1); rc=$?
ev_none && ok "wt-new: nothing in the config runs (origin policy or uncommitted main-tree lines)" || bad "wt-new executed the config" "$(ev_list)"
[ $rc -eq 0 ] && [ -d "$CFH/cfwt/cf1" ] && git -C "$CF" rev-parse -q --verify refs/heads/wt/cf1 >/dev/null && [ ! -e "$TMP/cf-evil-wt" ] \
    && ok "wt-new: origin's GG_WT_DIR=\$HOME/… expanded; uncommitted main-tree values ignored" || bad "wt-new: values come from origin" "rc=$rc $out"
echo "$out" | grep -q 'ignoring invalid GG_BRANCH_PREFIX' && ok "wt-new: an invalid value is named out loud, default used" || bad "wt-new: invalid value warning" "$out"
ev_clear
out=$(HOME="$CFH" bash "$CF/scripts/wt-status.sh" --names 2>&1)
ev_none && ok "wt-status: nothing in the config runs" || bad "wt-status executed the config" "$(ev_list)"

CW="$CFH/cfwt/cf1"
# wt-new run FROM a worktree: that tree's own (uncommitted) config is not read either
cp "$CW/.gitguards.conf" "$TMP/cw-conf.bak"
printf 'touch "%s/b1"\nGG_WT_DIR="%s"\nGG_BRANCH_PREFIX="evil/"\n' "$EV" "$TMP/cf-evil-wt" >> "$CW/.gitguards.conf"
ev_clear
out=$( cd "$CW" && HOME="$CFH" bash scripts/wt-new.sh cf2 2>&1 ); rc=$?
ev_none && ok "wt-new run from a worktree: nothing in that tree's config runs" || bad "wt-new from a worktree executed its config" "$(ev_list)"
[ $rc -eq 0 ] && [ -d "$CFH/cfwt/cf2" ] && git -C "$CF" rev-parse -q --verify refs/heads/wt/cf2 >/dev/null && [ ! -e "$TMP/cf-evil-wt" ] \
    && ok "wt-new run from a worktree: values come from origin, not from the tree" || bad "wt-new from a worktree: values" "rc=$rc $out"
cp "$TMP/cw-conf.bak" "$CW/.gitguards.conf"
HOME="$CFH" bash "$CF/scripts/wt-done.sh" cf2 --force >/dev/null 2>&1
printf 'touch "%s/w1"\nGG_PROTECTED="wt/x"\nGG_RELEASE_GATE_SKIP="*"\n' "$EV" >> "$CW/.gitguards.conf"
echo code > "$CW/code.ts"; nh -C "$CW" add code.ts; nh -C "$CW" commit -qm code
ev_clear
out=$( cd "$CW" && HOME="$CFH" bash scripts/release-gate.sh scope 2>&1 ); rc=$?
ev_none && ok "release-gate: nothing in the branch's config runs" || bad "release-gate executed the config" "$(ev_list)"
[ $rc -eq 0 ] && echo "$out" | grep -q '(refs/remotes/origin/main)' && echo "$out" | grep -q 'files for review' \
    && ok "release-gate: base and SKIP come from origin/main, not from the branch's GG_PROTECTED/SKIP" || bad "release-gate: branch config moved the base" "rc=$rc $out"
nh -C "$CW" checkout -q -- .gitguards.conf
printf 'GG_PROTECTED="wt/cf1"\n' >> "$CF/.gitguards.conf"
ev_clear
out=$(HOME="$CFH" bash "$CF/scripts/wt-done.sh" cf1 2>&1); rc=$?
ev_none && ok "wt-done: nothing in the config runs" || bad "wt-done executed the config" "$(ev_list)"
[ $rc -ne 0 ] && [ -d "$CW" ] && git -C "$CF" rev-parse -q --verify refs/heads/wt/cf1 >/dev/null && echo "$out" | grep -q 'not on any remote' \
    && ok "wt-done: an uncommitted GG_PROTECTED does not unlock deleting unpushed work" || bad "wt-done: unpushed work" "rc=$rc $out"
out=$(HOME="$CFH" bash "$CF/scripts/wt-done.sh" cf1 --force 2>&1); rc=$?
[ $rc -eq 0 ] && [ ! -d "$CW" ] && ok "wt-done --force: removes the tree found by origin's GG_WT_DIR" || bad "wt-done --force" "rc=$rc $out"

# Bootstrap: origin has NO config yet → the main working tree's text is used — read, not run
CMO="$TMP/cm-origin.git"; git init -q --bare "$CMO"; git -C "$CMO" symbolic-ref HEAD refs/heads/main
CM="$TMP/cm"; mkrepo "$CM"; git -C "$CM" branch -M main; kit_copy "$CM"
nh -C "$CM" add -A; nh -C "$CM" commit -qm kit
git -C "$CM" remote add origin "$CMO"; nh -C "$CM" push -q origin main 2>/dev/null; git -C "$CM" fetch -q origin
printf 'touch "%s/t1"\nGG_BRANCH_PREFIX="mt/"\nGG_WT_DIR="%s"\n' "$EV" "$TMP/cm-wt" > "$CM/.gitguards.conf"
ev_clear
out=$(bash "$CM/scripts/wt-new.sh" m1 2>&1); rc=$?
ev_none && ok "bootstrap (no config on origin): the main-tree text is read, not run" || bad "bootstrap executed the config" "$(ev_list)"
[ $rc -eq 0 ] && git -C "$CM" rev-parse -q --verify refs/heads/mt/m1 >/dev/null && [ -d "$TMP/cm-wt/m1" ] \
    && ok "bootstrap: main-tree values apply while origin has no config" || bad "bootstrap values" "rc=$rc $out"
printf 'GG_BRANCH_PREFIX="unterminated\n' > "$CM/.gitguards.conf"
out=$(bash "$CM/scripts/wt-status.sh" 2>"$TMP/ws.err"); rc=$?
[ $rc -eq 0 ] && [ ! -s "$TMP/ws.err" ] && ok "wt-status: a broken config stays silent (SessionStart)" || bad "wt-status: broken config" "rc=$rc $(cat "$TMP/ws.err")"

# No origin: the committed config of the local main branch; uncommitted edits ignored
CN="$TMP/cn"; mkrepo "$CN"; git -C "$CN" branch -M main; kit_copy "$CN"
printf 'GG_BRANCH_PREFIX="lb/"\nGG_WT_DIR="$HOME/cn-wt"\n' > "$CN/.gitguards.conf"
nh -C "$CN" add -A; nh -C "$CN" commit -qm kit
printf 'touch "%s/n1"\nGG_BRANCH_PREFIX="evil/"\n' "$EV" >> "$CN/.gitguards.conf"
ev_clear
out=$(HOME="$CFH" bash "$CN/scripts/wt-new.sh" n1 2>&1); rc=$?
ev_none && ok "no origin: nothing in the config runs" || bad "no origin: executed the config" "$(ev_list)"
[ $rc -eq 0 ] && git -C "$CN" rev-parse -q --verify refs/heads/lb/n1 >/dev/null && ! git -C "$CN" rev-parse -q --verify refs/heads/evil/n1 >/dev/null \
    && ok "no origin: the committed config of local main applies, the uncommitted edit does not" || bad "no origin: source of values" "rc=$rc $out"
[ -d "$CFH/cn-wt/n1" ] && ok "no origin: GG_WT_DIR=\$HOME/… from the committed config of local main is expanded" || bad "no origin: \$HOME in GG_WT_DIR" "$out"

# origin added but never fetched, no committed config: GG_PROTECTED from the main-tree
# text may name the branch being deleted — wt-done refuses to delete the protected branch
CX="$TMP/cx"; mkrepo "$CX"; git -C "$CX" branch -M main; kit_copy "$CX"
nh -C "$CX" add -A; nh -C "$CX" commit -qm kit
git -C "$CX" remote add origin "$TMP/cx-nowhere.git"
git -C "$CX" worktree add -q "$TMP/cx-wt/x" -b wt/x
echo work > "$TMP/cx-wt/x/w.txt"; nh -C "$TMP/cx-wt/x" add w.txt; nh -C "$TMP/cx-wt/x" commit -qm work
printf 'GG_PROTECTED="wt/x"\n' > "$CX/.gitguards.conf"
out=$(bash "$CX/scripts/wt-done.sh" x 2>&1); rc=$?
[ $rc -ne 0 ] && [ -d "$TMP/cx-wt/x" ] && git -C "$CX" rev-parse -q --verify refs/heads/wt/x >/dev/null && echo "$out" | grep -q 'protected branch' \
    && ok "wt-done: the protected branch itself is never deleted" || bad "wt-done: protected branch" "rc=$rc $out"
out=$(bash "$CX/scripts/wt-done.sh" x --force 2>&1); rc=$?
[ $rc -ne 0 ] && [ -d "$TMP/cx-wt/x" ] && ok "wt-done --force: the protected branch is still not deleted" || bad "wt-done --force: protected branch" "rc=$rc $out"

# origin without refs yet: the first read is the local branch; wt-new fetches, reads again,
# and RECOMPUTES the tree directory from the fresh origin config
CRO="$TMP/cr-origin.git"; git init -q --bare "$CRO"; git -C "$CRO" symbolic-ref HEAD refs/heads/main
CR="$TMP/cr"; mkrepo "$CR"; git -C "$CR" branch -M main; kit_copy "$CR"
printf 'GG_WT_DIR="%s"\n' "$TMP/cr-old-wt" > "$CR/.gitguards.conf"
nh -C "$CR" add -A; nh -C "$CR" commit -qm kit
git -C "$CR" remote add origin "$CRO"; nh -C "$CR" push -q origin main 2>/dev/null
CRN="$TMP/crn"; git clone -q "$CRO" "$CRN" 2>/dev/null; git -C "$CRN" config user.email t@t; git -C "$CRN" config user.name t
printf 'GG_WT_DIR="%s"\n' "$TMP/cr-new-wt" > "$CRN/.gitguards.conf"; nh -C "$CRN" commit -qam "new wt dir"; nh -C "$CRN" push -q origin HEAD:main 2>/dev/null
git -C "$CR" update-ref -d refs/remotes/origin/main
out=$(bash "$CR/scripts/wt-new.sh" r1 2>&1); rc=$?
[ $rc -eq 0 ] && [ -d "$TMP/cr-new-wt/r1" ] && [ ! -e "$TMP/cr-old-wt/r1" ] \
    && ok "wt-new: after its own fetch, the fresh origin config decides the tree directory" || bad "wt-new: re-read after fetch" "rc=$rc $out"

# A tree whose kit lacks the library: a clear stop, wt-status silent
CK="$TMP/ck"; mkrepo "$CK"; git -C "$CK" branch -M main; kit_copy "$CK"; rm -f "$CK/scripts/git-guards/conf.sh"
out=$(bash "$CK/scripts/wt-new.sh" k1 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'conf.sh missing' && echo "$out" | grep -q 'merge-main' \
    && ok "wt-new without conf.sh: a clear stop that says how to restore the kit" || bad "wt-new without conf.sh" "rc=$rc $out"
out=$(bash "$CK/scripts/wt-status.sh" 2>"$TMP/ws.err"); rc=$?
[ $rc -eq 0 ] && [ ! -s "$TMP/ws.err" ] && ok "wt-status without conf.sh: silent, exit 0" || bad "wt-status without conf.sh" "rc=$rc $(cat "$TMP/ws.err")"
ev_none && ok "no evidence left by any run" || bad "evidence left" "$(ev_list)"

# ═════════════════════════════════════════════════════════════════════════════
# Empty policy values (vibe-flow 1.2.11): an empty value is not "invalid" — no false
# warning — and it still means the DEFAULT, never "off". An independent fixture:
# the PGR one restores itself by origin/main~1, an extra policy commit there breaks it.
# ═════════════════════════════════════════════════════════════════════════════
echo "== hooks: an empty policy value is silent and still means the default =="
EPO="$TMP/ep-origin.git"; git init -q --bare "$EPO"; git -C "$EPO" symbolic-ref HEAD refs/heads/main
EP="$TMP/ep"; git init -q "$EP"; git -C "$EP" symbolic-ref HEAD refs/heads/main
git -C "$EP" config user.email t@t; git -C "$EP" config user.name t
kit_copy "$EP"; cp "$ROOT/scripts/release-gate.sh" "$EP/scripts/"; echo a > "$EP/a.txt"
cat > "$EP/.gitguards.conf" <<'CONF'
GG_RELEASE_GATE=1
GG_RELEASE_GATE_SKIP=""
GG_DEV_READY_GLOBS=""
GG_PLAN_REQUIRED_TYPES=""
GG_PLAN_GATE_EXEMPT=""
CONF
nh -C "$EP" add -A; nh -C "$EP" commit -qm init
git -C "$EP" remote add origin "$EPO"; nh -C "$EP" push -q origin main 2>/dev/null; git -C "$EP" fetch -q origin
bash "$EP/scripts/install-git-guards.sh" >/dev/null 2>&1
git -C "$EP" checkout -q -b wt/ep-md
pg_mc "$EP" "[docs]: notes" notes.md n1 >/dev/null
out=$(pg_push "$EP" wt/ep-md); rc=$?
[ $rc -eq 0 ] && ! echo "$out" | grep -q 'ignoring invalid' \
    && ok "pre-push: empty values in origin's policy — no false 'ignoring invalid' warning" || bad "pre-push: empty values warn" "rc=$rc $out"
! echo "$out" | grep -q 'has not passed final review' && ok "pre-push: empty SKIP = default *.md — a docs-only push needs no review" || bad "pre-push: empty SKIP" "$out"
out=$( cd "$EP" && bash scripts/release-gate.sh scope 2>&1 ); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'no files need review' \
    && ok "release-gate: empty SKIP = default *.md, like pre-push" || bad "release-gate: empty SKIP" "rc=$rc $out"
pg_mc "$EP" "[fix]: code" a.txt a2 >/dev/null
out=$(pg_push "$EP" wt/ep-md); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'has not passed final review' \
    && ok "pre-push: empty SKIP — code without a verdict is still refused" || bad "pre-push: empty SKIP lets code through" "rc=$rc $out"
git -C "$EP" checkout -q -b wt/ep-feat origin/main
pg_mc "$EP" "[feat]: a documented feature" feat.md f1 >/dev/null
out=$(pg_push "$EP" wt/ep-feat); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "no 'Plan: <file>.md' line" && ! echo "$out" | grep -q 'ignoring invalid' \
    && ok "pre-push: empty GG_PLAN_REQUIRED_TYPES = default feat — [feat] without Plan: is refused, silently" || bad "pre-push: empty PLAN_REQUIRED_TYPES" "rc=$rc $out"
out=$( cd "$EP" && sh githooks/plan-gate.sh --get GG_PLAN_GATE_EXEMPT 2>&1 >/dev/null ); rc=$?
[ $rc -ne 0 ] && [ -z "$out" ] && ok "plan-gate.sh: an empty value is absent (rc 1) and silent" || bad "plan-gate.sh: empty value" "rc=$rc $out"
EN="$TMP/en"; mkrepo "$EN"; printf 'GG_PLAN_GATE_EXEMPT="nope"\n' > "$EN/.gitguards.conf"
out=$( cd "$EN" && sh "$ROOT/githooks/plan-gate.sh" --get GG_PLAN_GATE_EXEMPT 2>&1 >/dev/null )
echo "$out" | grep -q 'ignoring invalid GG_PLAN_GATE_EXEMPT' && ok "plan-gate.sh: a non-empty invalid value is still named out loud" || bad "plan-gate.sh: invalid value warning" "$out"
# " " = skip nothing: the documented way to review even *.md
git -C "$EP" checkout -q main
printf 'GG_RELEASE_GATE=1\nGG_RELEASE_GATE_SKIP=" "\n' > "$EP/.gitguards.conf"
nh -C "$EP" commit -qam "skip nothing"; nh -C "$EP" push -q origin main 2>/dev/null; git -C "$EP" fetch -q origin
git -C "$EP" checkout -q -b wt/ep-skip origin/main
pg_mc "$EP" "[docs]: more" more.md m1 >/dev/null
out=$( cd "$EP" && bash scripts/release-gate.sh scope 2>&1 ); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'files for review' && ok "release-gate: SKIP=\" \" — even a docs-only diff needs review" || bad "release-gate: SKIP space" "rc=$rc $out"
out=$(pg_push "$EP" wt/ep-skip); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'has not passed final review' && ok "pre-push: SKIP=\" \" — a docs-only push needs a verdict" || bad "pre-push: SKIP space" "rc=$rc $out"

# ═════════════════════════════════════════════════════════════════════════════
# Portability: GNU vs BSD tools, the guard in a subdirectory, native Windows.
# Linux, WSL and Git Bash ship GNU tools: `mktemp -t NAME` without X's fails
# ("too few X's") and `stat -f %m` prints filesystem info instead of an mtime.
# The shims reproduce that on any machine, so these cases are red/green on
# macOS too, not only in CI.
# ═════════════════════════════════════════════════════════════════════════════
echo "== portability: safe-commit and git-lock under GNU mktemp, without uuidgen =="
mkshim mktemp-gnu mktemp <<'EOF'
t=""
for a in "$@"; do
    case "$a" in
        -t) echo "mktemp: too few X's in template" >&2; exit 1 ;;
        -*) ;;
        *) t="$a" ;;
    esac
done
case "$t" in ""|*XXX*) exec @REAL_MKTEMP@ "$@" ;; esac
echo "mktemp: too few X's in template '$t'" >&2; exit 1
EOF
S_MKT="$TMP/shim-mktemp-gnu"
mkshim no-uuidgen uuidgen <<'EOF'
exit 127
EOF
S_NOUUID="$TMP/shim-no-uuidgen"
PT="$TMP/port-sc"; mkrepo "$PT"
echo v2 > "$PT/a.txt"; echo foreign > "$PT/b.txt"
out=$(PATH="$S_MKT:$PATH" commit "$PT" "edit a under GNU mktemp" a.txt); rc=$?
[ $rc -eq 0 ] && [ "$(git -C "$PT" show --name-only --format='' HEAD)" = "a.txt" ] && [ -z "$(git -C "$PT" status --porcelain a.txt)" ] \
    && ok "safe-commit under GNU mktemp (-t rejected) — commits exactly a.txt, index in sync" || bad "safe-commit under GNU mktemp" "$out"
[ -z "$(ls -A "$PT/.git" | grep '^index\.monitorex\.')" ] && ok "safe-commit: no temporary index left next to .git/index" || bad "temp index left" "$(ls -A "$PT/.git")"
echo v3 > "$PT/a.txt"
out=$(PATH="$S_NOUUID:$PATH" commit "$PT" "edit a without uuidgen" a.txt); rc=$?
[ $rc -eq 0 ] && git -C "$PT" log -1 --format='%(trailers:key=Session-Id)' | grep -q test \
    && ok "safe-commit without uuidgen (optional uuid-runtime on Debian/Ubuntu) — commits" || bad "safe-commit without uuidgen" "$out"

PLK="$TMP/port-lock"; mkrepo "$PLK"
echo v2 > "$PLK/a.txt"; git -C "$PLK" add a.txt          # the index no longer matches HEAD
mkdir -p "$PLK/.git/monitorex-locks"
printf 'phase=post-cas\nbranch=main\nold=%s\nnew=%s\n' "$(git -C "$PLK" rev-parse HEAD)" "$(git -C "$PLK" rev-parse HEAD)" > "$PLK/.git/monitorex-locks/journal"
out=$( cd "$PLK" && echo yes | PATH="$S_MKT:$PATH" bash "$GL" release 2>&1 ); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'index reset to' && git -C "$PLK" diff --cached --quiet && [ ! -f "$PLK/.git/monitorex-locks/journal" ] \
    && [ -z "$(ls -A "$PLK/.git" | grep '^index\.monitorex\.')" ] \
    && ok "git-lock release in post-cas under GNU mktemp — index repaired, no temp left" || bad "git-lock release repair" "$out"

echo "== portability: sha256 with only sha256sum or only shasum =="
mkshim no-sha256sum sha256sum <<'EOF'
exit 127
EOF
H_NOSHA="$TMP/shim-no-sha256sum"
mkshim no-shasum shasum <<'EOF'
exit 127
EOF
H_NOSHASUM="$TMP/shim-no-shasum"
ABC=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
if command -v shasum >/dev/null 2>&1; then
    [ "$(PATH="$H_NOSHA:$PATH" sha_of abc)" = "$ABC" ] && [ "$(PATH="$H_NOSHASUM:$PATH" sha_of abc)" = "$ABC" ] \
        && ok "sha_of: the same digest with only shasum or only sha256sum" || bad "sha_of fallback" "$(PATH="$H_NOSHASUM:$PATH" sha_of abc)"
else
    na "sha_of: the same digest with only shasum or only sha256sum" "no shasum"
fi
IGS="$TMP/port-igs"; mkrepo "$IGS"; kit_copy "$IGS"
( cd "$IGS" && PATH="$H_NOSHASUM:$PATH" bash scripts/install-git-guards.sh ) >/dev/null 2>&1
want=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$IGS/.git/monitorex-hooks/pre-push" 2>/dev/null)
[ -n "$want" ] && [ "$(cat "$IGS/.git/monitorex-hooks/pre-push.sha256" 2>/dev/null)" = "$want" ] \
    && ok "install-git-guards: hook digest written without shasum" || bad "install-git-guards digest without shasum" "want=$want got=$(cat "$IGS/.git/monitorex-hooks/pre-push.sha256" 2>/dev/null)"

echo "== portability: a bypass mark's age is fail-closed (stat empty / junk / GNU / BSD / future) =="
PY_MTIME='import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))'
mkshim stat-empty stat <<'EOF'
exit 1
EOF
S_EMPTY="$TMP/shim-stat-empty"
mkshim stat-junk stat <<'EOF'
echo "  File: \"$3\""; echo "    ID: 0        Namelen: 255     Type: ext2/ext3"; exit 0
EOF
S_JUNK="$TMP/shim-stat-junk"
mkshim stat-gnu stat <<EOF
if [ "\$1" = -c ] && [ "\$2" = %Y ]; then exec python3 -c '$PY_MTIME' "\$3"; fi
echo "  File: \"\$3\""; echo "stat: cannot read file system information for '%m'" >&2; exit 1
EOF
S_GNU="$TMP/shim-stat-gnu"
mkshim stat-bsd stat <<EOF
if [ "\$1" = -f ] && [ "\$2" = %m ]; then exec python3 -c '$PY_MTIME' "\$3"; fi
echo "stat: illegal option -- c" >&2; exit 1
EOF
S_BSD="$TMP/shim-stat-bsd"
FUTURE=209901010000   # touch -t: an mtime decades ahead (clock skew, restored backup)

# pre-commit: the one-off commit mark (CONFIRM target=commit)
pc_case() {   # label shim-dir(or "") touch-arg(or "") expect(honored|refused)
    local r="$TMP/port-pc-$1" f out got
    mkrepo "$r"; f="$r/.git/monitorex-locks/CONFIRM"; mkdir -p "${f%/*}"
    printf 'target=commit\nts=x\n' > "$f"; [ -n "$3" ] && touch -t "$3" "$f"
    out=$( cd "$r" && PATH="${2:+$2:}$PATH" sh "$HOOK" 2>&1 )
    if echo "$out" | grep -q 'forbidden'; then got=refused; else got=honored; fi
    if [ "$got" = "$4" ] && { { [ "$4" = honored ] && [ ! -f "$f" ]; } || { [ "$4" = refused ] && [ -f "$f" ]; }; }; then
        ok "pre-commit mark, $1 — $4$([ "$4" = refused ] && echo ', not consumed')"
    else bad "pre-commit mark, $1 — $4" "got $got, mark $([ -f "$f" ] && echo kept || echo consumed): $out"; fi
}
pc_case "stat prints nothing" "$S_EMPTY" "" refused
pc_case "stat prints junk" "$S_JUNK" "" refused
pc_case "GNU stat, fresh" "$S_GNU" "" honored
pc_case "BSD stat, fresh" "$S_BSD" "" honored
pc_case "GNU stat, expired" "$S_GNU" 202001010000 refused
pc_case "mtime in the future" "" "$FUTURE" refused

# pre-push: the delete-allow mark (deleting files from the protected branch)
PD="$TMP/port-pd"; mkrepo "$PD"
PDO="$TMP/port-pd.git"; git init -q --bare "$PDO"; git -C "$PDO" symbolic-ref HEAD refs/heads/main
git -C "$PD" remote add origin "$PDO"; git -C "$PD" push -q origin main 2>/dev/null; git -C "$PD" fetch -q origin
mkdir -p "$PD/.git/monitorex-hooks" "$PD/.git/monitorex-locks"
cp "$PP" "$PD/.git/monitorex-hooks/pre-push"; git -C "$PD" config core.hooksPath "$PD/.git/monitorex-hooks"
PDR=$(git -C "$PD" rev-parse origin/main)
git -C "$PD" rm -q b.txt; printf 'remove b\n\nSession-Id: port-sess\n' > "$TMP/port-pd-msg"
git -C "$PD" commit -q -F "$TMP/port-pd-msg"; PDS=$(git -C "$PD" rev-parse HEAD)
PDM="$PD/.git/monitorex-locks/delete-allow"
pd_case() {   # label shim-dir(or "") touch-arg(or "") expect(honored|refused)
    local out got
    printf 'b.txt\n' > "$PDM"; [ -n "$3" ] && touch -t "$3" "$PDM"
    out=$( cd "$PD" && printf '%s\n' "refs/heads/main $PDS refs/heads/main $PDR" \
        | PATH="${2:+$2:}$PATH" CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=port-sess sh "$PD/.git/monitorex-hooks/pre-push" origin "$PDO" 2>&1 )
    if echo "$out" | grep -q 'Deletion confirmed by a mark'; then got=honored
    elif echo "$out" | grep -q 'DELETES files'; then got=refused; else got=error; fi
    if [ "$got" = "$4" ] && { { [ "$4" = honored ] && [ ! -f "$PDM" ]; } || { [ "$4" = refused ] && [ -f "$PDM" ]; }; }; then
        ok "pre-push delete-allow mark, $1 — $4$([ "$4" = refused ] && echo ', not consumed')"
    else bad "pre-push delete-allow mark, $1 — $4" "got $got, mark $([ -f "$PDM" ] && echo kept || echo consumed): $out"; fi
    rm -f "$PDM"
}
pd_case "real stat, fresh" "" "" honored
pd_case "stat prints nothing" "$S_EMPTY" "" refused
pd_case "stat prints junk" "$S_JUNK" "" refused
pd_case "GNU stat, fresh" "$S_GNU" "" honored
pd_case "GNU stat, expired" "$S_GNU" 202001010000 refused
pd_case "mtime in the future" "" "$FUTURE" refused

# plan-gate.sh: the human feat mark (CONFIRM target=feat), early mode
PGTC="$PGT/.git/monitorex-locks/CONFIRM"; mkdir -p "${PGTC%/*}"
pg_case() {   # label shim-dir(or "") touch-arg(or "") expect(honored|refused)
    local rc got
    printf 'target=feat\n' > "$PGTC"; [ -n "$3" ] && touch -t "$3" "$PGTC"
    PATH="${2:+$2:}$PATH" pgt '[feat]: x'; rc=$?
    if [ $rc -eq 0 ]; then got=honored; else got=refused; fi
    [ "$got" = "$4" ] && ok "plan-gate feat mark, $1 — $4" || bad "plan-gate feat mark, $1 — $4" "rc=$rc"
    rm -f "$PGTC"
}
pg_case "real stat, fresh" "" "" honored
pg_case "stat prints nothing" "$S_EMPTY" "" refused
pg_case "stat prints junk" "$S_JUNK" "" refused
pg_case "GNU stat, fresh" "$S_GNU" "" honored
pg_case "BSD stat, fresh" "$S_BSD" "" honored
pg_case "BSD stat, expired" "$S_BSD" 202001010000 refused
pg_case "mtime in the future" "" "$FUTURE" refused

# Display-only sites: no arithmetic error, the age is shown as unknown
GCF="$TMP/port-gc"; mkrepo "$GCF"; GCM="$GCF/.git/monitorex-locks/CONFIRM"; mkdir -p "${GCM%/*}"; printf 'target=feat\n' > "$GCM"
out=$( cd "$GCF" && PATH="$S_JUNK:$PATH" bash "$ROOT/scripts/git-confirm.sh" status 2>&1 ); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'unknown' && echo "$out" | grep -q 'treated as absent' \
    && ok "git-confirm.sh status: unreadable age — 'unknown, treated as absent'" || bad "git-confirm status junk stat" "rc=$rc $out"
out=$( cd "$GCF" && PATH="$S_GNU:$PATH" bash "$ROOT/scripts/git-confirm.sh" status 2>&1 ); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q '^mark: ' && ok "git-confirm.sh status under GNU stat — fresh mark shown" || bad "git-confirm status GNU" "rc=$rc $out"
GDM="$GCF/.git/monitorex-locks/delete-allow"; printf 'b.txt\n' > "$GDM"
out=$( cd "$GCF" && PATH="$S_JUNK:$PATH" bash "$ROOT/scripts/git-allow-delete.sh" list 2>&1 ); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'treated as absent' && ok "git-allow-delete.sh list: unreadable age — treated as absent" || bad "git-allow-delete list junk stat" "rc=$rc $out"
mkdir -p "$GCF/.git/monitorex-locks/commit"; printf 'actor=x\npurpose=take\nworktree=/w\n' > "$GCF/.git/monitorex-locks/commit/owner"
out=$( cd "$GCF" && PATH="$S_JUNK:$PATH" bash "$GL" status 2>&1 ); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'age ?' && ok "git-lock.sh status: unreadable age — shown as '?'" || bad "git-lock status junk stat" "rc=$rc $out"
rm -rf "$GCF/.git/monitorex-locks/commit"

echo "== portability: the guard in a subdirectory of the main tree =="
# --git-dir comes back absolute and --git-common-dir relative (../../.git) in a
# subdirectory: comparing the raw strings took the main tree for a linked worktree.
GSD="$TMP/port-gsd"; mkrepo "$GSD"; mkdir -p "$GSD/sub/deep"
git -C "$GSD" worktree add -q "$TMP/port-gsd-wt" -b wt/gsd >/dev/null 2>&1; mkdir -p "$TMP/port-gsd-wt/sub"
gcase "git add from a subdirectory of the main tree" deny "$GSD" Bash command "git add a.txt" "$GSD/sub/deep"
gcase "cd sub/deep && git add in the main tree" deny "$GSD" Bash command "cd sub/deep && git add a.txt" "$GSD"
gcase "git -C <main>/sub/deep add" deny "$GSD" Bash command "git -C $GSD/sub/deep add a.txt" "$OUTSIDE"
gcase "git add from a subdirectory of a linked worktree" allow "$GSD" Bash command "git add a.txt" "$TMP/port-gsd-wt/sub"
gcase "git add at the root of a linked worktree" allow "$GSD" Bash command "git add a.txt" "$TMP/port-gsd-wt"

guard_wrapper_cases

if [ -n "$KIT" ]; then
    echo "== portability: Git Bash supported, MSYS/Cygwin stop, a failed detect (installer) =="
    # vibe-flow 1.3.0: native Windows through Git for Windows (uname MINGW*) is
    # supported; MSYS2/Cygwin shells bring their own POSIX Python and path rules and
    # are not tested, so they stop — whatever GG_ALLOW_UNSUPPORTED_OS says (removed).
    FW="$TMP/fakekit-win"; fake_kit "$FW"
    untouched() { [ -z "$(git -C "$1" status --porcelain)" ] && [ ! -e "$1/.gitguards.conf" ] && [ ! -e "$1/scripts" ] && [ ! -e "$1/githooks" ] && [ ! -e "$1/CLAUDE.md" ]; }
    STOP_MSG='use Git for Windows (Git Bash) or WSL 2'
    for u in MINGW64_NT-10.0-26200 MSYS_NT-10.0-26200 CYGWIN_NT-10.0-26200; do
        k=${u%%_*}
        mkshim "uname-$k" uname <<EOF
echo $u
EOF
    done
    FP="$TMP/fakeplugin"; mkdir -p "$FP"
    cp -R "$KIT/../scripts" "$KIT/../templates" "$KIT/../.claude-plugin" "$FP/"; cp -R "$FW" "$FP/git-guards"
    NG="$TMP/port-notgit"; mkdir -p "$NG"
    for k in MSYS CYGWIN; do
        US="$TMP/shim-uname-$k"
        WR="$TMP/port-win-$k"; mkrepo "$WR"
        out=$(env -u GG_ALLOW_UNSUPPORTED_OS -u GITHUB_ACTIONS PATH="$US:$PATH" GG_EMBEDDED=1 bash "$FW/install.sh" "$WR" 2>&1); rc=$?
        [ $rc -ne 0 ] && echo "$out" | grep -qF "$STOP_MSG" && untouched "$WR" \
            && ok "install.sh on $k — stops ('$STOP_MSG'), repository untouched" || bad "install.sh on $k" "rc=$rc $out"
        out=$(GITHUB_ACTIONS=true GG_ALLOW_UNSUPPORTED_OS=1 PATH="$US:$PATH" GG_EMBEDDED=1 bash "$FW/install.sh" "$WR" 2>&1); rc=$?
        [ $rc -ne 0 ] && echo "$out" | grep -qF "$STOP_MSG" && untouched "$WR" \
            && ok "install.sh on $k with GG_ALLOW_UNSUPPORTED_OS=1 inside CI — still stops (the variable is gone)" || bad "install.sh on $k, old override" "rc=$rc $out"
        WI="$TMP/port-win-init-$k"; mkrepo "$WI"
        out=$(env -u GG_ALLOW_UNSUPPORTED_OS -u GITHUB_ACTIONS PATH="$US:$PATH" bash "$FP/scripts/init.sh" "$WI" 2>&1); rc=$?
        [ $rc -ne 0 ] && echo "$out" | grep -qF "$STOP_MSG" && untouched "$WI" \
            && ok "init.sh on $k — stops before any write" || bad "init.sh on $k" "rc=$rc $out"
        out=$(GITHUB_ACTIONS=true GG_ALLOW_UNSUPPORTED_OS=1 PATH="$US:$PATH" bash "$FP/scripts/init.sh" "$NG" 2>&1); rc=$?
        [ $rc -ne 0 ] && echo "$out" | grep -qF "$STOP_MSG" \
            && ok "init.sh on $k with GG_ALLOW_UNSUPPORTED_OS=1 inside CI — still stops" || bad "init.sh on $k, old override" "rc=$rc $out"
    done
    US="$TMP/shim-uname-MINGW64"
    WR="$TMP/port-win-MINGW64"; mkrepo "$WR"
    out=$(env -u GG_ALLOW_UNSUPPORTED_OS -u GITHUB_ACTIONS PATH="$US:$PATH" GG_EMBEDDED=1 bash "$FW/install.sh" "$WR" 2>&1); rc=$?
    [ $rc -eq 0 ] && ! echo "$out" | grep -q 'WSL 2' && grep -q '^GG_PROTECTED=' "$WR/.gitguards.conf" 2>/dev/null \
        && ok "install.sh on MINGW64 (Git Bash) — no stop, the kit is installed" || bad "install.sh on MINGW64" "rc=$rc $out"
    WI="$TMP/port-win-init-MINGW64"; mkrepo "$WI"
    out=$(env -u GG_ALLOW_UNSUPPORTED_OS -u GITHUB_ACTIONS PATH="$US:$PATH" bash "$FP/scripts/init.sh" "$WI" 2>&1); rc=$?
    [ $rc -eq 0 ] && ! echo "$out" | grep -q 'WSL 2' && [ -f "$WI/.gitguards.conf" ] && grep -q 'vibe-flow:begin' "$WI/CLAUDE.md" 2>/dev/null \
        && ok "init.sh on MINGW64 (Git Bash) — no stop, deployed" || bad "init.sh on MINGW64" "rc=$rc $out"

    FD="$TMP/fakekit-baddetect"; cp -R "$FW" "$FD"
    printf 'import sys\nprint("GG_PARTIAL=1")\nsys.exit(1)\n' > "$FD/detect.py"
    DR="$TMP/port-detect"; mkrepo "$DR"
    out=$(GG_EMBEDDED=1 bash "$FD/install.sh" "$DR" 2>&1); rc=$?
    [ $rc -ne 0 ] && [ ! -e "$DR/.gitguards.conf" ] && ok "install.sh: detect fails — no half-written .gitguards.conf left" || bad "failed detect" "rc=$rc $(ls -A "$DR")"
    out=$(GG_EMBEDDED=1 bash "$FW/install.sh" "$DR" 2>&1); rc=$?
    [ $rc -eq 0 ] && grep -q '^GG_PROTECTED=' "$DR/.gitguards.conf" && ! grep -q GG_PARTIAL "$DR/.gitguards.conf" \
        && ok "install.sh rerun after a failed detect — config written" || bad "rerun after failed detect" "rc=$rc $out"

    [ "$(git -C "$KIT" check-attr eol -- files/scripts/wt-new.sh | sed 's/.*: //')" = lf ] \
        && ok ".gitattributes: scripts check out with LF on any core.autocrlf" || bad ".gitattributes eol" "$(git -C "$KIT" check-attr eol -- files/scripts/wt-new.sh)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# vibe-flow 1.3.0 — native Windows (Git Bash) and the holes found on the way.
# Every case below runs on macOS and Linux too, except the block marked
# "native Windows only". The contracts K1–K14 are in the 1.3.0 plan.
# ═════════════════════════════════════════════════════════════════════════════
echo "== policy from origin: absent → tree text, unreadable → refuse (K8, Codex C1), git replace ignored =="
# A read ERROR is not "absent": the built-in defaults switch the release gate, the
# plan gate and the typecheck off, and the tree copy is whatever the branch wants.
pp_direct() {   # $1 repo, $2 origin, $3 branch, $4 sha, [$5 PATH prefix] → pre-push run directly
    # (not via `git push`: git puts its exec-path first on PATH, past any shim)
    ( cd "$1" && printf 'refs/heads/%s %s refs/heads/%s 0000000000000000000000000000000000000000\n' "$3" "$4" "$3" \
        | env PATH="${5:+$5:}$PATH" MONITOREX_ACTOR=tst CLAUDE_CODE_SESSION_ID= sh "$1/.git/monitorex-hooks/pre-push" origin "$2" 2>&1 )
}
K8O="$TMP/k8-origin.git"; git init -q --bare "$K8O"; git -C "$K8O" symbolic-ref HEAD refs/heads/main
K8="$TMP/k8"; git init -q "$K8"; git -C "$K8" symbolic-ref HEAD refs/heads/main
git -C "$K8" config user.email t@t; git -C "$K8" config user.name t
kit_copy "$K8"; cp "$ROOT/scripts/release-gate.sh" "$K8/scripts/"; echo a > "$K8/a.txt"
printf 'GG_PROTECTED="main"\nGG_RELEASE_GATE=1\nGG_PLAN_REQUIRED_TYPES="feat"\nGG_PLAN_GATE="githooks/plan-gate.sh"\n' > "$K8/.gitguards.conf"
nh -C "$K8" add -A; nh -C "$K8" commit -qm init
git -C "$K8" remote add origin "$K8O"; nh -C "$K8" push -q origin main 2>/dev/null; git -C "$K8" fetch -q origin
bash "$K8/scripts/install-git-guards.sh" >/dev/null 2>&1
# The main tree's own copy, weakened and uncommitted: only origin's text may count.
printf 'GG_RELEASE_GATE=0\nGG_PLAN_REQUIRED_TYPES="none"\n' > "$K8/.gitguards.conf"
mkshim policy-unreadable git <<'EOF'
# Every read of .gitguards.conf out of git fails — today's `git show <ref>:.gitguards.conf`
# and the 1.3.0 ls-tree / cat-file path alike; anything else goes to the real git.
for a in "$@"; do
    case "$a" in *.gitguards.conf*)
        for b in "$@"; do case "$b" in show|ls-tree|cat-file) echo "fatal: injected read failure" >&2; exit 128 ;; esac; done ;;
    esac
done
exec "@REAL_GIT@" "$@"
EOF
S_NOPOL="$TMP/shim-policy-unreadable"
git -C "$K8" checkout -q -b wt/k8f origin/main
K8F=$(pg_mc "$K8" "[feat]: unplanned" a.txt f1)
git -C "$K8" checkout -q -b wt/k8x origin/main
K8X=$(pg_mc "$K8" "[fix]: code" a.txt x1)
# pre-push checks the commit it pushes against the working tree: push what is checked out
k8_on() { git -C "$K8" checkout -q "$1"; }
k8_on wt/k8f; out=$(pp_direct "$K8" "$K8O" wt/k8f "$K8F"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'plan gate' && ok "K8 fixture: origin's policy refuses an unapproved [feat] (control)" || bad "K8 fixture: [feat] control" "rc=$rc $out"
k8_on wt/k8x; out=$(pp_direct "$K8" "$K8O" wt/k8x "$K8X"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'has not passed final review' && ok "K8 fixture: origin's policy refuses code without a verdict (control)" || bad "K8 fixture: verdict control" "rc=$rc $out"
k8_on wt/k8f; out=$(pp_direct "$K8" "$K8O" wt/k8f "$K8F" "$S_NOPOL"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'unreadable' \
    && ok "pre-push: origin's policy unreadable — an unapproved [feat] is still refused, out loud (Codex C1)" || bad "pre-push: unreadable policy, [feat]" "rc=$rc $out"
k8_on wt/k8x; out=$(pp_direct "$K8" "$K8O" wt/k8x "$K8X" "$S_NOPOL"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'unreadable' \
    && ok "pre-push: origin's policy unreadable — code without a verdict is still refused (Codex C1)" || bad "pre-push: unreadable policy, no verdict" "rc=$rc $out"
printf '[feat]: early\n' > "$TMP/k8-msg"
out=$( cd "$K8" && env PATH="$S_NOPOL:$PATH" sh githooks/plan-gate.sh "$TMP/k8-msg" a.txt 2>&1 ); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'unreadable' \
    && ok "plan-gate.sh: policy unreadable — refuses (not the tree's GG_PLAN_REQUIRED_TYPES=none)" || bad "plan-gate.sh: unreadable policy" "rc=$rc $out"
out=$( cd "$K8" && env PATH="$S_NOPOL:$PATH" bash scripts/release-gate.sh scope 2>&1 ); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'unreadable' && ok "release-gate.sh scope: policy unreadable — stops" || bad "release-gate.sh: unreadable policy" "rc=$rc $out"
out=$( cd "$K8" && env PATH="$S_NOPOL:$PATH" bash scripts/wt-new.sh k8wt 2>&1 ); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'unreadable' && [ ! -d "$TMP/k8-wt/k8wt" ] \
    && ok "wt-new: policy unreadable — stops, no tree from the tree's or the default values" || bad "wt-new: unreadable policy" "rc=$rc $out"
K8H=$(git -C "$K8" rev-parse HEAD); echo s1 > "$K8/a.txt"
out=$( cd "$K8" && env PATH="$S_NOPOL:$PATH" MONITOREX_ACTOR=tst CLAUDE_CODE_SESSION_ID= MONITOREX_SKIP_TESTS=1 \
       bash scripts/git-safe-commit.sh --message-file "$TMP/k8-msg" -- a.txt 2>&1 ); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'unreadable' && [ "$(git -C "$K8" rev-parse HEAD)" = "$K8H" ] \
    && ok "safe-commit: policy unreadable — the gate part refuses, no commit" || bad "safe-commit: unreadable policy" "rc=$rc $out"
nh -C "$K8" reset -q --hard "$K8H"
printf 'GG_RELEASE_GATE=0\nGG_PLAN_REQUIRED_TYPES="none"\n' > "$K8/.gitguards.conf"
# git replace swaps what `git show` returns; the policy reader must not follow it
K8B=$(git -C "$K8" ls-tree origin/main -- .gitguards.conf | awk '{print $3}')
K8W=$(printf 'GG_RELEASE_GATE=0\n' | git -C "$K8" hash-object -w --stdin)
git -C "$K8" replace "$K8B" "$K8W" 2>/dev/null
out=$(pp_direct "$K8" "$K8O" wt/k8x "$K8X"); rc=$?
[ -n "$K8B" ] && [ $rc -ne 0 ] && echo "$out" | grep -q 'has not passed final review' \
    && ok "pre-push: a 'git replace' of origin's policy blob is ignored (the real policy applies)" || bad "pre-push: git replace of the policy" "rc=$rc $out"
git -C "$K8" replace -d "$K8B" >/dev/null 2>&1
# Bootstrap: origin has no policy yet (gg_blob "absent") → the main tree's text applies
K8AO="$TMP/k8a-origin.git"; git init -q --bare "$K8AO"; git -C "$K8AO" symbolic-ref HEAD refs/heads/main
K8A="$TMP/k8a"; git init -q "$K8A"; git -C "$K8A" symbolic-ref HEAD refs/heads/main
git -C "$K8A" config user.email t@t; git -C "$K8A" config user.name t
kit_copy "$K8A"; echo a > "$K8A/a.txt"; nh -C "$K8A" add -A; nh -C "$K8A" commit -qm init
git -C "$K8A" remote add origin "$K8AO"; nh -C "$K8A" push -q origin main 2>/dev/null; git -C "$K8A" fetch -q origin
bash "$K8A/scripts/install-git-guards.sh" >/dev/null 2>&1
printf 'GG_RELEASE_GATE=1\n' > "$K8A/.gitguards.conf"
git -C "$K8A" checkout -q -b wt/k8a origin/main
K8AX=$(pg_mc "$K8A" "[fix]: code" a.txt y1)
out=$(pp_direct "$K8A" "$K8AO" wt/k8a "$K8AX"); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'has not passed final review' \
    && ok "pre-push: no policy on origin yet (absent) — the main tree's text applies" || bad "pre-push: absent policy fallback" "rc=$rc $out"

echo "== safe-commit: a new kit script keeps its exec bit without core.filemode (K11) =="
# A kit committed from Windows (core.filemode=false) must still run on Linux/macOS clones.
XB="$TMP/xbit"; mkrepo "$XB"; git -C "$XB" config core.filemode false
mkdir -p "$XB/scripts/git-guards" "$XB/githooks" "$XB/.claude/hooks" "$XB/lib"
printf '#!/bin/sh\necho old\n' > "$XB/scripts/old.sh"; git -C "$XB" add scripts/old.sh; git -C "$XB" commit -qm old
printf '#!/bin/sh\necho v2\n' > "$XB/scripts/old.sh"
for f in scripts/new.sh scripts/git-guards/helper.sh githooks/new-hook .claude/hooks/new-hook.sh lib/tool.sh; do
    printf '#!/bin/sh\necho x\n' > "$XB/$f"
done
printf 'echo no shebang\n' > "$XB/scripts/plain.sh"
chmod 644 "$XB/scripts/old.sh" "$XB/scripts/new.sh" "$XB/scripts/plain.sh" "$XB/scripts/git-guards/helper.sh" \
    "$XB/githooks/new-hook" "$XB/.claude/hooks/new-hook.sh" "$XB/lib/tool.sh"
out=$(commit "$XB" "kit files" scripts githooks .claude lib); rc=$?
xmode() { git -C "$XB" ls-tree HEAD -- "$1" | cut -d' ' -f1; }
[ $rc -eq 0 ] && [ "$(xmode scripts/new.sh)" = 100755 ] && [ "$(xmode scripts/git-guards/helper.sh)" = 100755 ] \
    && [ "$(xmode githooks/new-hook)" = 100755 ] && [ "$(xmode .claude/hooks/new-hook.sh)" = 100755 ] \
    && ok "safe-commit: NEW kit files starting with #! are committed 100755 under core.filemode=false" \
    || bad "safe-commit: exec bit of new kit files" "rc=$rc new.sh=$(xmode scripts/new.sh) helper=$(xmode scripts/git-guards/helper.sh) hook=$(xmode githooks/new-hook) claude=$(xmode .claude/hooks/new-hook.sh) $out"
[ "$(xmode scripts/old.sh)" = 100644 ] && ok "safe-commit: an existing kit file keeps HEAD's mode (100644)" || bad "safe-commit: existing file mode" "$(xmode scripts/old.sh)"
[ "$(xmode lib/tool.sh)" = 100644 ] && [ "$(xmode scripts/plain.sh)" = 100644 ] \
    && ok "safe-commit: a script outside the kit paths, a kit file without #! — 100644" || bad "safe-commit: non-kit modes" "tool=$(xmode lib/tool.sh) plain=$(xmode scripts/plain.sh)"

if [ -n "$KIT" ]; then
    echo "== attributes.py: the kit's eol=lf block in the target's .gitattributes (K10) =="
    # Without it, worktrees on Windows check out CRLF scripts and bash fails on $'\r'.
    ga_block() {
        printf '%s\n' '# vibe-flow:git-guards:begin (managed by vibe-flow, do not edit inside)' \
            'scripts/*.sh text eol=lf' 'scripts/git-guards/** text eol=lf' 'githooks/** text eol=lf' \
            '.claude/hooks/** text eol=lf' '.gitguards.conf text eol=lf' '# vibe-flow:git-guards:end'
    }
    ga_run() { "$PYBIN" "$KIT/attributes.py" "$1" 2>&1; }
    GA1="$TMP/ga1"; mkdir -p "$GA1"; ga_block > "$TMP/ga1.want"
    out=$(ga_run "$GA1"); rc=$?
    [ $rc -eq 0 ] && cmp -s "$GA1/.gitattributes" "$TMP/ga1.want" \
        && ok "attributes.py: no .gitattributes — created with exactly the block (LF)" || bad "attributes.py: created" "rc=$rc $out"
    GA2="$TMP/ga2"; mkdir -p "$GA2"; printf '*.png binary' > "$GA2/.gitattributes"
    { printf '*.png binary\n'; ga_block; } > "$TMP/ga2.want"
    out=$(ga_run "$GA2"); rc=$?
    [ $rc -eq 0 ] && cmp -s "$GA2/.gitattributes" "$TMP/ga2.want" \
        && ok "attributes.py: a file without a final newline — newline first, block appended, own line kept" || bad "attributes.py: appended" "rc=$rc $out"
    GA3="$TMP/ga3"; mkdir -p "$GA3"
    printf '*.jpg binary\r\n# vibe-flow:git-guards:begin (managed by vibe-flow, do not edit inside)\nold line\n# vibe-flow:git-guards:end\n*.pdf binary\n' > "$GA3/.gitattributes"
    { printf '*.jpg binary\r\n'; ga_block; printf '*.pdf binary\n'; } > "$TMP/ga3.want"
    out=$(ga_run "$GA3"); rc=$?
    [ $rc -eq 0 ] && cmp -s "$GA3/.gitattributes" "$TMP/ga3.want" \
        && ok "attributes.py: an old block replaced in place, lines outside byte-identical (a CRLF one too)" || bad "attributes.py: replaced" "rc=$rc $out"
    cp "$GA3/.gitattributes" "$TMP/ga3.before"; out=$(ga_run "$GA3"); rc=$?
    [ $rc -eq 0 ] && cmp -s "$GA3/.gitattributes" "$TMP/ga3.before" \
        && ok "attributes.py: a rerun leaves the file byte-identical" || bad "attributes.py: idempotent" "rc=$rc $out"

    echo "== selftest.sh: the guard really blocks on this machine (K9) =="
    # Fail-open stays (the user's decision), silence goes: an install whose guard
    # cannot deny must say so instead of claiming success.
    st_setup() { mkrepo "$1"; kit_copy "$1"; "$PYBIN" "$KIT/settings-merge.py" "$1" >/dev/null 2>&1; }
    st_run() { bash "$KIT/selftest.sh" "$1" 2>&1; }
    ST_OK='✅ guard self-test passed: the guard blocks on this machine'
    ST_BAD='🔴 the guard does not block on this machine'
    ST="$TMP/st"; st_setup "$ST"; nh -C "$ST" add -A; nh -C "$ST" commit -qm kit
    out=$(st_run "$ST"); rc=$?
    [ $rc -eq 0 ] && echo "$out" | grep -qF "$ST_OK" && ok "selftest: a healthy install — passes" || bad "selftest: healthy" "rc=$rc $out"
    git -C "$ST" worktree add -q "$TMP/st-wt" -b wt/st >/dev/null 2>&1
    out=$(st_run "$TMP/st-wt"); rc=$?
    [ $rc -eq 0 ] && echo "$out" | grep -qF "$ST_OK" \
        && ok "selftest: run from a linked worktree — still judged in the main tree, passes" || bad "selftest: from a worktree" "rc=$rc $out"
    # The rollout tests its prepared worktree: the guard under test is THAT tree's,
    # not the healthy one installed in the main tree (code review M2).
    cp "$TMP/st-wt/.claude/hooks/monitorex-git-guard.sh" "$TMP/st-wt-guard.bak"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/st-wt/.claude/hooks/monitorex-git-guard.sh"
    out=$(st_run "$TMP/st-wt"); rc=$?
    [ $rc -eq 1 ] && echo "$out" | grep -qF "$ST_BAD" \
        && ok "selftest: an inert guard in the tested worktree fails even though the main tree's guard is healthy" \
        || bad "selftest: worktree guard under test" "rc=$rc $out"
    cp "$TMP/st-wt-guard.bak" "$TMP/st-wt/.claude/hooks/monitorex-git-guard.sh"
    S86="$TMP/st-py86"; mkdir -p "$S86"
    for n in python3 python py; do printf '#!/bin/sh\nexit 86\n' > "$S86/$n"; chmod +x "$S86/$n"; done
    out=$(PATH="$S86:$PATH" st_run "$ST"); rc=$?
    [ $rc -eq 1 ] && echo "$out" | grep -qF "$ST_BAD" && ok "selftest: only too-old interpreters on PATH — fails loudly" || bad "selftest: too-old interpreter" "rc=$rc $out"
    ST2="$TMP/st-inert"; st_setup "$ST2"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$ST2/.claude/hooks/monitorex-git-guard.sh"
    out=$(st_run "$ST2"); rc=$?
    [ $rc -eq 1 ] && echo "$out" | grep -qF "$ST_BAD" && ok "selftest: an inert guard (wrapper exits 0) — fails loudly" || bad "selftest: inert guard" "rc=$rc $out"
    ST3="$TMP/st-noreg"; mkrepo "$ST3"; kit_copy "$ST3"
    out=$(st_run "$ST3"); rc=$?
    [ $rc -eq 1 ] && echo "$out" | grep -qF "$ST_BAD" && ok "selftest: no registration in .claude/settings.json — fails" || bad "selftest: no registration" "rc=$rc $out"
    ST4="$TMP/st-bashonly"; mkrepo "$ST4"; kit_copy "$ST4"; mkdir -p "$ST4/.claude"
    printf '{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash \\"$CLAUDE_PROJECT_DIR/.claude/hooks/monitorex-git-guard.sh\\""}]}]}}\n' > "$ST4/.claude/settings.json"
    out=$(st_run "$ST4"); rc=$?
    [ $rc -eq 1 ] && echo "$out" | grep -qF "$ST_BAD" && ok "selftest: registered for Bash only, not for Write|Edit — fails" || bad "selftest: Bash-only registration" "rc=$rc $out"
fi

echo "== inlined helpers: every copy is byte-identical to its source (drift) =="
# Git hooks and the Claude hook wrappers run standalone (or as copies from the
# protected branch) and cannot source pyenv.sh / paths.sh: they carry the marked
# block inline. (The marker is assembled from pieces so this file never matches.)
gi_block() {   # $1 = file, $2 = block name → the block, marker lines included; rc 1 unless exactly one
    awk -v s="# >>> gg""-inline:$2 >>>" -v e="# <<< gg""-inline:$2 <<<" '
        { l = $0; sub(/\r$/, "", l); t = l; sub(/^[ \t]+/, "", t) }
        t == s { if (on) broken = 1; on = 1; n++ }
        on { print }
        t == e { if (!on) broken = 1; on = 0; m++ }
        END { exit (n == 1 && m == 1 && !broken && !on) ? 0 : 1 }' "$1"
}
# One path per line, never word-split: projects live in folders like
# "Vibe-coding school" (1.3.0 split them and reported every copy as drifted).
gi_required() {   # $1 = block, $2 = root, $3 = hooks dir → the copies that MUST carry it
    case "$1" in
        pyenv) printf '%s\n' "$3/monitorex-git-guard.sh" "$3/plan-approved.sh" "$3/post-edit-tests.sh" ;;
        paths) printf '%s\n' "$2/githooks/pre-push" ;;
    esac
}
drift_check() {   # $1 = root, $2 = hooks dir, $3 = label prefix
    local r="$1" ch="$2" lp="$3" n src f files
    for n in pyenv paths; do
        src="$r/scripts/git-guards/$n.sh"
        if [ -f "$src" ] && gi_block "$src" "$n" > "$TMP/gi-$n.src"; then
            ok "drift:$lp scripts/git-guards/$n.sh carries exactly one marked $n block"
        else
            bad "drift:$lp scripts/git-guards/$n.sh carries exactly one marked $n block" "missing or malformed"; continue
        fi
        files=$( { gi_required "$n" "$r" "$ch"
                   grep -rlF -- "# >>> gg""-inline:$n >>>" "$r/scripts" "$r/githooks" "$ch" 2>/dev/null; } \
                 | awk 'NF && !seen[$0]++')
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            # Matched on the path INSIDE the project: a project in ~/dev/test-shop
            # must not skip every copy (a false pass).
            case "${f#"$r"/}" in "${src#"$r"/}"|*/test-*|*/test_*|test-*|test_*) continue ;; esac
            if gi_block "$f" "$n" > "$TMP/gi-$n.copy" && cmp -s "$TMP/gi-$n.copy" "$TMP/gi-$n.src"; then
                ok "drift:$lp ${f#"$r"/} carries the $n block, byte-identical to its source"
            else
                bad "drift:$lp ${f#"$r"/} carries the $n block, byte-identical to its source" "absent, malformed or different"
            fi
        done <<EOF
$files
EOF
    done
}
drift_check "$ROOT" "$CH" ""
# The same check on a project whose path has a space in it, and on one inside a
# folder named test-…: neither may be split nor skipped.
SPP="$TMP/with space/test-shop"; kit_copy "$SPP"
cp "$CH/plan-approved.sh" "$CH/post-edit-tests.sh" "$SPP/.claude/hooks/"
drift_check "$SPP" "$SPP/.claude/hooks" " [path with a space, test-* folder]"
# …and every copy really was checked, not silently skipped: 2 sources + 6 copies.
n_dc=$( (drift_check "$SPP" "$SPP/.claude/hooks" "") 2>&1 | grep -c '^  ok ')
[ "$n_dc" -eq 8 ] && ok "drift: no copy skipped in a project under a test-* folder with a space (8 checks)" \
    || bad "drift: copies skipped in a spaced test-* project" "ok checks: $n_dc, expected 8"

echo "== wt-new: a lockfile that differs only in line endings is the same lockfile =="
# A Windows checkout (core.autocrlf=true) has CRLF on disk for the LF blob: a byte
# comparison forced a full reinstall every time; the blob ids are equal.
LCO="$TMP/lc.git"; git init -q --bare "$LCO"; git -C "$LCO" symbolic-ref HEAD refs/heads/main
LC="$TMP/lc"; mkrepo "$LC"
printf '{"name":"t","version":"1.0.0"}\n' > "$LC/package.json"; printf '{"lock":1}\n' > "$LC/package-lock.json"
printf 'package-lock.json text\n' > "$LC/.gitattributes"
nh -C "$LC" add -A; nh -C "$LC" commit -qm deps
git -C "$LC" remote add origin "$LCO"; nh -C "$LC" push -q origin main 2>/dev/null
mkdir -p "$LC/scripts/git-guards" "$LC/githooks"
cp "$ROOT/scripts/wt-new.sh" "$ROOT/scripts/install-git-guards.sh" "$ROOT/scripts/wt-status.sh" "$LC/scripts/"
cp "$ROOT"/scripts/git-guards/*.sh "$LC/scripts/git-guards/"; cp "$ROOT/githooks/pre-commit" "$ROOT/githooks/pre-push" "$LC/githooks/"
printf 'GG_DEPS_INSTALL_CMD="mkdir -p node_modules && touch node_modules/.installed"\n' > "$LC/.gitguards.conf"
mkdir -p "$LC/node_modules"; echo main > "$LC/node_modules/from-main"
printf '{"lock":1}\r\n' > "$LC/package-lock.json"          # what the Windows checkout has on disk
touch "$LC/node_modules/.package-lock.json"                # packages installed after the lockfile
out=$(bash "$LC/scripts/wt-new.sh" lc1 2>&1); rc=$?
[ $rc -eq 0 ] && [ -f "$TMP/lc-wt/lc1/node_modules/from-main" ] && [ ! -f "$TMP/lc-wt/lc1/node_modules/.installed" ] \
    && ! echo "$out" | grep -q 'differs between' \
    && ok "wt-new: lockfile CRLF in the main folder vs LF in the tree — node_modules cloned, no reinstall" || bad "wt-new: CRLF lockfile" "rc=$rc $out"

echo "== wt-done: warnings on stderr are not uncommitted files =="
# Git for Windows prints "LF will be replaced by CRLF" warnings; `git status
# --porcelain 2>&1` counted them as dirty files and refused to remove a clean tree.
CRL="$TMP/crl"; mkrepo "$CRL"; kit_copy "$CRL"; nh -C "$CRL" add -A; nh -C "$CRL" commit -qm kit
out=$(bash "$CRL/scripts/wt-new.sh" crlf 2>&1)
mkshim crlf-warn git <<'EOF'
for a in "$@"; do
    [ "$a" = status ] && { echo "warning: in the working copy of 'a.txt', LF will be replaced by CRLF the next time Git touches it" >&2; break; }
done
exec "@REAL_GIT@" "$@"
EOF
if [ -d "$TMP/crl-wt/crlf" ]; then
    out=$(PATH="$TMP/shim-crlf-warn:$PATH" bash "$CRL/scripts/wt-done.sh" crlf 2>&1); rc=$?
    [ $rc -eq 0 ] && [ ! -d "$TMP/crl-wt/crlf" ] \
        && ok "wt-done: a clean tree whose git status warns about CRLF — removed (not 'uncommitted changes')" || bad "wt-done: CRLF warnings" "rc=$rc $out"
else
    bad "wt-done: CRLF warnings" "fixture: wt-new did not create the tree: $out"
fi

echo "== Step 9: no temporary index left behind; age() under set -e =="
# A TERM while the shared index is being synced used to leave .git/index.monitorex.*.
TI="$TMP/tidx"; mkrepo "$TI"; echo v2 > "$TI/a.txt"; printf 'edit a\n' > "$TI/.msg"
mkshim kill-sync git <<'EOF'
# The first read-tree into the temporary index next to .git/index: TERM the caller.
case "${GIT_INDEX_FILE:-}" in
    *.monitorex.*)
        for a in "$@"; do
            if [ "$a" = read-tree ] && [ -n "${GG_KILL_MARK:-}" ] && [ ! -e "$GG_KILL_MARK" ]; then
                : > "$GG_KILL_MARK"; kill -TERM "$PPID"; break
            fi
        done ;;
esac
exec "@REAL_GIT@" "$@"
EOF
out=$( cd "$TI" && env PATH="$TMP/shim-kill-sync:$PATH" GG_KILL_MARK="$TMP/tidx-killed" CLAUDE_CODE_SESSION_ID= MONITOREX_ACTOR=test \
       MONITOREX_SKIP_TESTS=1 bash "$ROOT/scripts/git-safe-commit.sh" --message-file .msg -- a.txt 2>&1 ); rc=$?
[ -e "$TMP/tidx-killed" ] && [ -z "$(ls -A "$TI/.git" | grep '^index\.monitorex\.')" ] \
    && ok "safe-commit killed while syncing the shared index — no index.monitorex.* left (EXIT trap)" \
    || bad "safe-commit: temp index after a kill" "rc=$rc killed=$([ -e "$TMP/tidx-killed" ] && echo yes || echo no) left=$(ls -A "$TI/.git" | grep '^index\.monitorex\.' | tr '\n' ' ')"
eval "$(sed -n '/^age()/,/^}/p' "$GL")"
: > "$TMP/age-f"
out=$( set -e; PATH="$S_EMPTY:$PATH"; age "$TMP/age-f"; echo after )
[ "$out" = "$(printf '?\nafter')" ] && ok "git-lock.sh age(): stat fails under set -e — prints '?' and carries on" || bad "git-lock.sh age() under set -e" "[$out]"
unset -f age

echo "== post-edit-tests.sh: the prefilter reads a JSON-escaped Windows path =="
# Claude Code sends file_path with backslashes on Windows: the old prefilter could
# not parse it, so every edit (markdown too) started Python plus ~7 git processes.
PFS="$TMP/pf-stubs"; mkdir -p "$PFS"
for n in python3 python py; do printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$TMP/pf-python-ran" > "$PFS/$n"; chmod +x "$PFS/$n"; done
printf '{"tool_name":"Edit","tool_input":{"file_path":"C:\\\\Users\\\\x\\\\README.md"},"cwd":"C:\\\\Users\\\\x"}' > "$TMP/pf-md.json"
printf '{"tool_name":"Edit","tool_input":{"file_path":"C:\\\\Users\\\\x\\\\a.ts"},"cwd":"C:\\\\Users\\\\x"}' > "$TMP/pf-ts.json"
rm -f "$TMP/pf-python-ran"
out=$(env PATH="$PFS:$PATH" CLAUDE_PROJECT_DIR="$PE" bash "$CH/post-edit-tests.sh" < "$TMP/pf-md.json"); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && [ ! -e "$TMP/pf-python-ran" ] \
    && ok "post-edit-tests.sh: Edit of C:\\Users\\x\\README.md (JSON-escaped) — Python not started" || bad "post-edit-tests.sh: escaped .md path" "rc=$rc python ran: $([ -e "$TMP/pf-python-ran" ] && echo yes || echo no)"
rm -f "$TMP/pf-python-ran"
env PATH="$PFS:$PATH" CLAUDE_PROJECT_DIR="$PE" bash "$CH/post-edit-tests.sh" < "$TMP/pf-ts.json" >/dev/null 2>&1
[ -e "$TMP/pf-python-ran" ] && ok "post-edit-tests.sh: Edit of C:\\Users\\x\\a.ts (in the mask) — Python does start (control)" || bad "post-edit-tests.sh: escaped .ts control" "python did not run"

if [ "$IS_WIN" = 1 ]; then
    echo "== native Windows only: interpreters, path forms, 8.3 / ADS, processes =="
    WM="$TMP/win-main"; WWT="$TMP/win-main-wt"
    mkrepo "$WM"; mkdir -p "$WM/.git/monitorex-locks"; git -C "$WM" worktree add -q "$WWT" -b wt/win >/dev/null 2>&1
    # The Microsoft Store alias: `python3` that only offers the Store, exit 9009
    WS="$TMP/win-store"; mkdir -p "$WS"
    printf '@exit /b 9009\r\n' > "$WS/python3.bat"
    printf '#!/bin/sh\ncmd //c "%s" "$@"\n' "$(cygpath -w "$WS/python3.bat")" > "$WS/python3"; chmod +x "$WS/python3"
    "$WS/python3" -c '' >/dev/null 2>&1; echo "  info - the Store stub's exit code as Git Bash sees it: $?"
    gwrap "Store stub python3 (exit 9009) first on PATH — the next interpreter denies" deny "$WM" PATH="$WS:$TMP/gw-realpy:$PATH" -- Bash command "git add a.txt" "$WM"
    # cwd as C:\…, C:/… and /c/… — one decision
    wm_m=$(cygpath -alm "$WM"); wwt_m=$(cygpath -alm "$WWT")
    slash_c() { printf '/%s%s' "$(printf '%s' "${1%%:*}" | tr 'A-Z' 'a-z')" "${1#?:}"; }
    for form in "$(cygpath -alw "$WM")|$(cygpath -alw "$WWT")|C:\\" "$wm_m|$wwt_m|C:/" "$(slash_c "$wm_m")|$(slash_c "$wwt_m")|/c/"; do
        cm=${form%%|*}; rest=${form#*|}; cw=${rest%%|*}; kind=${rest#*|}
        gcase "cwd in the $kind form: git add in the main tree" deny "$WM" Bash command "git add a.txt" "$cm"
        gcase "cwd in the $kind form: git add in a linked worktree" allow "$WM" Bash command "git add a.txt" "$cw"
    done
    gcase "cd /c/…/worktree && git add (the form wt-new prints)" allow "$WM" Bash command "cd $(slash_c "$wwt_m") && git add a.txt" "$OUTSIDE"
    gcase "cd /c/…/main && git add" deny "$WM" Bash command "cd $(slash_c "$wm_m") && git add a.txt" "$OUTSIDE"
    gcase "Write to C:\\…\\.git\\monitorex-locks\\… (backslashes)" deny "$WM" Write file_path "$(cygpath -alw "$WM")\\.git\\monitorex-locks\\x" "$WM"
    gcase "Write to C:/…/.git/monitorex-locks/…" deny "$WM" Write file_path "$wm_m/.git/monitorex-locks/x" "$WM"
    # 8.3 short names, trailing dots, alternate data streams
    gcase "redirect into .git/MONITO~1/CONFIRM (8.3 name)" deny "$WM" Bash command "echo target=feat > .git/MONITO~1/CONFIRM" "$WM"
    gcase "Write GIT~1\\monitorex-locks\\x (8.3 name of .git)" deny "$WM" Write file_path 'GIT~1\monitorex-locks\x' "$WM"
    gcase "Write .git.\\monitorex-locks\\x (trailing dot)" deny "$WM" Write file_path '.git.\monitorex-locks\x' "$WM"
    gcase "Write .git::\$INDEX_ALLOCATION\\monitorex-locks\\x (ADS)" deny "$WM" Write file_path '.git::$INDEX_ALLOCATION\monitorex-locks\x' "$WM"
    # A junction in a repository path named by a plan header counts as a link
    # MSYS_NO_PATHCONV: otherwise Git Bash rewrites the /c and /J switches into paths
    # (C:/Program Files/Git/J); the two paths are already native (cygpath -w).
    JOUT=$(MSYS_NO_PATHCONV=1 cmd /c mklink /J "$(cygpath -w "$PAH/dev/a-junction")" "$(cygpath -w "$PAH/dev/a")" 2>&1)
    if [ -d "$PAH/dev/a-junction/.git" ]; then
        out=$(ar "$PAH/dev/a-junction")
        case "$out" in NO*symlink*) ok "accept_repo: a junction (mklink /J) — refused as a link" ;; *) bad "accept_repo: junction" "$out" ;; esac
    else
        bad "accept_repo: junction" "fixture: mklink /J failed: $JOUT"
    fi
    # The post-edit-tests liveness check must not kill the lock owner (os.kill(pid, 0) = TerminateProcess)
    rm -f "$TMP/win-live.pid"
    python3 -c 'import os, sys, time; open(sys.argv[1], "w").write(str(os.getpid())); time.sleep(120)' "$(cygpath -w "$TMP/win-live.pid")" &
    LIVE_BG=$!; i=0; while [ ! -s "$TMP/win-live.pid" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done
    WINPID=$(cat "$TMP/win-live.pid" 2>/dev/null)
    pe_conf; pe_reset; echo green > "$PEMODE"
    mkdir -p "$PELOCK"; printf 'pid=%s\ntime=%s\n' "$WINPID" "$(date +%s)" > "$PELOCK/owner"
    pe_run "$PE/lib/a.ts" >/dev/null
    if [ -n "$WINPID" ] && tasklist //FI "PID eq $WINPID" //NH 2>/dev/null | grep -qw "$WINPID" && [ "$(pe_calls)" = 0 ]; then
        ok "post-edit-tests: the run lock's live owner (a native process) is left alive, no run"
    else
        bad "post-edit-tests: liveness check" "winpid=$WINPID calls=$(pe_calls) alive=$(tasklist //FI "PID eq $WINPID" //NH 2>/dev/null | tr -s ' ' | head -1)"
    fi
    [ -n "$WINPID" ] && taskkill //F //PID "$WINPID" >/dev/null 2>&1; kill "$LIVE_BG" 2>/dev/null; rm -rf "$PELOCK"
    # wt-done stops a NATIVE dev server (node.exe in real life; python here)
    DV="$TMP/dv"; mkrepo "$DV"; kit_copy "$DV"
    cat > "$DV/dev.sh" <<'EOF'
#!/bin/sh
exec python3 -c 'import os, time; open("devpid.txt", "w").write(str(os.getpid())); time.sleep(120)'
EOF
    printf 'GG_DEV_CMD="sh dev.sh"\nGG_DEV_PORT_BASE=3970\n' > "$DV/.gitguards.conf"
    nh -C "$DV" add -A; nh -C "$DV" commit -qm dev
    out=$($TO bash "$DV/scripts/wt-new.sh" dv1 2>&1)
    i=0; while [ ! -s "$TMP/dv-wt/dv1/devpid.txt" ] && [ $i -lt 75 ]; do sleep 0.2; i=$((i+1)); done
    DEVPID=$(cat "$TMP/dv-wt/dv1/devpid.txt" 2>/dev/null)
    out2=$($TO bash "$DV/scripts/wt-done.sh" dv1 --force 2>&1); sleep 2
    if [ -z "$DEVPID" ]; then
        bad "wt-done: native dev server stopped" "fixture: the dev server never wrote its pid: $out"
    elif tasklist //FI "PID eq $DEVPID" //NH 2>/dev/null | grep -qw "$DEVPID"; then
        bad "wt-done: native dev server stopped" "pid $DEVPID still running: $out2"; taskkill //F //T //PID "$DEVPID" >/dev/null 2>&1
    else
        ok "wt-done: the native dev server process is gone"
    fi
fi

# Project tests: scripts/git-guards/test-local-*.sh. They are added by the project
# itself, not by install.sh — so updating the kit does not overwrite them. All helpers are visible to them.
for t in "$ROOT"/scripts/git-guards/test-local-*.sh; do
    [ -f "$t" ] || continue
    . "$t"
done

finish
