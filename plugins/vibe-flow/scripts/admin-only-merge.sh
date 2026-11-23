#!/usr/bin/env bash
# admin-only-merge.sh — the only `gh pr merge --admin` vibe-flow allows.
#
#   cd <worktree> && bash admin-only-merge.sh <PR number> [<expected head sha>]
#
# Some owners protect the production branch with a ruleset named exactly `main-admin-only`:
# only the admin role may update the branch, so an agent's bot token cannot merge. Then a plain
# `gh pr merge` is refused even for the admin ("base branch policy prohibits the merge").
# `--admin` gets past that ruleset, and past EVERY other protection of the branch too, including
# the ones a student set up for themselves. So the checks live here, in code, and not as a list
# of steps in an agent's text that a small model can skip. --admin is used only when:
#   - the repository has an active ruleset named exactly main-admin-only;
#   - no review is pending (reviewDecision is not REVIEW_REQUIRED / CHANGES_REQUESTED);
#   - the branch rules are only deletion, non_fast_forward, update, creation,
#     required_status_checks and pull_request without required reviews;
#   - classic branch protection (if any) has no required reviews, signatures, linear history,
#     conversation resolution, lock or push restrictions;
#   - the checks are green (the required ones; with none required, none of the checks is red),
#     every required check context has reported, and a branch that must be up to date is not behind;
#   - the merge is pinned to the head that was checked (--match-head-commit), and to the
#     expected head if one is given.
# Anything that cannot be read counts as a refusal (fail-closed).
#
# Exit codes: 0 merged · 3 not applicable (no main-admin-only ruleset: the caller reports the
# original refusal) · 1 refused or failed (one line saying why) · 2 usage.
set -u
ME="admin-only-merge"

usage() { printf 'usage: %s <PR number> [<expected head sha>]\n' "$ME" >&2; exit 2; }
refuse() { printf '%s: not merged — %s\n' "$ME" "$*" >&2; exit 1; }
oneline() { tr -s '\r\n\t' '   ' | sed 's/^ *//; s/ *$//'; }

[ $# -ge 1 ] && [ $# -le 2 ] || usage
n="$1"; want="${2:-}"
case "$n" in ''|*[!0-9]*) usage ;; esac
if [ -n "$want" ]; then
    case "$want" in *[!0-9a-f]*) usage ;; esac
    [ "${#want}" -eq 40 ] || usage
fi

# 1. The ruleset. No gh, an API error or no such active ruleset: the exception does not apply.
command -v gh >/dev/null 2>&1 || { printf '%s: not applicable — gh not found\n' "$ME" >&2; exit 3; }
rs=$(gh api 'repos/{owner}/{repo}/rulesets' --paginate \
    --jq '.[] | select(.name=="main-admin-only" and .enforcement=="active") | .id' 2>/dev/null) || rs=""
[ -n "$rs" ] || { printf '%s: not applicable — no active ruleset named main-admin-only\n' "$ME" >&2; exit 3; }

PY=""
for p in python3 python; do    # the Microsoft Store alias fails this and is skipped
    if command -v "$p" >/dev/null 2>&1 && "$p" -I -c 'import sys; sys.exit(sys.version_info < (3, 6))' >/dev/null 2>&1; then
        PY="$p"; break
    fi
done
[ -n "$PY" ] || refuse "python3 not found"
T=$(mktemp -d "${TMPDIR:-/tmp}/admin-only-merge.XXXXXX") || refuse "cannot create a temp directory"
trap 'rm -rf "$T"' EXIT

# JSON parsing. Data on stdout; on stderr the reason: exit 1 = a protection --admin would skip,
# exit 2 = the response is not what GitHub returns.
read -r -d '' PYCODE <<'PY'
import json, re, sys

def docs(path):
    """Every JSON document in the file: gh api --paginate prints one array per page."""
    text = open(path, encoding="utf-8").read()
    dec, i, out = json.JSONDecoder(), 0, []
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            break
        obj, i = dec.raw_decode(text, i)
        out.append(obj)
    if not out:
        raise ValueError("empty response")
    return out

def one(path):
    d = docs(path)
    if len(d) != 1:
        raise ValueError("several documents")
    return d[0]

def on(v):        # a protection switch counts as set unless it is false or absent
    return v is not None and v is not False

def zero(v):
    return type(v) is int and v == 0

