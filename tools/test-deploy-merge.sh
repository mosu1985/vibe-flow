#!/usr/bin/env bash
# Tests plugins/vibe-flow/scripts/deploy-merge.sh against a fake gh: the merge after one "yes"
# to "Deploy <sha>?" happens only for the approved commit, into the production branch, after CI;
# every refusal merges nothing. Runs in a temp directory; talks to no real repository.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../plugins/vibe-flow/scripts/deploy-merge.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-deploy-merge.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0; total=0; cases=0
ok()  { total=$((total + 1)); printf '  ok   %s\n' "$1"; }
bad() { total=$((total + 1)); fails=$((fails + 1)); printf '  FAIL %s\n' "$1"; }
SHA=0123456789abcdef0123456789abcdef01234567
OTHER=fedcba9876543210fedcba9876543210fedcba98
TAB="$(printf '\t')"

# The fake gh: answers from files in $FAKE (<name>.out on stdout, <name>.err on stderr,
# <name>.rc as the exit code, 0 by default) and logs every call. A sequence <name>.1.*,
# <name>.2.*, … is answered in order, the last one repeating.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/log"
reply() {
    local n="$1"
    if [ -f "$FAKE/$1.1.out" ]; then
        local k; k=$(( $(cat "$FAKE/$1.count" 2>/dev/null || echo 0) + 1 ))
        echo "$k" > "$FAKE/$1.count"
        while [ "$k" -gt 1 ] && [ ! -f "$FAKE/$1.$k.out" ]; do k=$((k - 1)); done
        n="$1.$k"
    fi
    [ -f "$FAKE/$n.err" ] && cat "$FAKE/$n.err" >&2
    [ -f "$FAKE/$n.out" ] && cat "$FAKE/$n.out"
    exit "$(cat "$FAKE/$n.rc" 2>/dev/null || echo 0)"
}
case "$*" in
    "pr list "*)                        reply list ;;
    "pr create "*)                      reply create ;;
    "api repos/{owner}/{repo}/rules/branches/"*) reply rules ;;
    "api repos/{owner}/{repo}/branches/"*"/protection/required_status_checks") reply classic ;;
    "pr checks "*" --json "*)           reply checks-json ;;
    "pr checks "*" --required")         reply checks-required ;;
    "pr checks "*)                      reply checks-all ;;
    "pr merge "*)                       reply merge ;;
    "pr view "*" --json mergeCommit "*) reply merged-commit ;;
    *) echo "fake gh: unexpected call: $*" >&2; exit 99 ;;
esac
SH
chmod +x "$TMP/bin/gh"
# A fake admin-only-merge.sh next to a copy of the script: logs its arguments, exit from $FAKE.
mkdir -p "$TMP/scripts"
cp "$SCRIPT" "$TMP/scripts/deploy-merge.sh" 2>/dev/null
cat > "$TMP/scripts/admin-only-merge.sh" <<'SH'
#!/usr/bin/env bash
printf 'admin-only-merge %s\n' "$*" >> "$FAKE/log"
[ -f "$FAKE/admin.out" ] && cat "$FAKE/admin.out"
exit "$(cat "$FAKE/admin.rc" 2>/dev/null || echo 0)"
SH

