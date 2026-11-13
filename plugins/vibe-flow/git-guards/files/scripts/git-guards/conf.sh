# conf.sh — the kit's reader of .gitguards.conf (bash 3.2+, sourced).
# Used by wt-new.sh, wt-done.sh, wt-status.sh, release-gate.sh and by
# tools/rollout-projects.sh of vibe-flow.
#
# 🔴 THE CONFIG IS DATA, NEVER CODE. These scripts used to `source` it: any line
# added to an uncommitted copy ran inside a script the guard lets the model run
# by name (and in the owner's rollout, across every project at once), and a
# branch's own GG_PROTECTED moved the release-gate base. Now:
#   - the text comes from the PROTECTED BRANCH: origin/<P> (origin/HEAD → main →
#     master, the kit-wide rule), or the committed config of local main/master
#     when there is no origin ref; the main working tree's file only while the
#     branch has no config yet (a project adopting the kit) — as in pre-push;
#   - a value is taken from the LAST `KEY=` line; quotes are handled the way the
#     shell treats the text inside them, and nothing is evaluated: `$VAR` in a
#     command stays text and is expanded when the command runs (sh -c);
#   - every key has an allowed shape; a value that does not fit is ignored OUT
#     LOUD and the default is used.
# The hooks (pre-push, plan-gate.sh, git-safe-commit.sh) keep their own copy of
# conf_raw: on values without a backslash inside double quotes it returns the same
# (test-git-guards.sh checks that). Rules for this file: lines are read only with
# `IFS= read -r`; no eval, no sourcing, no printf %b, no ${!name} built from data.

# gg_conf_raw KEY < text → the value of the last KEY= line.
# rc 1: no such line; rc 2: an unterminated quote.
gg_conf_raw() {
    local key="$1" line="" found="" l v out c nx i n closed
    while IFS= read -r l || [ -n "$l" ]; do
        l=${l//$'\r'/}
        case "$l" in "$key="*) line=$l; found=1 ;; esac
    done
    if [ -z "$found" ]; then return 1; fi
    v=${line#*=}
    case "$v" in
        \"*)
            # Inside double quotes the shell un-escapes only \$ \" \\ \` — the same here.
            v=${v#\"}; out=""; i=0; n=${#v}; closed=0
            while [ "$i" -lt "$n" ]; do
                c=${v:$i:1}
                if [ "$c" = '\' ] && [ $((i + 1)) -lt "$n" ]; then
                    nx=${v:$((i + 1)):1}
                    case "$nx" in
                        '$'|'"'|'\'|'`') out="$out$nx"; i=$((i + 2)); continue ;;
                    esac
                fi
                if [ "$c" = '"' ]; then closed=1; break; fi
                out="$out$c"; i=$((i + 1))
            done
            if [ "$closed" != 1 ]; then return 2; fi
            v=$out ;;
        \'*)
            v=${v#\'}
            case "$v" in *\'*) v=${v%%\'*} ;; *) return 2 ;; esac ;;
        *)
            v=${v%%[[:space:]]#*}
            while :; do case "$v" in *[[:space:]]) v=${v%?} ;; *) break ;; esac; done ;;
    esac
    printf '%s\n' "$v"
}

# A leading $HOME, ${HOME} or ~ in a path → the home directory. Nothing else.
gg_conf_home() {
    local v="$1" h="${HOME:-}"
    if [ -n "$h" ]; then
        case "$v" in
            '$HOME'|'${HOME}'|'~') v=$h ;;
            '$HOME/'*)   v="$h/${v#'$HOME/'}" ;;
            '${HOME}/'*) v="$h/${v#'${HOME}/'}" ;;
            '~/'*)       v="$h/${v#'~/'}" ;;
        esac
    fi
    printf '%s\n' "$v"
}

gg_no_cntrl() { case "$1" in *[[:cntrl:]]*) return 1 ;; esac; return 0; }

# Allowlist of keys and the shape of each value (the shapes shared with pre-push
# are the same regexes).
gg_conf_valid() {
    local k="$1" v="$2" re=""
    case "$k" in
        GG_PROTECTED|GG_BRANCH_PREFIX)
            if [ "$k" = GG_PROTECTED ] && [ -z "$v" ]; then return 1; fi
            case "$v" in -*|*..*) return 1 ;; esac
            re='^[A-Za-z0-9._/-]*$' ;;
        GG_WT_DIR)
            case "$v" in -*|*'$'*|*'`'*) return 1 ;; esac
            gg_no_cntrl "$v"; return ;;
        GG_DEV_PORT_BASE) re='^[0-9]{1,5}$' ;;
        GG_DEV_READY_WAIT|GG_FETCH_TIMEOUT|GG_ISSUE_TIMEOUT) re='^[0-9]{1,4}$' ;;
        GG_DEV_PORT_ENV) re='^[A-Za-z_][A-Za-z0-9_]*$' ;;
        GG_REQUIRE_DEV_READY) re='^[01]$' ;;
        GG_RELEASE_GATE_SKIP) re='^[][A-Za-z0-9_.*?/ -]*$' ;;
        # Goes into `find`/`for` unquoted — words only, none starting with - ( or ! (L5).
        GG_DEV_READY_GLOBS) re='^([A-Za-z0-9_./*][A-Za-z0-9_./*-]*( [A-Za-z0-9_./*][A-Za-z0-9_./*-]*)*)?$' ;;
        GG_DEV_CMD|GG_DEPS_INSTALL_CMD|GG_DEV_PROC_MATCH)
            gg_no_cntrl "$v"; return ;;
        *) return 1 ;;
    esac
    [[ $v =~ $re ]]
}