def ctx(v):
    if not isinstance(v, str) or not v or "\n" in v or "\t" in v:
        raise ValueError("bad check context")
    return "ctx\t" + v

def view(path):
    d = one(path)
    base, head, review = d["baseRefName"], d["headRefOid"], d.get("reviewDecision") or ""
    if not (isinstance(base, str) and re.fullmatch(r"[A-Za-z0-9._/-]+", base)):
        raise ValueError("bad baseRefName")
    if not (isinstance(head, str) and re.fullmatch(r"[0-9a-f]{40}", head)):
        raise ValueError("bad headRefOid")
    if not isinstance(review, str):
        raise ValueError("bad reviewDecision")
    print(base); print(head); print(review)
    return []

def rules(path):
    bad, out = [], []
    for page in docs(path):
        if not isinstance(page, list):
            raise ValueError("not a list")
        for r in page:
            t, p = r["type"], r.get("parameters") or {}
            if not isinstance(t, str) or not isinstance(p, dict):
                raise ValueError("bad rule")
            if t in ("deletion", "non_fast_forward", "update", "creation"):
                continue
            if t == "pull_request":
                if not zero(p.get("required_approving_review_count")):
                    bad.append("pull_request rule requires %s approving review(s)" % p.get("required_approving_review_count"))
                for k in ("require_code_owner_review", "require_last_push_approval", "required_review_thread_resolution"):
                    if on(p.get(k)):
                        bad.append("pull_request rule: " + k)
                if p.get("required_reviewers") not in (None, []):
                    bad.append("pull_request rule: required_reviewers")
                mm = p.get("allowed_merge_methods")
                if mm is not None and (not isinstance(mm, list) or "merge" not in mm):
                    bad.append("pull_request rule: merge commits not allowed")
            elif t == "required_status_checks":
                lst = p.get("required_status_checks")
                if not isinstance(lst, list):
                    raise ValueError("bad required_status_checks")
                out += [ctx(c["context"]) for c in lst]
                if on(p.get("strict_required_status_checks_policy")):
                    out.append("strict")
            else:
                bad.append("rule " + t)
    print("\n".join(out))
    return bad

def protection(path):
    d, bad, out = one(path), [], []
    if not isinstance(d, dict):
        raise ValueError("not an object")
    r = d.get("required_pull_request_reviews")
    if r is not None:
        if not isinstance(r, dict):
            raise ValueError("bad required_pull_request_reviews")
        if not zero(r.get("required_approving_review_count")):
            bad.append("classic protection requires %s approving review(s)" % r.get("required_approving_review_count"))
        for k in ("require_code_owner_reviews", "require_last_push_approval"):
            if on(r.get(k)):
                bad.append("classic protection: " + k)
    for k in ("required_signatures", "required_linear_history", "required_conversation_resolution", "lock_branch"):
        v = d.get(k)
        if v is not None and (not isinstance(v, dict) or on(v.get("enabled"))):
            bad.append("classic protection: " + k)
    if d.get("restrictions") is not None:
        bad.append("classic protection: push restrictions")
    s = d.get("required_status_checks")
    if s is not None:
        if not isinstance(s, dict):
            raise ValueError("bad required_status_checks")
        out += [ctx(c) for c in (s.get("contexts") or [])]
        out += [ctx(c["context"]) for c in (s.get("checks") or [])]
        if on(s.get("strict")):
            out.append("strict")
    print("\n".join(out))
    return bad

def present(path, need_path):
    items = one(path)
    if not isinstance(items, list):
        raise ValueError("not a list")
    good = {i["name"] for i in items if i.get("bucket") in ("pass", "skipping")}
    need = sorted({l[4:] for l in open(need_path, encoding="utf-8").read().splitlines() if l.startswith("ctx\t")})
    miss = [c for c in need if c not in good]
    return [", ".join(miss)] if miss else []

try:
    bad = {"view": view, "rules": rules, "protection": protection, "present": present}[sys.argv[1]](*sys.argv[2:])
except Exception as e:
    sys.stderr.write("unexpected response (%s: %s)" % (e.__class__.__name__, e))
    sys.exit(2)
if bad:
    sys.stderr.write("; ".join(bad))
    sys.exit(1)
