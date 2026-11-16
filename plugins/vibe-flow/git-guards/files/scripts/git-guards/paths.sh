# paths.sh — the kit's path and policy-blob helpers (POSIX sh: dash, bash 3.2,
# Git Bash; sourced, no `local`, helper variables prefixed _gg_).
#
# WHY. On native Windows (Git for Windows) one directory has three spellings:
# git prints C:/Users/x, the shell works with /c/Users/x, Claude Code sends
# C:\Users\x. A raw string comparison then takes the main tree for a worktree,
# `case … in /*)` calls C:/… relative and glues a prefix onto it. And MSYS rewrites
# an argument like `origin/main:.gitguards.conf` into `origin\main;.gitguards.conf`,
# so every `git show <rev>:<path>` silently failed and the policy readers fell back
# to the working tree's copy. These helpers are the one way to do both:
#   gg_path [BASE] PATH — physical absolute path; on MSYS the form git prints
#   gg_is_abs PATH      — /…, X:/…, X:\… (any OS)
#   gg_blob REV PATH    — a file at a revision WITHOUT a <rev>:<path> argument
# On macOS/Linux gg_path is exactly `cd <dir> && pwd -P` (identity by construction).
#
# git hooks run standalone from $GIT_COMMON_DIR/monitorex-hooks and cannot source
# this file: githooks/pre-push and githooks/plan-gate.sh carry the marked block
# below byte for byte; test-git-guards.sh compares every copy with this source.

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

# gg_is_msys: 0 in MSYS mode (Git for Windows with cygpath) — for the scripts that
# switch to the Windows process model (taskkill, netstat, /proc/<pid>/winpid).
gg_is_msys() { _gg_msys; }