set_reply() { # $1 name, $2 stdout, $3 exit code (optional), $4 stderr (optional)
    printf '%s\n' "$2" > "$FAKE/$1.out"
    if [ -n "${3:-}" ]; then printf '%s\n' "$3" > "$FAKE/$1.rc"; else rm -f "$FAKE/$1.rc"; fi
    if [ -n "${4:-}" ]; then printf '%s\n' "$4" > "$FAKE/$1.err"; else rm -f "$FAKE/$1.err"; fi
}
pr_json() { # $1 base, $2 head ref, $3 head oid → one open PR #7
    printf '[{"number":7,"baseRefName":"%s","headRefName":"%s","headRefOid":"%s","url":"https://example.invalid/pull/7"}]' "$1" "$2" "$3"
}
# The default: an open PR #7 of wt/x into main at the approved commit, required checks green,
# a project with a pull_request workflow.
scenario() {
    cases=$((cases + 1)); FAKE="$TMP/case$cases"; rm -rf "$FAKE"; mkdir -p "$FAKE/work/.github/workflows"; : > "$FAKE/log"
    printf 'on:\n  pull_request:\n' > "$FAKE/work/.github/workflows/test.yml"
    set_reply list "$(pr_json main wt/x "$SHA")"
    set_reply create 'https://example.invalid/pull/7'
    set_reply checks-required "ci${TAB}pass${TAB}1m${TAB}https://example.invalid/1${TAB}"
    set_reply checks-all "ci${TAB}pass${TAB}1m${TAB}https://example.invalid/1${TAB}"
    set_reply merge ''
    set_reply merged-commit 'abcabcabcabcabcabcabcabcabcabcabcabcabca'
    set_reply rules '[]'
    set_reply classic '{"message":"Not Found","status":"404"}' 1 'gh: Not Found (HTTP 404)'
    set_reply checks-json '[{"name":"ci","bucket":"pass"}]'
}
REQ='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci"},{"context":"test"}]}}]'
run() { out="$(cd "$FAKE/work" && FAKE="$FAKE" PATH="$TMP/bin:$PATH" DEPLOY_MERGE_POLL=0 DEPLOY_MERGE_CI_START=2 DEPLOY_MERGE_DEADLINE=3 DEPLOY_MERGE_HEAD_WAIT=1 bash "$TMP/scripts/deploy-merge.sh" "$@" 2>&1)"; rc=$?; }
merged() { grep -q '^pr merge' "$FAKE/log" || grep -q '^admin-only-merge' "$FAKE/log"; }
refused() { # $1 test name, $2 substring the reason must contain
    if [ "$rc" = 1 ] && ! merged && printf '%s' "$out" | grep -qF -- "$2"; then
        ok "$1"
    else
        bad "$1 (rc=$rc, merge called: $(merged && echo yes || echo no)): $out"
    fi
}

echo "== usage"
scenario; run wt/x
[ "$rc" = 2 ] && ! merged && ok "one argument → usage, nothing merged" || bad "usage: rc=$rc $out"
scenario; run wt/x 0123abc main
[ "$rc" = 2 ] && ! merged && ok "short sha → usage" || bad "short sha: rc=$rc $out"
scenario; run main "$SHA" main
refused "branch equals the production branch → refused" "production branch"

echo "== merged"
scenario; run wt/x "$SHA" main
[ "$rc" = 0 ] && grep -qx "pr merge 7 --merge --match-head-commit $SHA" "$FAKE/log" \
    && printf '%s' "$out" | grep -qF 'merged' \
    && ok "open PR into main at the approved commit, checks green → merged with --match-head-commit" \
    || bad "happy path: rc=$rc $out"
scenario
printf '[]\n' > "$FAKE/list.1.out"
printf '%s\n' "$(pr_json main wt/x "$SHA")" > "$FAKE/list.2.out"
run wt/x "$SHA" main
[ "$rc" = 0 ] && grep -qx "pr create --fill --base main --head wt/x" "$FAKE/log" && merged \
    && ok "no open PR → created with --base main --head wt/x, then merged" || bad "create: rc=$rc $out"

echo "== the PR is not the approved one"
scenario; set_reply list "$(pr_json staging wt/x "$SHA")"
run wt/x "$SHA" main
refused "open PR into another base → refused" "staging"
scenario; set_reply list "$(pr_json main wt/x "$OTHER")"
run wt/x "$SHA" main
refused "PR head differs from the approved commit → refused" "$OTHER"
scenario; set_reply list '[{"number":7,"baseRefName":"main","headRefName":"wt/x","headRefOid":"'"$SHA"'"},{"number":8,"baseRefName":"staging","headRefName":"wt/x","headRefOid":"'"$SHA"'"}]'
run wt/x "$SHA" main
refused "two open PRs of the branch → refused" "2 open"

