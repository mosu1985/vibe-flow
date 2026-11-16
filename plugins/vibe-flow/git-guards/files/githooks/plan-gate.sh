#!/usr/bin/env sh
# plan-gate.sh — "a feature or a new migration ships only with an approved plan".
#
# ONE logic, TWO callers:
#
#   pre-push — AUTHORITATIVE. Runs the INSTALLED copy
#   ($GIT_COMMON_DIR/monitorex-hooks/plan-gate.sh, put there from the protected
#   branch on origin by install-git-guards.sh), so a branch cannot weaken it:
#       plan-gate.sh --commits <sha>...
#
#   git-safe-commit.sh — EARLY and NOT authoritative. It only gives fast feedback
#   before the commit exists; the branch can edit or drop that call, which is
#   exactly why the real check lives in pre-push:
#       plan-gate.sh <message-file> <path>...
#
# A plan is required when the commit type (first line: `[feat]: …`, `feat: …`,
# `feat(x): …`) is in GG_PLAN_REQUIRED_TYPES (default "feat"), OR the commit
# brings in a file matching GG_PLAN_REQUIRED_NEW that the protected branch does
# not have yet (a migration merged in from main is not "new"; a renamed one is).
# A required plan means:
#   - a line `Plan: <name>.md` in the message (a bare file name: no `/`, no `..`,
#     no leading dot);
#   - the file exists in one of the plans directories (see plans_dirs below:
#     the project's plansDirectory, $GG_PLANS_DIR, the old ~/.claude/plans);
#   - an approval mark $GIT_COMMON_DIR/monitorex-locks/plan-approved/<name>, no
#     older than GG_PLAN_APPROVAL_TTL_DAYS (30). The mark is written by the Claude
#     Code hook on an approved ExitPlanMode, never by the model (the PreToolUse
#     guard forbids the model any write into monitorex-locks/).
#
# The gate catches FORGETFULNESS. A deliberate lie (a hand-written plan, a
# feature renamed to [fix]) is out of its reach — that is release-gate's job.
#
# Bypass is a human decision: `scripts/git-confirm.sh feat` (TTL 15 min), used
# up by the first push it lets through.
#
# POLICY comes from the protected branch on origin, parsed line by line — never
# `source`d: an uncommitted `.gitguards.conf` in the tree would otherwise switch
# the gate off with one `exit 0`. Protected branch: refs/remotes/origin/HEAD →
# origin/main → origin/master; no origin remote → the main working tree's
# .gitguards.conf (GG_PROTECTED, default main). The same parser lives in pre-push
# and git-safe-commit.sh — keep the three in sync.
#
# Exit codes: 0 — allowed / no plan needed, 1 — rejected, 2 — usage error.

set -u

