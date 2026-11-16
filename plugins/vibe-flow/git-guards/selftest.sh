#!/usr/bin/env bash
# selftest.sh TARGET — does the PreToolUse guard really block on this machine?
#
# WHY. The guard is fail-open by the owner's decision: a missing or broken Python
# lets the tool call through. That used to be silent — the kit "installed fine"
# while the guard could deny nothing (Windows: cp1252 stdout crashed every deny;
# macOS: /usr/bin/python3 3.9 crashed on 3.10 syntax). Fail-open stays, silence
# goes: install.sh and tools/rollout-projects.sh prepare run this check, and a miss
# fails the install / marks the project failed. There is no switch to skip it.
#
# What it does, as Claude Code would:
#   1. TARGET/.claude/settings.json registers a PreToolUse command containing
#      "monitorex-git-guard" for Bash AND for Write|Edit|MultiEdit|NotebookEdit;
#   2. the main working tree = the parent of TARGET's --git-common-dir (TARGET may be
#      a linked worktree: its settings.json, the main tree's guard and policy);
#   3. the EXACT registered command runs through `bash -c`, cwd = the main tree,
#      CLAUDE_PROJECT_DIR = TARGET, so TARGET's own hooks run (on Windows twice:
#      C:\… and /c/… forms), with
#      four payloads, decisions read by the hook protocol (deny ⇔ rc 2, or rc 0 and a
#      JSON permissionDecision "deny"; anything else but a clean allow is an error):
#        git add x → deny · git commit -m "исправление" → deny (UTF-8)
#        Write <common dir>/monitorex-locks/x → deny · git status → allow
#
# Exit 0 + "✅ guard self-test passed: the guard blocks on this machine";
# exit 1 + "🔴 the guard does not block on this machine: <reason>" on stderr.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB="$HERE/files/scripts/git-guards"
PASS_MSG='✅ guard self-test passed: the guard blocks on this machine'

fail() { printf '🔴 the guard does not block on this machine: %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] && [ -n "$1" ] || { echo "usage: bash selftest.sh TARGET" >&2; exit 2; }
for lib in paths.sh pyenv.sh; do
    [ -f "$LIB/$lib" ] || fail "the kit is incomplete: $LIB/$lib is missing"
    . "$LIB/$lib"
done
TARGET="$1"
[ -d "$TARGET" ] || fail "$TARGET is not a directory"

# Payloads are built and replies parsed by Python: no Python, no guard either.
gg_python 2>/dev/null \
    || fail "no working Python 3.9+ found (tried python3, python, py -3) — install Python 3.9+ from python.org"

# ── 1. Registration ──────────────────────────────────────────────────────────
SETTINGS="$TARGET/.claude/settings.json"
[ -f "$SETTINGS" ] || fail "no .claude/settings.json in $TARGET — the guard is not registered"
# Prints two lines: the command registered for Bash, then the one for the write tools.
REG=$("$GG_PY" - "$SETTINGS" <<'PY'
import json, re, sys

GUARD = "monitorex-git-guard"
WRITE_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")

def covers(matcher, tool):
    if matcher in (None, "", "*"):
        return True
    try:
        return re.fullmatch(matcher, tool) is not None
    except re.error:
        return matcher == tool

def guard_command(groups, tool):
    for group in groups:
        if not isinstance(group, dict) or not covers(group.get("matcher"), tool):
            continue
        for hook in group.get("hooks") or []:
            cmd = hook.get("command") if isinstance(hook, dict) else None
            if isinstance(cmd, str) and GUARD in cmd:
                return cmd
    return None

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        settings = json.load(fh)
except (OSError, ValueError) as exc:
    print("ERR .claude/settings.json cannot be read: %s" % exc); sys.exit(0)
groups = (settings.get("hooks") or {}).get("PreToolUse") or [] if isinstance(settings, dict) else []
bash_cmd = guard_command(groups, "Bash")
if bash_cmd is None:
    print("ERR the guard is not registered for Bash (PreToolUse) in .claude/settings.json"); sys.exit(0)
write_cmds = [guard_command(groups, t) for t in WRITE_TOOLS]
missing = [t for t, c in zip(WRITE_TOOLS, write_cmds) if c is None]
if missing:
    print("ERR the guard is not registered for %s (PreToolUse) in .claude/settings.json"
          % "|".join(missing)); sys.exit(0)
for cmd in (bash_cmd, write_cmds[0]):
    if "\n" in cmd:
        print("ERR a registered guard command spans several lines"); sys.exit(0)
print("OK")
print(bash_cmd)
print(write_cmds[0])
PY
) || fail "could not read .claude/settings.json"
case "$REG" in OK*) ;; ERR\ *) fail "${REG#ERR }" ;; *) fail "unexpected answer while reading .claude/settings.json" ;; esac
BASH_CMD=$(printf '%s\n' "$REG" | sed -n '2p')
WRITE_CMD=$(printf '%s\n' "$REG" | sed -n '3p')