echo "== CI"
scenario
set_reply checks-required '' 1 "no required checks reported on the 'wt/x' branch"
printf '%s\n' "ci${TAB}pending${TAB}0${TAB}u${TAB}" > "$FAKE/checks-all.1.out"; echo 8 > "$FAKE/checks-all.1.rc"
printf '%s\n' "ci${TAB}pass${TAB}1m${TAB}u${TAB}" > "$FAKE/checks-all.2.out"
run wt/x "$SHA" main
[ "$rc" = 0 ] && merged && [ "$(grep -c '^pr checks 7$' "$FAKE/log")" -ge 2 ] \
    && ok "no required checks, CI running → waits for all checks, merges after green" || bad "wait all: rc=$rc $out"
scenario
set_reply checks-required '' 1 "no required checks reported on the 'wt/x' branch"
printf '%s\n' "ci${TAB}fail${TAB}1m${TAB}u${TAB}" > "$FAKE/checks-all.out"; echo 1 > "$FAKE/checks-all.rc"
run wt/x "$SHA" main
refused "no required checks, a check is red → refused with its name" "ci"
scenario
set_reply checks-required '' 1 "no required checks reported on the 'wt/x' branch"
: > "$FAKE/checks-all.1.out"; echo 1 > "$FAKE/checks-all.1.rc"; echo "no checks reported on the 'wt/x' branch" > "$FAKE/checks-all.1.err"
printf '%s\n' "ci${TAB}pass${TAB}1m${TAB}u${TAB}" > "$FAKE/checks-all.2.out"
run wt/x "$SHA" main
[ "$rc" = 0 ] && merged && ok "checks not created yet → waits for them to appear, then merges" || bad "appear: rc=$rc $out"
scenario
set_reply checks-required '' 1 "no required checks reported on the 'wt/x' branch"
set_reply checks-all '' 1 "no checks reported on the 'wt/x' branch"
run wt/x "$SHA" main
refused "pull_request workflow present, checks never appear → refused" "CI"
scenario
set_reply checks-required '' 1 "no required checks reported on the 'wt/x' branch"
printf '%s\n' "build${TAB}skipping${TAB}0${TAB}u${TAB}" > "$FAKE/checks-all.1.out"
printf '%s\n' "build${TAB}skipping${TAB}0${TAB}u${TAB}" "ci${TAB}pass${TAB}1m${TAB}u${TAB}" > "$FAKE/checks-all.2.out"
run wt/x "$SHA" main
[ "$rc" = 0 ] && merged && [ "$(grep -c '^pr checks 7$' "$FAKE/log")" -ge 2 ] \
    && ok "only skipped checks so far (pull_request CI) → waits for the real run, then merges" || bad "skipped only: rc=$rc $out"
scenario; rm -rf "$FAKE/work/.github"
set_reply checks-required '' 1 "no required checks reported on the 'wt/x' branch"
set_reply checks-all "build${TAB}skipping${TAB}0${TAB}u${TAB}"
run wt/x "$SHA" main
[ "$rc" = 0 ] && merged && ok "only skipped checks and no pull_request CI in the project → merged" || bad "skipped no-ci: rc=$rc $out"
scenario; rm -rf "$FAKE/work/.github"
set_reply checks-required '' 1 "no required checks reported on the 'wt/x' branch"
set_reply checks-all '' 1 "no checks reported on the 'wt/x' branch"
run wt/x "$SHA" main
[ "$rc" = 0 ] && merged && ok "no CI in the project and none reported → merged" || bad "no CI: rc=$rc $out"
scenario
set_reply checks-required "ci${TAB}pending${TAB}0${TAB}u${TAB}" 8
run wt/x "$SHA" main
[ "$rc" = 3 ] && ! merged && ok "required checks still running at the deadline → exit 3, nothing merged" || bad "deadline: rc=$rc $out"
scenario
set_reply checks-required "ci${TAB}fail${TAB}1m${TAB}u${TAB}" 1
run wt/x "$SHA" main
refused "required check red → refused with its name" "ci"

