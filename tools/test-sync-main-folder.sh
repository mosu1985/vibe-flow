#!/usr/bin/env bash
# Tests plugins/vibe-flow/scripts/sync-main-folder.sh: after a merge on GitHub the project's main
# folder moves forward to the merge commit — and NEVER loses anyone's work: not a tracked edit (even
# with merge.autoStash on), not an ignored file (.env, data/), not local commits, not another branch.
# Real git repositories in a temp directory: a bare "origin", the main folder, a worktree. The
# "merge" moves main in the bare repository with a fetch into it — nothing is ever pushed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../plugins/vibe-flow/scripts/sync-main-folder.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-sync-main-folder.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
HANG_PIDS="$TMP/hang.pids"
cleanup() {
    # A fake remote helper that the watchdog did not reach must not outlive the test.
    if [ -f "$HANG_PIDS" ]; then
        while read -r p; do kill "$p" 2>/dev/null || true; done < "$HANG_PIDS"
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
fails=0; total=0; cases=0
ok()  { total=$((total + 1)); printf '  ok   %s\n' "$1"; }
bad() { total=$((total + 1)); fails=$((fails + 1)); printf '  FAIL %s\n' "$1"; }

# Isolation: no repository above $TMP is ever discovered, no user or system git config leaks in
# (a user's merge.autoStash or hooks would change the results), no SSH override from the caller.
export GIT_CEILING_DIRECTORIES="$TMP"
: > "$TMP/gitconfig"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset GIT_SSH_COMMAND GIT_SSH GIT_DIR GIT_WORK_TREE 2>/dev/null || true
g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# A fresh case: $C/origin.git (bare), $C/main (main folder on main), $C/main-wt/x (worktree wt/x).
scenario() {
    cases=$((cases + 1)); C="$TMP/c$cases"; mkdir -p "$C"
    M="$C/main"; O="$C/origin.git"; W="$C/main-wt/x"
    g init -q "$M" && g -C "$M" symbolic-ref HEAD refs/heads/main
    printf 'a\n' > "$M/a.txt"; printf 'data/\n' > "$M/.gitignore"
    g -C "$M" add -A && g -C "$M" commit -qm init
    g init -q --bare "$O" && g -C "$O" fetch -q "$M" main:main
    g -C "$M" remote add origin "$O"
    g -C "$M" worktree add -q "$W" -b wt/x
    INIT=$(g -C "$M" rev-parse HEAD)
}
# A commit on wt/x; with "merge", origin's main moves to it (the PR merge on GitHub). Prints the sha.
commit_wt() { # $1 file, $2 content
    mkdir -p "$(dirname "$W/$1")"; printf '%s\n' "$2" > "$W/$1"
    g -C "$W" add -f -- "$1" && g -C "$W" commit -qm "change $1" && g -C "$W" rev-parse HEAD
}
merge_on_origin() { g -C "$O" fetch -q "$W" "wt/x:main"; }
run() { # from the worktree, as the deploy agent does
    local t0; t0=$(date +%s)
    out="$(cd "$W" && bash "$SCRIPT" "$@" 2>&1)"; rc=$?
    took=$(( $(date +%s) - t0 ))
    last="$(printf '%s\n' "$out" | tail -1)"
}
head_of() { g -C "$M" rev-parse HEAD; }

echo "== usage"
scenario
run; [ "$rc" = 2 ] && ok "no arguments → usage" || bad "no args: rc=$rc $out"
run main abc123; [ "$rc" = 2 ] && ok "short sha → usage" || bad "short sha: rc=$rc $out"
MC=$(commit_wt b.txt b)
run 'bad:name' "$MC"; [ "$rc" = 2 ] && ok "base that is not a branch name → usage" || bad "bad base: rc=$rc $out"

echo "== S1 clean main folder → updated"
scenario; MC=$(commit_wt b.txt b); merge_on_origin
run main "$MC"
[ "$rc" = 0 ] && [ "$(head_of)" = "$MC" ] && printf '%s' "$last" | grep -q '^main folder: updated to ' \
    && [ "$(cat "$M/b.txt")" = b ] \
    && ok "S1: main folder fast-forwarded to the merge commit" || bad "S1: rc=$rc head=$(head_of) $out"

echo "== S2 tracked edit + merge.autoStash → skipped, nothing touched"
scenario; g -C "$M" config merge.autoStash true; printf 'local\n' > "$M/a.txt"
MC=$(commit_wt a.txt a2); merge_on_origin
run main "$MC"
[ "$rc" = 1 ] && printf '%s' "$last" | grep -q '^main folder: skipped' \
    && [ "$(head_of)" = "$INIT" ] && [ "$(cat "$M/a.txt")" = local ] \
    && [ -z "$(g -C "$M" stash list)" ] && g -C "$M" diff --cached --quiet \
    && ok "S2: refused; HEAD, index, the edit and the stash list untouched" || bad "S2: rc=$rc head=$(head_of) a=$(cat "$M/a.txt") $out"

echo "== S3 main folder on another branch → skipped"
scenario; g -C "$M" checkout -q -b topic
MC=$(commit_wt b.txt b); merge_on_origin
run main "$MC"
[ "$rc" = 1 ] && printf '%s' "$last" | grep -q '^main folder: skipped' \
    && [ "$(g -C "$M" rev-parse refs/heads/main)" = "$INIT" ] && [ "$(g -C "$M" rev-parse refs/heads/topic)" = "$INIT" ] \
    && [ "$(g -C "$M" symbolic-ref --short HEAD)" = topic ] \
    && ok "S3: another branch checked out → no branch moved" || bad "S3: rc=$rc $out"

echo "== S4 already up to date"
scenario; MC=$(commit_wt b.txt b); merge_on_origin
run main "$MC"; run main "$MC"
[ "$rc" = 0 ] && printf '%s' "$last" | grep -q '^main folder: already up to date' && [ "$(head_of)" = "$MC" ] \
    && ok "S4: second run → already up to date" || bad "S4: rc=$rc $out"

echo "== S5 ignored file the merge starts tracking → skipped, file kept (also on retry)"
scenario; mkdir -p "$M/data"; printf 'LIVE-STATE\n' > "$M/data/state.json"
MC=$(commit_wt data/state.json tracked); merge_on_origin
run main "$MC"
first_rc=$rc; first_last=$last
run main "$MC"
[ "$first_rc" = 1 ] && printf '%s' "$first_last" | grep -q '^main folder: skipped' && [ "$rc" = 1 ] \
    && [ "$(cat "$M/data/state.json")" = LIVE-STATE ] && [ "$(head_of)" = "$INIT" ] \
    && ok "S5: ignored data/state.json survives the sync and its retry" || bad "S5: rc=$first_rc/$rc state=$(cat "$M/data/state.json") $out"

echo "== S6 origin unreachable → skipped"
scenario; MC=$(commit_wt b.txt b); merge_on_origin; mv "$O" "$O.gone"
run main "$MC"
[ "$rc" = 1 ] && printf '%s' "$last" | grep -q '^main folder: skipped' && [ "$(head_of)" = "$INIT" ] \
    && ok "S6: fetch fails → skipped, nothing moved" || bad "S6: rc=$rc $out"

echo "== S7 origin does not contain the merge commit yet (merge queue) → skipped"
scenario; MC=$(commit_wt b.txt b)     # committed, never merged on origin
run main "$MC"
[ "$rc" = 1 ] && printf '%s' "$last" | grep -q 'does not contain' && [ "$(head_of)" = "$INIT" ] \
    && ok "S7: merge commit not on origin → skipped" || bad "S7: rc=$rc $out"

echo "== S8 local main ahead of origin → skipped, local commit kept"
scenario; MC=$(commit_wt b.txt b); merge_on_origin
g -C "$M" commit -q --allow-empty -m local-only; LOCAL=$(head_of)
run main "$MC"
[ "$rc" = 1 ] && printf '%s' "$last" | grep -q '^main folder: skipped' && [ "$(head_of)" = "$LOCAL" ] \
    && ok "S8: local commits not on origin → skipped, kept" || bad "S8: rc=$rc $out"

echo "== S9 hanging fetch → cut off by the watchdog"
scenario; MC=$(commit_wt b.txt b); merge_on_origin
mkdir -p "$TMP/bin"
cat > "$TMP/bin/git-remote-hang" <<SH
#!/bin/sh
echo \$\$ >> "$HANG_PIDS"
exec sleep 30
SH
chmod +x "$TMP/bin/git-remote-hang"
g -C "$M" remote set-url origin "hang::nowhere"
PATH="$TMP/bin:$PATH" SYNC_MAIN_TIMEOUT=2 run main "$MC"
[ "$rc" = 1 ] && printf '%s' "$last" | grep -q 'timed out' && [ "$took" -le 10 ] && [ "$(head_of)" = "$INIT" ] \
    && ok "S9: fetch cut off after the timeout (${took}s)" || bad "S9: rc=$rc took=${took}s $out"

echo "== S10 the repository's own SSH command is kept"
scenario; MC=$(commit_wt b.txt b); merge_on_origin
MARK="$C/ssh-called"
cat > "$C/fake-ssh" <<SH
#!/bin/sh
echo called > "$MARK"
exit 1
SH
chmod +x "$C/fake-ssh"
g -C "$M" config core.sshCommand "$C/fake-ssh"
g -C "$M" remote set-url origin "ssh://git@example.invalid/owner/repo.git"
run main "$MC"
[ "$rc" = 1 ] && [ -f "$MARK" ] && [ "$(head_of)" = "$INIT" ] \
    && ok "S10: core.sshCommand of the repository is used, not replaced" || bad "S10: rc=$rc mark=$([ -f "$MARK" ] && echo yes || echo no) $out"

echo
echo "sync-main-folder: $((total - fails)) of $total passed"
[ "$fails" = 0 ]