# ── 2. The main working tree ─────────────────────────────────────────────────
COMMON=$(git -C "$TARGET" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || COMMON=$(git -C "$TARGET" rev-parse --git-common-dir 2>/dev/null) \
    || fail "$TARGET is not inside a git repository"
COMMON=$(gg_path "$TARGET" "$COMMON") || fail "cannot resolve the git common dir of $TARGET"
MAIN=${COMMON%/*}
[ -d "$MAIN" ] || fail "cannot find the main working tree of $TARGET"
# CLAUDE_PROJECT_DIR = TARGET: the registered command is
# `…"$CLAUDE_PROJECT_DIR/.claude/hooks/monitorex-git-guard.sh"`, so this runs the
# hooks of the tree under test. The rollout passes its prepared worktree, and must
# test the guard it is about to ship, not the old one installed in the main tree
# (code review M2). The payload cwd stays the main tree, and both share one common
# dir, so the guard's decisions are the same.
PROJ=$(gg_path "$TARGET") || fail "cannot resolve $TARGET"
# The machine's native form of the lock path, as Claude Code would send it.
LOCK_TARGET="$COMMON/monitorex-locks/x"
if gg_is_msys; then
    LOCK_TARGET=$(cygpath -w "$LOCK_TARGET")
    PROJECT_FORMS="$(cygpath -w "$PROJ")
$(cygpath -u "$PROJ")"
else
    PROJECT_FORMS=$PROJ
fi

# ── 3. The guard, run exactly as registered ──────────────────────────────────
payload() {   # tool key value → a PreToolUse JSON payload (cwd = the main tree)
    "$GG_PY" -c 'import json, sys
tool, key, value, cwd = sys.argv[1:5]
data = {"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": {key: value}, "cwd": cwd}
if tool == "Write":
    data["tool_input"]["content"] = "x"
sys.stdout.buffer.write(json.dumps(data, ensure_ascii=False).encode("utf-8"))' "$@"
}
decision() {  # $1 = rc; stdin = the hook's stdout → deny | allow | error
    "$GG_PY" -c 'import json, sys
rc = int(sys.argv[1]); out = sys.stdin.buffer.read().decode("utf-8", "replace").strip()
if rc == 2:
    print("deny"); sys.exit(0)
if rc != 0:
    print("error"); sys.exit(0)
if not out:
    print("allow"); sys.exit(0)
try:
    d = json.loads(out)
except ValueError:
    print("error"); sys.exit(0)
h = d.get("hookSpecificOutput") if isinstance(d, dict) else None
print("deny" if isinstance(h, dict) and h.get("permissionDecision") == "deny" else "allow")' "$1"
}
ERRF=$(mktemp "${TMPDIR:-/tmp}/gg-selftest.XXXXXX") || fail "mktemp failed"
OUTF=$(mktemp "${TMPDIR:-/tmp}/gg-selftest.XXXXXX") || { rm -f "$ERRF"; fail "mktemp failed"; }
trap 'rm -f "$ERRF" "$OUTF"' EXIT
check() {     # project-dir command expect label tool key value
    local proj="$1" cmd="$2" want="$3" label="$4" rc got
    shift 4
    payload "$@" "$MAIN" | ( cd "$MAIN" && CLAUDE_PROJECT_DIR="$proj" "${BASH:-bash}" -c "$cmd" ) >"$OUTF" 2>"$ERRF"
    rc=$?
    got=$(decision "$rc" < "$OUTF")
    [ "$got" = "$want" ] && return 0
    case "$got" in
        error) fail "$label: the guard failed (exit $rc) instead of answering $want — $(head -c 300 "$ERRF" | tr '\n' ' ')" ;;
        *)     fail "$label: expected $want, the guard answered $got (CLAUDE_PROJECT_DIR=$proj)" ;;
    esac
}
while IFS= read -r proj; do
    [ -n "$proj" ] || continue
    check "$proj" "$BASH_CMD"  deny  "git add x in the main working tree"            Bash command 'git add x'
    check "$proj" "$BASH_CMD"  deny  'git commit -m "исправление" in the main tree'   Bash command 'git commit -m "исправление"'
    check "$proj" "$WRITE_CMD" deny  "a Write to $LOCK_TARGET"                        Write file_path "$LOCK_TARGET"
    check "$proj" "$BASH_CMD"  allow "git status"                                     Bash command 'git status'
done <<EOF
$PROJECT_FORMS
EOF

echo "$PASS_MSG"