# gg_conf_value KEY < text → the checked value.
# rc 1: absent (silent); rc 2: invalid — a warning names the key, the caller uses its default.
gg_conf_value() {
    local k="$1" v rc
    v=$(gg_conf_raw "$k"); rc=$?
    if [ "$rc" -eq 1 ]; then return 1; fi
    if [ "$rc" -eq 0 ]; then
        if [ "$k" = GG_WT_DIR ]; then v=$(gg_conf_home "$v"); fi
        if gg_conf_valid "$k" "$v"; then printf '%s\n' "$v"; return 0; fi
    fi
    printf '⚠️  .gitguards.conf: ignoring invalid %s — using the default\n' "$k" >&2
    return 2
}

# gg_conf_init DIR — finds the protected branch and the policy text for the
# repository at DIR. Sets GG_COMMON, GG_MAIN_CONF, GG_PROT, GG_PROT_REF,
# GG_POLICY (text) and GG_POLICY_SOURCE: origin | local-branch | main-text | none.
gg_conf_init() {
    local dir="${1:-.}" h="" b="" t="" lb=""
    GG_COMMON=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
    case "$GG_COMMON" in
        /*) ;;
        *) GG_COMMON=$(cd "$dir" 2>/dev/null && cd "$GG_COMMON" 2>/dev/null && pwd -P) || return 1 ;;
    esac
    GG_MAIN_CONF="$(dirname "$GG_COMMON")/.gitguards.conf"
    GG_PROT=""; GG_PROT_REF=""; GG_POLICY=""; GG_POLICY_SOURCE=none

    # The kit-wide rule: origin/HEAD → origin/main → origin/master, the first that exists.
    if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
        h=$(git -C "$dir" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || h=""
        for b in "${h#refs/remotes/origin/}" main master; do
            [ -n "$b" ] || continue
            if git -C "$dir" rev-parse -q --verify "refs/remotes/origin/$b^{commit}" >/dev/null 2>&1; then
                GG_PROT=$b; GG_PROT_REF="refs/remotes/origin/$b"; break
            fi
        done
    fi
    if [ -n "$GG_PROT_REF" ]; then
        if t=$(git -C "$dir" show "$GG_PROT_REF:.gitguards.conf" 2>/dev/null); then
            GG_POLICY=$t; GG_POLICY_SOURCE=origin
        elif [ -f "$GG_MAIN_CONF" ]; then
            GG_POLICY=$(cat "$GG_MAIN_CONF"); GG_POLICY_SOURCE=main-text
        fi
        return 0
    fi

    # No origin ref (no origin, never fetched, or a protected branch that is neither
    # main nor master without origin/HEAD — `git remote set-head origin -a`):
    # the committed config of local main/master, else the main working tree's text.
    for b in main master; do
        if git -C "$dir" rev-parse -q --verify "refs/heads/$b^{commit}" >/dev/null 2>&1; then lb=$b; break; fi
    done
    if [ -n "$lb" ] && t=$(git -C "$dir" show "refs/heads/$lb:.gitguards.conf" 2>/dev/null); then
        GG_POLICY=$t; GG_POLICY_SOURCE=local-branch
        GG_PROT=$(printf '%s\n' "$t" | gg_conf_value GG_PROTECTED) || GG_PROT=$lb
        if [ "$GG_PROT" != "$lb" ] && t=$(git -C "$dir" show "refs/heads/$GG_PROT:.gitguards.conf" 2>/dev/null); then
            GG_POLICY=$t
        fi
    elif [ -f "$GG_MAIN_CONF" ]; then
        GG_POLICY=$(cat "$GG_MAIN_CONF"); GG_POLICY_SOURCE=main-text
        GG_PROT=$(printf '%s\n' "$GG_POLICY" | gg_conf_value GG_PROTECTED) || GG_PROT=${lb:-main}
    else
        GG_PROT=${lb:-main}
    fi
    if git -C "$dir" rev-parse -q --verify "refs/heads/$GG_PROT^{commit}" >/dev/null 2>&1; then
        GG_PROT_REF="refs/heads/$GG_PROT"
    fi
    return 0
}

# gg_get KEY DEFAULT → the checked value from the policy text, else DEFAULT.
gg_get() {
    local v
    if v=$(printf '%s\n' "$GG_POLICY" | gg_conf_value "$1"); then
        printf '%s\n' "$v"
    else
        printf '%s\n' "${2-}"
    fi
}
