#!/usr/bin/env bash
# Tests plugins/vibe-flow/scripts/admin-only-merge.sh against a fake gh: when the --admin merge
# under a main-admin-only ruleset is allowed, and that every refusal merges nothing.
# Runs in a temp directory; talks to no real repository.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../plugins/vibe-flow/scripts/admin-only-merge.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-admin-only-merge.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0; total=0; cases=0
ok()  { total=$((total + 1)); printf '  ok   %s\n' "$1"; }
bad() { total=$((total + 1)); fails=$((fails + 1)); printf '  FAIL %s\n' "$1"; }
SHA=0123456789abcdef0123456789abcdef01234567
TAB="$(printf '\t')"

# The fake gh: answers from files in $FAKE (<name>.out on stdout, <name>.err on stderr,
# <name>.rc as the exit code, 0 by default) and logs every call.
mkdir -p "$TMP/bin" "$TMP/work"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/log"
reply() {
    [ -f "$FAKE/$1.err" ] && cat "$FAKE/$1.err" >&2
    [ -f "$FAKE/$1.out" ] && cat "$FAKE/$1.out"
    exit "$(cat "$FAKE/$1.rc" 2>/dev/null || echo 0)"
}
case "$*" in
    "api repos/{owner}/{repo}/rulesets "*)              reply rulesets ;;
    "pr view "*)                                        reply view ;;
    "api repos/{owner}/{repo}/rules/branches/"*)        reply rules ;;
    "api repos/{owner}/{repo}/branches/"*"/protection") reply protection ;;
    "api repos/{owner}/{repo}/compare/"*)               reply compare ;;
    "pr checks "*" --json "*)                           reply checks-json ;;
    "pr checks "*" --required --watch")                 reply checks-required-watch ;;
    "pr checks "*" --required")                         reply checks-required ;;
    "pr checks "*" --watch")                            reply checks-all-watch ;;
    "pr checks "*)                                      reply checks-all ;;
    "pr merge "*)                                       reply merge ;;
    *) echo "fake gh: unexpected call: $*" >&2; exit 99 ;;
esac
SH
chmod +x "$TMP/bin/gh"

set_reply() { # $1 name, $2 stdout, $3 exit code (optional), $4 stderr (optional)
    printf '%s\n' "$2" > "$FAKE/$1.out"
    if [ -n "${3:-}" ]; then printf '%s\n' "$3" > "$FAKE/$1.rc"; else rm -f "$FAKE/$1.rc"; fi
    if [ -n "${4:-}" ]; then printf '%s\n' "$4" > "$FAKE/$1.err"; else rm -f "$FAKE/$1.err"; fi
}
# The default: a main-admin-only ruleset, harmless rules (its own + a pull_request rule without
# reviews + a required check), no classic protection, required checks green.
scenario() {
    cases=$((cases + 1)); FAKE="$TMP/case$cases"; rm -rf "$FAKE"; mkdir -p "$FAKE"; : > "$FAKE/log"
    set_reply rulesets 27891618
    set_reply view "{\"baseRefName\":\"main\",\"headRefOid\":\"$SHA\",\"reviewDecision\":\"\"}"
    set_reply rules '[{"type":"deletion","ruleset_id":1},{"type":"non_fast_forward","ruleset_id":1},
{"type":"update","parameters":{"update_allows_fetch_and_merge":false},"ruleset_id":1},
{"type":"pull_request","parameters":{"required_approving_review_count":0,"dismiss_stale_reviews_on_push":false,
"require_code_owner_review":false,"require_last_push_approval":false,"required_review_thread_resolution":false,
"allowed_merge_methods":["merge","squash","rebase"]},"ruleset_id":2},
{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,
"required_status_checks":[{"context":"ci","integration_id":15368}]},"ruleset_id":2}]'
    set_reply protection '{"message":"Branch not protected","status":"404"}' 1 'gh: Branch not protected (HTTP 404)'
    set_reply compare 0
    set_reply checks-required "ci${TAB}pass${TAB}1m${TAB}https://example.invalid/1${TAB}"
    set_reply checks-required-watch "ci${TAB}pass${TAB}2m${TAB}https://example.invalid/1${TAB}"
    set_reply checks-all "ci${TAB}pass${TAB}1m${TAB}https://example.invalid/1${TAB}"
    set_reply checks-all-watch "ci${TAB}pass${TAB}2m${TAB}https://example.invalid/1${TAB}"
    set_reply checks-json '[{"bucket":"pass","name":"ci"}]'
    set_reply merge ''
}
run() { out="$(cd "$TMP/work" && FAKE="$FAKE" PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$@" 2>&1)"; rc=$?; }
merged() { grep -q '^pr merge' "$FAKE/log"; }
refused() { # $1 test name, $2 substring the reason must contain
    if [ "$rc" = 1 ] && ! merged && printf '%s' "$out" | grep -qF -- "$2" && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ]; then
        ok "$1"
    else
        bad "$1 (rc=$rc, merge called: $(merged && echo yes || echo no)): $out"
    fi
}

echo "== not applicable"
scenario; set_reply rulesets ''
run 5
[ "$rc" = 3 ] && ! merged && ok "no main-admin-only ruleset → exit 3, nothing merged" || bad "no ruleset: rc=$rc $out"
scenario; set_reply rulesets '' 1 'gh: Not Found (HTTP 404)'
run 5
[ "$rc" = 3 ] && ! merged && ok "rulesets not readable → exit 3, nothing merged" || bad "rulesets error: rc=$rc $out"