# The installed copy runs standalone from $GIT_COMMON_DIR/monitorex-hooks and cannot
# source scripts/git-guards/: the path and Python helpers are inlined (test-git-guards.sh
# checks that both blocks are byte-identical to their sources).
# >>> gg-inline:paths >>>
# Path helpers (vibe-flow 1.3.0; source: scripts/git-guards/paths.sh — keep copies identical).
# MSYS mode = Git for Windows / MSYS2 / Cygwin uname AND cygpath on PATH; else POSIX.
_gg_msys_v=""
_gg_msys() {
    if [ -z "$_gg_msys_v" ]; then
        _gg_msys_v=posix
        case "$(uname -s 2>/dev/null)" in
            MINGW*|MSYS*|CYGWIN*) if command -v cygpath >/dev/null 2>&1; then _gg_msys_v=msys; fi ;;
        esac
    fi
    [ "$_gg_msys_v" = msys ]
}
# gg_is_abs PATH: 0 for /…, X:/…, X:\… on any OS.
gg_is_abs() {
    case "${1-}" in /*|[A-Za-z]:/*|[A-Za-z]:\\*) return 0 ;; esac
    return 1
}
# gg_path [BASE] PATH: the physical absolute path. A relative PATH resolves against
# BASE, else $PWD; a missing tail is kept on the deepest existing ancestor. MSYS:
# the C:/Long/Form git prints. rc 1 and no output on failure.
gg_path() {
    if [ $# -ge 2 ]; then _gg_b=$1; _gg_p=$2; else _gg_b=""; _gg_p=${1-}; fi
    [ -n "$_gg_p" ] || return 1
    if _gg_msys; then
        case "$_gg_p" in [A-Za-z]:*) _gg_p=$(cygpath -u "$_gg_p" 2>/dev/null) || return 1 ;; esac
        case "$_gg_b" in [A-Za-z]:*) _gg_b=$(cygpath -u "$_gg_b" 2>/dev/null) || return 1 ;; esac
    fi
    case "$_gg_p" in /*) ;; *) _gg_p="${_gg_b:-.}/$_gg_p" ;; esac
    case "$_gg_p" in /*) ;; *) _gg_p="$PWD/$_gg_p" ;; esac
    while :; do case "$_gg_p" in ?*/) _gg_p=${_gg_p%/} ;; *) break ;; esac; done
    _gg_t=""
    while [ ! -d "$_gg_p" ]; do
        case "$_gg_p" in */*) ;; *) return 1 ;; esac
        _gg_t="/${_gg_p##*/}$_gg_t"; _gg_p=${_gg_p%/*}
        [ -n "$_gg_p" ] || _gg_p=/
    done
    _gg_p=$(cd "$_gg_p" 2>/dev/null && pwd -P) || return 1
    case "$_gg_p" in */) _gg_p=${_gg_p%/} ;; esac
    _gg_p="$_gg_p$_gg_t"
    [ -n "$_gg_p" ] || _gg_p=/
    if _gg_msys; then _gg_p=$(cygpath -alm "$_gg_p" 2>/dev/null) || return 1; fi
    [ -n "$_gg_p" ] || return 1
    printf '%s\n' "$_gg_p"
}
# gg_blob REV PATH: the file PATH at revision REV (repository of the current
# directory) on stdout. 0 found, 1 absent (the tree has no such path), 2 error.
# ls-tree + cat-file: no <rev>:<path> argument for MSYS to rewrite;
# --no-replace-objects: a `git replace` cannot swap what is read. Silent.
gg_blob() {
    _gg_l=$(git --no-replace-objects ls-tree --full-tree "$1" -- "$2" 2>/dev/null) || return 2
    [ -n "$_gg_l" ] || return 1
    _gg_ty=${_gg_l#* }; _gg_sha=${_gg_ty#* }; _gg_ty=${_gg_ty%% *}
    _gg_sha=${_gg_sha%%[!0-9a-f]*}
    [ "$_gg_ty" = blob ] && [ -n "$_gg_sha" ] || return 2
    git --no-replace-objects cat-file blob "$_gg_sha" 2>/dev/null || return 2
}
# <<< gg-inline:paths <<<
# >>> gg-inline:pyenv >>>
# Python resolver (vibe-flow 1.3.0; source: scripts/git-guards/pyenv.sh — keep copies identical).
# Candidates: python3, python, py -3. "Not a real Python": exit 9009/49/127 or a path
# under WindowsApps (the Microsoft Store alias). Floor: Python 3.9.
gg_py_fake() {   # RC PATH → 0 when this is not a real Python
    case "${1-}" in 9009|49|127) return 0 ;; esac
    case "${2-}" in
        */[Ww][Ii][Nn][Dd][Oo][Ww][Ss][Aa][Pp][Pp][Ss]/*) return 0 ;;
        *\\[Ww][Ii][Nn][Dd][Oo][Ww][Ss][Aa][Pp][Pp][Ss]\\*) return 0 ;;
    esac
    return 1
}
_gg_py_probe() { # CMD [ARG] → 0 and _gg_exe = sys.executable when it runs and is >= 3.9
    _gg_exe=$("$@" -c 'import sys; sys.stdout.write(sys.executable if sys.version_info >= (3, 9) else "")' 2>/dev/null)
    _gg_prc=$?
    [ "$_gg_prc" = 0 ] && [ -n "$_gg_exe" ] || return 1
    if gg_py_fake 0 "$_gg_exe"; then return 1; fi
    return 0
}
# gg_python: export GG_PY (a verified interpreter path) or say why not; rc 0/1.
# An inherited GG_PY is never trusted: it is run and checked like any candidate.
gg_python() {
    PYTHONUTF8=1; PYTHONIOENCODING=utf-8; export PYTHONUTF8 PYTHONIOENCODING
    if [ -n "${GG_PY:-}" ] && _gg_py_probe "$GG_PY"; then GG_PY=$_gg_exe; export GG_PY; return 0; fi
    for _gg_c in python3 python py; do
        _gg_p=$(command -v "$_gg_c" 2>/dev/null) || continue
        if gg_py_fake 0 "$_gg_p"; then continue; fi
        if [ "$_gg_c" = py ]; then _gg_py_probe "$_gg_p" -3 || continue
        else _gg_py_probe "$_gg_p" || continue
        fi
        GG_PY=$_gg_exe; export GG_PY; return 0
    done
    GG_PY=""
    echo "🔴 no working Python 3.9+ found (tried python3, python, py -3) — install Python 3.9+ from python.org" >&2
    return 1
}
# gg_hook_exec SCRIPT [ARGS...]: the hook wrappers' loop. Reads stdin once, runs
# `<candidate> SCRIPT ARGS` with it; exits with the hook's own code. Skips (without
# running) a missing candidate or one under WindowsApps; moves on after rc 9009, 49,
# 127 ("not a real Python") or 86 (the hook's "interpreter below 3.9"). No candidate
# left: exit 0 (fail-open, the owner's decision; the installer self-test is loud).
# stdin goes to a mktemp file when mktemp and cat exist, else (a trimmed PATH) into
# a shell variable through bash's `read -d ''` — this function runs only in bash.
gg_hook_exec() {
    PYTHONUTF8=1; PYTHONIOENCODING=utf-8; PYTHONDONTWRITEBYTECODE=1
    export PYTHONUTF8 PYTHONIOENCODING PYTHONDONTWRITEBYTECODE
    _gg_buf=""; _gg_in=""
    if command -v mktemp >/dev/null 2>&1 && command -v cat >/dev/null 2>&1; then
        _gg_buf=$(mktemp "${TMPDIR:-/tmp}/gg-hook.XXXXXX" 2>/dev/null) || _gg_buf=""
    fi
    trap '[ -z "$_gg_buf" ] || rm -f "$_gg_buf"' EXIT
    trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
    if [ -n "$_gg_buf" ]; then
        cat > "$_gg_buf" || exit 0
    else
        IFS= read -r -d '' _gg_in || true
    fi
    for _gg_c in python3 python py; do
        _gg_p=$(command -v "$_gg_c" 2>/dev/null) || continue
        if gg_py_fake 0 "$_gg_p"; then continue; fi
        if [ -n "$_gg_buf" ]; then
            if [ "$_gg_c" = py ]; then "$_gg_p" -3 "$@" < "$_gg_buf"; else "$_gg_p" "$@" < "$_gg_buf"; fi
        else
            if [ "$_gg_c" = py ]; then printf '%s' "$_gg_in" | "$_gg_p" -3 "$@"; else printf '%s' "$_gg_in" | "$_gg_p" "$@"; fi
        fi
        _gg_rc=$?
        case "$_gg_rc" in 9009|49|127|86) continue ;; esac
        exit "$_gg_rc"
    done
    exit 0
}
# <<< gg-inline:pyenv <<<

NOW=$(date +%s)
COMMON=$(git rev-parse --git-common-dir 2>/dev/null) || { echo "🔴 plan gate: not a git repository" >&2; exit 2; }
gg_is_abs "$COMMON" || COMMON=$(gg_path "$COMMON") || { echo "🔴 plan gate: cannot resolve $COMMON" >&2; exit 2; }
TOP=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
MAIN_CONF="$(dirname "$COMMON")/.gitguards.conf"
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904

# ── Policy parser (keep in sync with pre-push and git-safe-commit.sh) ────────
# Value of the LAST `KEY=` line of stdin. One pair of matching quotes is removed;
# an unquoted value ends at ` #`. Nothing is evaluated. rc 1 — key absent or invalid.
conf_raw() {
    _l=$(grep -E "^$1=" | tail -n 1 | tr -d '\r')
    [ -n "$_l" ] || return 1
    _v=${_l#*=}
    case "$_v" in
        \"*) _r=${_v#\"}; case "$_r" in *\"*) _v=${_r%%\"*} ;; *) return 1 ;; esac ;;
        \'*) _r=${_v#\'}; case "$_r" in *\'*) _v=${_r%%\'*} ;; *) return 1 ;; esac ;;
        *) _v=${_v%%[[:space:]]#*}; _v=$(printf '%s' "$_v" | sed 's/[[:space:]]*$//') ;;
    esac
    printf '%s\n' "$_v"
}
# Allowlist of keys and the shape of each value. Anything else is ignored.
conf_valid() {   # $1 key, $2 value
    case "$1" in
        GG_RELEASE_GATE|GG_REQUIRE_DEV_READY)
            printf '%s' "$2" | grep -Eq '^[01]$' ;;
        GG_PROTECTED)
            printf '%s' "$2" | grep -Eq '^[A-Za-z0-9._/-]+$' && ! printf '%s' "$2" | grep -q '\.\.' ;;
        GG_RELEASE_GATE_SKIP|GG_PLAN_REQUIRED_NEW)
            printf '%s' "$2" | grep -Eq '^[][A-Za-z0-9_.*?/ -]*$' ;;
        GG_PLAN_REQUIRED_TYPES)
            printf '%s' "$2" | grep -Eq '^[A-Za-z0-9_, -]*$' ;;
        GG_PLAN_GATE)
            printf '%s' "$2" | grep -Eq '^([A-Za-z0-9_][A-Za-z0-9_./-]*)?$' && ! printf '%s' "$2" | grep -q '\.\.' ;;
        GG_PLAN_APPROVAL_TTL_DAYS)
            printf '%s' "$2" | grep -Eq '^[0-9]{1,4}$' ;;
        GG_PLAN_GATE_EXEMPT)
            printf '%s' "$2" | grep -Eq '^[[:space:]]*([0-9a-f]{40}([[:space:]]+[0-9a-f]{40})*)?[[:space:]]*$' ;;
        GG_DEV_READY_GLOBS)
            printf '%s' "$2" | grep -Eq '^([A-Za-z0-9_./*][A-Za-z0-9_./*-]*( [A-Za-z0-9_./*][A-Za-z0-9_./*-]*)*)?$' ;;
        GG_TYPECHECK_CMD|GG_TEST_CMD|GG_DEV_CMD)
            ! printf '%s' "$2" | LC_ALL=C grep -q '[[:cntrl:]]' ;;
        *) return 1 ;;
    esac
}
conf_get() {     # $1 key; stdin — config text
    _cv=$(conf_raw "$1") || return 1
    # Empty = absent: rc 1 and the caller's default, without a false warning (1.2.11).
    conf_valid "$1" "$_cv" || { [ -z "$_cv" ] || echo "⚠️  plan gate: ignoring invalid $1 in the policy" >&2; return 1; }
    printf '%s\n' "$_cv"
}

# Contract: protected branch.
PROT=""; PROT_REF=""
if git remote get-url origin >/dev/null 2>&1; then
    _h=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || _h=""
    for _b in "${_h#refs/remotes/origin/}" main master; do
        [ -n "$_b" ] || continue
        if git rev-parse -q --verify "refs/remotes/origin/$_b^{commit}" >/dev/null 2>&1; then
            PROT=$_b; PROT_REF="refs/remotes/origin/$_b"; break
        fi
    done
else
    [ -f "$MAIN_CONF" ] && PROT=$(conf_get GG_PROTECTED < "$MAIN_CONF") || PROT=""
    [ -n "$PROT" ] || PROT=main
    git rev-parse -q --verify "refs/heads/$PROT^{commit}" >/dev/null 2>&1 && PROT_REF="refs/heads/$PROT"
fi

# Contract: policy text — the protected branch on origin, else the main working tree.
# Read with gg_blob: absent on origin (the gate is being adopted) → the main working
# tree's text; a read ERROR (Codex C1) → refuse: the defaults below would switch the
# gate off and the tree's copy is whatever the branch wants.
POLICY=""
_prc=1
case "$PROT_REF" in
    refs/remotes/*) _prc=0; POLICY=$(gg_blob "$PROT_REF" .gitguards.conf) || _prc=$? ;;
esac
if [ "$_prc" = 1 ]; then
    POLICY=""
    if [ -f "$MAIN_CONF" ]; then POLICY=$(cat "$MAIN_CONF"); fi
elif [ "$_prc" != 0 ]; then
    echo "🔴 policy from ${PROT_REF#refs/remotes/} unreadable — run: git fetch origin; if it persists, report it" >&2
    exit 1
fi
pol() { printf '%s\n' "$POLICY" | conf_get "$1"; }

# ── Helper modes for other scripts ───────────────────────────────────────────
case "${1:-}" in
    --protected) printf '%s\n' "$PROT"; [ -n "$PROT_REF" ]; exit $? ;;
    --get) [ $# -eq 2 ] || { echo "usage: plan-gate.sh --get KEY" >&2; exit 2; }
           pol "$2"; exit $? ;;
esac

# Off unless the policy turns it on: a project without these keys has no gate.
if ! printf '%s\n' "$POLICY" | grep -Eq '^GG_PLAN_(GATE|REQUIRED_TYPES|REQUIRED_NEW)='; then
    exit 0
fi
TYPES=$(pol GG_PLAN_REQUIRED_TYPES) || TYPES="feat"
if ! printf '%s\n' "$POLICY" | grep -q '^GG_PLAN_REQUIRED_TYPES='; then TYPES="feat"; fi
TYPES=$(printf '%s' "$TYPES" | tr 'A-Z,' 'a-z ')
NEWMASKS=$(pol GG_PLAN_REQUIRED_NEW) || NEWMASKS=""
TTL_DAYS=$(pol GG_PLAN_APPROVAL_TTL_DAYS) || TTL_DAYS=30
EXEMPT=$(pol GG_PLAN_GATE_EXEMPT) || EXEMPT=""
CONFIRM="$COMMON/monitorex-locks/CONFIRM"

# ── Plans directories (keep in sync with plans_dirs() in .claude/hooks/plan-approved.py) ──
# Claude Code confirms with a human every edit inside ~/.claude/ — even in auto mode — so
# projects keep plans in the project (Claude Code setting `plansDirectory`, default `.plans`).
# The plan file counts in any of: $GG_PLANS_DIR (if set), <this tree>/<plansDirectory>,
# <main tree>/<plansDirectory>, ~/.claude/plans (old plans, projects without the setting).
# plansDirectory comes from the main tree's .claude/settings.json; only a relative path
# without `..` counts. Several directories do not weaken the gate: what decides is the
# approval mark, which only the hook writes on the user's ExitPlanMode.
project_plans_dir() {
    _s="$(dirname "$COMMON")/.claude/settings.json"
    [ -f "$_s" ] && gg_python 2>/dev/null || { echo .plans; return 0; }
    "$GG_PY" - "$_s" <<'PY' 2>/dev/null || return 1
import json, re, sys
try:
    v = json.load(open(sys.argv[1], encoding="utf-8")).get("plansDirectory", ".plans")
except Exception:
    v = ".plans"
ok = isinstance(v, str) and re.fullmatch(r"\.?[A-Za-z0-9_][A-Za-z0-9_./-]*", v) and ".." not in v.split("/")
print(v.rstrip("/") if ok else "")
PY
}
plans_dirs() {   # one per line
    [ -n "${GG_PLANS_DIR:-}" ] && printf '%s\n' "$GG_PLANS_DIR"
    _pd=$(project_plans_dir) || _pd=""
    if [ -n "$_pd" ]; then
        printf '%s\n' "$TOP/$_pd"
        # Normalized: git's C:/… and the shell's /c/… are one directory on Windows.
        [ "$(gg_path "$(dirname "$COMMON")")" != "$(gg_path "$TOP")" ] && printf '%s\n' "$(dirname "$COMMON")/$_pd"
    fi
    printf '%s\n' "$HOME/.claude/plans"
}

# ── Pieces of the decision ───────────────────────────────────────────────────
commit_type() {  # first line → lower-case type, or nothing
    printf '%s\n' "$1" | sed -n -E \
        -e 's/^[[:space:]]*\[([A-Za-z0-9_-]+)\].*/\1/p' \
        -e 't' \
        -e 's/^[[:space:]]*([A-Za-z0-9_-]+)(\([^)]*\))?!?:.*/\1/p' | head -n 1 | tr 'A-Z' 'a-z'
}
type_required() {  # $1 first line
    _t=$(commit_type "$1")
    [ -n "$_t" ] || return 1
    for _x in $TYPES; do [ "$_x" = "$_t" ] && return 0; done
    return 1
}
matches_new_mask() {  # $1 repo-relative path
    [ -n "$NEWMASKS" ] || return 1
    set -f
    for _m in $NEWMASKS; do
        case "$1" in ($_m) set +f; return 0 ;; esac
    done
    set +f
    return 1
}
# Through ls-tree, not `git cat-file -e <rev>:<path>`: MSYS rewrites such an argument.
# A failed read counts as "not there": the file is then new and needs a plan (fail-closed).
in_tree() {   # $1 rev, $2 path → present at that revision
    [ -n "$(git --no-replace-objects ls-tree --full-tree "$1" -- "$2" 2>/dev/null)" ]
}
in_protected() {   # $1 path → present in the protected branch
    [ -n "$PROT_REF" ] && in_tree "$PROT_REF" "$1"
}
# New files a COMMIT brings in: added relative to its first parent (what the commit
# itself introduces — a merge of main lists main's files here, and the next filters
# drop them), added relative to the merge base with the protected branch, and absent
# from the protected branch. --no-renames: a renamed migration is a new path.
commit_new_files() {   # $1 sha
    _p=$(git rev-parse -q --verify "$1^1" 2>/dev/null) || _p=$EMPTY_TREE
    _own=$(git -c core.quotePath=false diff --no-renames --name-only --diff-filter=A "$_p" "$1" 2>/dev/null)
    [ -n "$_own" ] || return 0
    _base=""
    [ -n "$PROT_REF" ] && _base=$(git -c core.quotePath=false diff --no-renames --name-only --diff-filter=A "$PROT_REF...$1" 2>/dev/null)
    printf '%s\n' "$_own" | while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        matches_new_mask "$_f" || continue
        if [ -n "$PROT_REF" ]; then
            printf '%s\n' "$_base" | grep -qxF -- "$_f" || continue
            in_protected "$_f" && continue
        fi
        printf '%s\n' "$_f"
    done
}
# New files a FUTURE commit would bring in (early check from git-safe-commit.sh):
# decided by history, not by the index — absent from HEAD and from the protected branch.
paths_new_files() {    # $@ — pathspec relative to the current directory
    git -c core.quotePath=false ls-files --full-name -c -o --exclude-standard -- "$@" 2>/dev/null \
        | sort -u | while IFS= read -r _f; do
        [ -n "$_f" ] && [ -f "$TOP/$_f" ] || continue
        matches_new_mask "$_f" || continue
        in_tree HEAD "$_f" && continue
        in_protected "$_f" && continue
        printf '%s\n' "$_f"
    done
}
# Checks the plan named in a message. Prints the problem and returns 1 if any.
plan_problem() {   # $1 full message
    _pl=$(printf '%s\n' "$1" | grep -E '^Plan:' | head -n 1)
    if [ -z "$_pl" ]; then
        echo "no 'Plan: <file>.md' line in the message"; return 1
    fi
    _name=$(printf '%s' "$_pl" | sed -e 's/^Plan:[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$_name" in
        */*|*..*|.*|"") echo "invalid Plan: line '$_name' — a bare file name is expected, no path"; return 1 ;;
    esac
    if ! printf '%s' "$_name" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9._-]*\.md$'; then
        echo "invalid Plan: line '$_name' — expected <name>.md"; return 1
    fi
    _found=""
    _dirs=$(plans_dirs)
    while IFS= read -r _d; do
        [ -n "$_d" ] && [ -f "$_d/$_name" ] && { _found=1; break; }
    done <<EOF
$_dirs
EOF
    if [ -z "$_found" ]; then
        echo "plan file not found: $_name is in none of the plans directories: $(printf '%s' "$_dirs" | tr '\n' ' ')"; return 1
    fi
    _mark="$COMMON/monitorex-locks/plan-approved/$_name"
    if [ ! -f "$_mark" ]; then
        echo "no approval mark for $_name — the user has not approved this plan in Plan Mode (ExitPlanMode)"; return 1
    fi
    _ts=$(sed -n 's/^ts=//p' "$_mark" | head -n 1)
    case "$_ts" in ''|*[!0-9]*) echo "approval mark for $_name is damaged (no ts=)"; return 1 ;; esac
    _age=$((NOW - _ts))
    if [ "$_age" -lt -300 ] || [ "$_age" -gt $((TTL_DAYS * 86400)) ]; then
        echo "approval mark for $_name expired (older than $TTL_DAYS days)"; return 1
    fi
    return 0
}
confirm_fresh() {   # human bypass: git-confirm.sh feat, younger than 15 minutes
    [ -f "$CONFIRM" ] && grep -qx 'target=feat' "$CONFIRM" 2>/dev/null || return 1
    # GNU stat first: GNU `stat -f %m` prints filesystem info instead of failing,
    # which turned the value into junk and silently voided the mark on Linux/WSL.
    _mt=$(stat -c %Y "$CONFIRM" 2>/dev/null || stat -f %m "$CONFIRM" 2>/dev/null) || return 1
    case "$_mt" in ''|*[!0-9]*) return 1 ;; esac
    _cage=$((NOW - _mt))
    [ "$_cage" -ge -300 ] && [ "$_cage" -lt 900 ]   # a future mtime (clock skew) is not fresh
}
hint() {
    cat >&2 <<'TXT'
   A feature or a new migration ships only with a plan the user approved in
   Plan Mode: the approval mark is written by the Claude Code hook when the
   user approves ExitPlanMode. Add a line with the plan's file name to the
   commit message:
     Plan: <plan-file>.md
   A merge commit that brings in a branch with a new migration counts too:
   put the Plan: line into the merge commit's message as well.

   No approved plan for this work? Go through Plan Mode first.
   Bypass is a human decision: ask the user to run
     ! scripts/git-confirm.sh feat --yes
   (lets one push through within 15 minutes).
TXT
}

# ── Mode: early check from git-safe-commit.sh ────────────────────────────────
if [ "${1:-}" != "--commits" ]; then
    [ $# -ge 1 ] && [ -f "$1" ] || { echo "usage: plan-gate.sh --commits <sha>... | <message-file> <path>..." >&2; exit 2; }
    MSG=$(cat "$1"); shift
    why=""
    first=$(printf '%s\n' "$MSG" | head -n 1)
    type_required "$first" && why="commit type [$(commit_type "$first")]"
    if [ -z "$why" ] && [ $# -gt 0 ] && [ -n "$NEWMASKS" ]; then
        nf=$(paths_new_files "$@" | head -n 1)
        [ -n "$nf" ] && why="new file $nf"
    fi
    [ -n "$why" ] || exit 0
    problem=$(plan_problem "$MSG") && exit 0
    if confirm_fresh; then
        echo "⚪️ plan gate: $problem — allowed by a human mark (git-confirm.sh feat); pre-push will use it up" >&2
        exit 0
    fi
    echo "" >&2
    echo "🔴 plan gate: this commit needs an approved plan ($why):" >&2
    echo "     $problem" >&2
    echo "" >&2
    hint
    echo "" >&2
    exit 1
fi

# ── Mode: authoritative check from pre-push ──────────────────────────────────
shift
report=""
for sha in "$@"; do
    case " $(printf '%s' "$EXEMPT" | tr '\n\t' '  ') " in *" $sha "*) continue ;; esac
    msg=$(git log -1 --format=%B "$sha" 2>/dev/null) || { report="$report$sha|cannot read the commit|
"; continue; }
    first=$(printf '%s\n' "$msg" | head -n 1)
    why=""
    type_required "$first" && why="commit type [$(commit_type "$first")]"
    if [ -z "$why" ] && [ -n "$NEWMASKS" ]; then
        nf=$(commit_new_files "$sha" | head -n 1)
        [ -n "$nf" ] && why="new file $nf"
    fi
    [ -n "$why" ] || continue
    problem=$(plan_problem "$msg") && continue
    report="$report$sha|$why|$problem
"
done

[ -n "$report" ] || exit 0

if confirm_fresh; then
    rm -f "$CONFIRM"
    echo "⚪️ plan gate: let through by a human mark (git-confirm.sh feat); the mark is now used up:" >&2
    printf '%s' "$report" | while IFS='|' read -r sha why problem; do
        [ -n "$sha" ] && printf '     %s  %s\n' "$(git rev-parse --short "$sha")" "$problem" >&2
    done
    exit 0
fi

echo "" >&2
echo "🔴 plan gate: these commits need an approved plan:" >&2
echo "" >&2
printf '%s' "$report" | while IFS='|' read -r sha why problem; do
    [ -n "$sha" ] || continue
    printf '     %s  %s\n' "$(git rev-parse --short "$sha")" "$(git log -1 --format=%s "$sha" 2>/dev/null)" >&2
    printf '       why: %s\n' "$why" >&2
    printf '       problem: %s\n' "$problem" >&2
done
echo "" >&2
hint
echo "" >&2
exit 1