PY
judge() { # $1 reason if a protection is found, $2 what was read; then the parser arguments
    local why="$1" what="$2" prc; shift 2
    "$PY" -I -c "$PYCODE" "$@" 2> "$T/err.py"; prc=$?
    case "$prc" in
        0) return 0 ;;
        1) refuse "$why: $(cat "$T/err.py")" ;;
        *) refuse "$what not readable: $(cat "$T/err.py")" ;;
    esac
}

# 2. The PR: base, head, review — one read, so the head checked below is the head merged.
gh pr view "$n" --json baseRefName,headRefOid,reviewDecision > "$T/view" 2> "$T/err" \
    || refuse "PR #$n not read: $(oneline < "$T/err")"
judge "PR #$n" "PR #$n" view "$T/view" > "$T/view.out"
{ read -r base; read -r head; read -r review; } < "$T/view.out"
[ -z "$want" ] || [ "$head" = "$want" ] || refuse "PR #$n head is $head, expected $want"

# 3. A pending review: --admin would skip it.
case "$review" in
    REVIEW_REQUIRED|CHANGES_REQUESTED) refuse "review $review — --admin would skip it" ;;
esac

# 4. Branch rules from every ruleset: anything beyond the harmless set would be skipped.
gh api "repos/{owner}/{repo}/rules/branches/$base" --paginate > "$T/rules" 2> "$T/err" \
    || refuse "rules of branch $base not read: $(oneline < "$T/err")"
judge "branch $base has protection --admin would skip" "rules of branch $base" rules "$T/rules" > "$T/need"

# 5. Classic branch protection. 404 "Branch not protected" = none.
if gh api "repos/{owner}/{repo}/branches/$base/protection" > "$T/prot" 2> "$T/err"; then
    judge "branch $base has protection --admin would skip" "branch protection of $base" protection "$T/prot" >> "$T/need"
elif ! grep -q 'Branch not protected' "$T/prot" "$T/err" 2>/dev/null; then
    refuse "branch protection of $base not read: $(oneline < "$T/err")"
fi

# 6. "Require branches to be up to date": --admin would merge a branch that is behind.
if grep -qx 'strict' "$T/need"; then
    behind=$(gh api "repos/{owner}/{repo}/compare/$base...$head" --jq .behind_by 2> "$T/err") \
        || refuse "comparison with $base not read: $(oneline < "$T/err")"
    [ "$behind" = 0 ] || refuse "the branch must be up to date and is ${behind:-?} commit(s) behind $base — update it first"
fi

# 7. Checks. Pending (exit 8) → wait with --watch and judge that exit code.
checks() { # $@ = extra flags → crc, cout
    cout=$(gh pr checks "$n" "$@" 2>&1); crc=$?
    if [ "$crc" = 8 ]; then cout=$(gh pr checks "$n" "$@" --watch 2>&1); crc=$?; fi
}
not_green() {
    local names
    names=$(printf '%s\n' "$cout" | awk -F'\t' '$2=="fail"||$2=="cancel"||$2=="pending"{print $1}' | sort -u | paste -s -d, - | sed 's/,/, /g')
    refuse "checks not green (gh pr checks exit $crc): ${names:-$(printf '%s\n' "$cout" | tail -1 | oneline)}"
}
checks --required
if [ "$crc" != 0 ]; then
    printf '%s' "$cout" | grep -qi 'no required checks reported' || not_green
    checks                                  # none required: none of the checks may be red
    if [ "$crc" != 0 ] && ! printf '%s' "$cout" | grep -qi 'no checks reported'; then not_green; fi
fi
# A required check that never reported is absent from the lists above: match the contexts.
if grep -q '^ctx' "$T/need"; then
    gh pr checks "$n" --json name,bucket > "$T/checks" 2> "$T/err" \
        || refuse "required checks configured ($(grep '^ctx' "$T/need" | cut -f2- | sort -u | paste -s -d, -)) but not reported: $(oneline < "$T/err")"
    judge "required check(s) not reported or not green" "PR checks" present "$T/checks" "$T/need"
fi

# 8. Merge, pinned to the head whose checks were seen.
out=$(gh pr merge "$n" --merge --admin --match-head-commit "$head" 2>&1) \
    || refuse "gh pr merge --admin refused: $(printf '%s' "$out" | oneline)"
printf 'merged with --admin (main-admin-only) — PR #%s, head %s\n' "$n" "$head"