echo "== merged"
scenario
run 5
[ "$rc" = 0 ] && grep -qx "pr merge 5 --merge --admin --match-head-commit $SHA" "$FAKE/log" \
    && printf '%s' "$out" | grep -qF 'merged with --admin (main-admin-only)' \
    && ok "ruleset + harmless rules + green checks → merged with --admin --match-head-commit <head>" \
    || bad "happy path: rc=$rc $out"
scenario
set_reply checks-required "ci${TAB}pending${TAB}0${TAB}https://example.invalid/1${TAB}" 8
run 5
[ "$rc" = 0 ] && grep -qx 'pr checks 5 --required --watch' "$FAKE/log" && merged \
    && ok "required checks pending → waits with --watch, then merges" || bad "pending: rc=$rc $out"
scenario
set_reply rules '[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"update"}]'
set_reply checks-required "no required checks reported on the 'wt/x' branch" 1
set_reply checks-all "no checks reported on the 'wt/x' branch" 1
run 5
[ "$rc" = 0 ] && merged && ok "no checks required and none reported → merged" || bad "no checks at all: rc=$rc $out"
scenario
run 5 "$SHA"
[ "$rc" = 0 ] && merged && ok "expected head equals the PR head → merged" || bad "expected head: rc=$rc $out"

echo "== refused"
scenario
set_reply rules '[{"type":"update"},{"type":"required_signatures"}]'
run 5; refused "rule required_signatures → refused" "rule required_signatures"
scenario
set_reply rules '[{"type":"update"}][{"type":"merge_queue","parameters":{}}]'
run 5; refused "rule merge_queue on the second page → refused" "rule merge_queue"
scenario
set_reply rules '[{"type":"update"},{"type":"pull_request","parameters":{"required_approving_review_count":1}}]'
run 5; refused "pull_request rule with 1 approval → refused" "requires 1 approving review"
scenario
set_reply rules '[{"type":"update"},{"type":"pull_request","parameters":{"required_approving_review_count":0,"require_code_owner_review":true}}]'
run 5; refused "pull_request rule with code owner review → refused" "require_code_owner_review"
scenario
set_reply protection '{"required_linear_history":{"enabled":true},"enforce_admins":{"enabled":false}}'
run 5; refused "classic protection with required_linear_history → refused" "required_linear_history"
scenario
set_reply protection '{"required_pull_request_reviews":{"required_approving_review_count":2,"require_code_owner_reviews":false}}'
run 5; refused "classic protection with 2 approvals → refused" "requires 2 approving review"
scenario
set_reply protection '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}' 1 'gh: Upgrade to GitHub Pro (HTTP 403)'
run 5; refused "classic protection not readable (403) → refused" "branch protection of main not read"
scenario
set_reply view "{\"baseRefName\":\"main\",\"headRefOid\":\"$SHA\",\"reviewDecision\":\"REVIEW_REQUIRED\"}"
run 5; refused "reviewDecision REVIEW_REQUIRED → refused" "REVIEW_REQUIRED"
scenario
set_reply view '' 1 'GraphQL: Could not resolve to a PullRequest with the number of 5.'
run 5; refused "PR not readable → refused" "PR #5 not read"
scenario
set_reply checks-required "ci${TAB}fail${TAB}1m${TAB}https://example.invalid/1${TAB}" 1
run 5; refused "red required check → refused" "checks not green (gh pr checks exit 1): ci"
scenario
set_reply rules '[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"update"}]'
set_reply checks-required "no required checks reported on the 'wt/x' branch" 1
set_reply checks-all "lint${TAB}fail${TAB}1m${TAB}https://example.invalid/2${TAB}" 1
run 5; refused "no required checks, a red optional one → refused" "checks not green (gh pr checks exit 1): lint"
scenario
set_reply checks-required "no required checks reported on the 'wt/x' branch" 1
set_reply checks-all "no checks reported on the 'wt/x' branch" 1
set_reply checks-json '' 1 "no checks reported on the 'wt/x' branch"
run 5; refused "a required context configured but never reported → refused" "required checks configured (ci) but not reported"
scenario
set_reply checks-json '[{"bucket":"pass","name":"other"}]'
run 5; refused "the required context missing from the reported checks → refused" "not reported or not green: ci"
scenario
set_reply rules '' 1 'gh: Server Error (HTTP 500)'
run 5; refused "branch rules not readable (API error) → refused" "rules of branch main not read"
scenario
set_reply rules '<html>rate limited</html>'
run 5; refused "branch rules not JSON → refused" "rules of branch main not readable: unexpected response"
scenario
set_reply rules '[{"type":"update"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"ci"}]}}]'
set_reply compare 3
run 5; refused "branch must be up to date and is behind → refused" "3 commit(s) behind main"
scenario
run 5 fedcba9876543210fedcba9876543210fedcba98
refused "PR head differs from the expected head → refused" "expected fedcba98"
scenario
set_reply merge '' 1 'X Pull request #5 is not mergeable: the merge commit cannot be cleanly created.'
run 5
[ "$rc" = 1 ] && printf '%s' "$out" | grep -qF 'gh pr merge --admin refused: X Pull request #5 is not mergeable' \
    && ok "gh refuses the --admin merge → exit 1 with gh's text" || bad "merge refused: rc=$rc $out"
scenario
run
[ "$rc" = 2 ] && ! merged && ok "no PR number → usage, exit 2" || bad "usage: rc=$rc $out"

echo
if [ "$fails" = 0 ]; then echo "admin-only-merge: all $total checks passed"; else echo "admin-only-merge: $fails of $total checks FAILED"; exit 1; fi