echo "== required contexts from the branch rules"
scenario; set_reply rules "$REQ"
printf '%s\n' '[{"name":"ci","bucket":"pass"}]' > "$FAKE/checks-json.1.out"
printf '%s\n' '[{"name":"ci","bucket":"pass"},{"name":"test","bucket":"pass"}]' > "$FAKE/checks-json.2.out"
run wt/x "$SHA" main
[ "$rc" = 0 ] && merged && [ "$(grep -c -- '--json name,bucket' "$FAKE/log")" -ge 2 ] \
    && ok "a required context not reported yet (--required already green) → waits for it, then merges" || bad "required wait: rc=$rc $out"
scenario; set_reply rules "$REQ"
run wt/x "$SHA" main
[ "$rc" = 3 ] && ! merged && printf '%s' "$out" | grep -qF 'test' \
    && ok "a required context never reports → exit 3 naming it, nothing merged" || bad "required never: rc=$rc $out"
scenario; set_reply rules "$REQ"; set_reply checks-json '[{"name":"ci","bucket":"pass"},{"name":"test","bucket":"fail"}]'
run wt/x "$SHA" main
refused "a required context red → refused with its name" "test"
scenario; set_reply classic '{"strict":false,"contexts":["legacy"],"checks":[{"context":"legacy","app_id":null}]}'
set_reply checks-json '[{"name":"ci","bucket":"pass"},{"name":"legacy","bucket":"skipping"}]'
run wt/x "$SHA" main
[ "$rc" = 0 ] && merged && ok "classic protection context reported as skipping → counts as green, merged" || bad "classic: rc=$rc $out"
scenario; set_reply rules '' 1 'gh: Forbidden (HTTP 403)'
run wt/x "$SHA" main
refused "branch rules not readable → refused" "rules of branch main"

echo "== the head right after the push"
scenario
printf '%s\n' "$(pr_json main wt/x "$OTHER")" > "$FAKE/list.1.out"
printf '%s\n' "$(pr_json main wt/x "$SHA")" > "$FAKE/list.2.out"
run wt/x "$SHA" main
[ "$rc" = 0 ] && grep -qx "pr merge 7 --merge --match-head-commit $SHA" "$FAKE/log" \
    && ok "GitHub still shows the previous head right after the push → waits, then merges the approved commit" \
    || bad "head lag: rc=$rc $out"
scenario
run wt/x "" main
[ "$rc" = 2 ] && ! merged && ok "empty sha (a variable lost between shell calls) → usage, nothing merged" || bad "empty sha: rc=$rc $out"

echo "== the head moves while waiting"
scenario
printf '%s\n' "$(pr_json main wt/x "$SHA")" > "$FAKE/list.1.out"
printf '%s\n' "$(pr_json main wt/x "$OTHER")" > "$FAKE/list.2.out"
run wt/x "$SHA" main
refused "PR head moved after the checks → refused before the merge" "$OTHER"

echo "== merge refused by policy"
scenario; set_reply merge '' 1 'GraphQL: base branch policy prohibits the merge'
run wt/x "$SHA" main
[ "$rc" = 0 ] && grep -qx "admin-only-merge 7 $SHA" "$FAKE/log" \
    && ok "policy refusal → admin-only-merge.sh <N> <approved sha>" || bad "admin path: rc=$rc $out"
scenario; set_reply merge '' 1 'GraphQL: base branch policy prohibits the merge'; echo 3 > "$FAKE/admin.rc"
run wt/x "$SHA" main
[ "$rc" = 1 ] && printf '%s' "$out" | grep -qF 'prohibits the merge' \
    && ok "admin-only-merge does not apply → refused with the original reason" || bad "admin rc 3: rc=$rc $out"
scenario; set_reply merge '' 1 'GraphQL: Pull request is not mergeable: conflicts'
run wt/x "$SHA" main
[ "$rc" = 1 ] && ! grep -q '^admin-only-merge' "$FAKE/log" && printf '%s' "$out" | grep -qF 'conflicts' \
    && ok "other merge refusal → refused verbatim, no --admin path" || bad "conflict: rc=$rc $out"

echo
echo "deploy-merge: $((total - fails)) of $total passed"
[ "$fails" = 0 ]
