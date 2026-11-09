#!/usr/bin/env bash
# Tests the rollout-projects.sh decision: which project file may be replaced and which may not.
# Runs in a temp directory; touches neither real projects nor this repository.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GG="$HERE/../plugins/vibe-flow/git-guards"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

# A project with the full kit: every file equals the canonical one
P="$TMP/roots/demo"
mkdir -p "$P/scripts/git-guards" "$P/githooks" "$P/.claude/hooks"
cp "$GG"/files/scripts/*.sh "$P/scripts/"
cp "$GG"/files/scripts/git-guards/* "$P/scripts/git-guards/"
cp "$GG"/files/githooks/* "$P/githooks/"
cp "$GG"/files/claude/hooks/* "$P/.claude/hooks/"
: > "$P/.gitguards.conf"

# Three cases: a version from the list, an unknown version, a missing file
printf '# an older version from the list\n' > "$P/scripts/wt-new.sh"
printf '# edited by the project\n' > "$P/scripts/wt-done.sh"
rm "$P/scripts/wt-status.sh"
KNOWN="$TMP/known.txt"
printf '%s  files/scripts/wt-new.sh\n' "$(git hash-object "$P/scripts/wt-new.sh")" > "$KNOWN"

out="$(GG_ROLLOUT_ROOTS="$TMP/roots" GG_ROLLOUT_KNOWN="$KNOWN" bash "$HERE/rollout-projects.sh" list)"
printf '%s\n' "$out" | grep -qx '    ~ scripts/wt-new.sh' \
    && ok "a listed version gets replaced" || bad "a listed version does not get replaced"
printf '%s\n' "$out" | grep -qx '    ! scripts/wt-done.sh (edited by the project)' \
    && ok "an unknown version counts as a project edit" || bad "an unknown version does not count as a project edit"
printf '%s\n' "$out" | grep -qx '    + scripts/wt-status.sh' \
    && ok "a missing file gets added" || bad "a missing file does not get added"
printf '%s\n' "$out" | grep -q 'demo: 3 change(s)' \
    && ok "identical files are untouched" || bad "unexpected changes: $(printf '%s' "$out" | head -1)"

# A listed hash is valid only for its own file
printf '%s  files/scripts/wt-done.sh\n' "$(git hash-object "$P/scripts/wt-new.sh")" > "$KNOWN"
out="$(GG_ROLLOUT_ROOTS="$TMP/roots" GG_ROLLOUT_KNOWN="$KNOWN" bash "$HERE/rollout-projects.sh" list)"
printf '%s\n' "$out" | grep -qx '    ! scripts/wt-new.sh (edited by the project)' \
    && ok "another file's hash does not allow a replacement" || bad "another file's hash allowed a replacement"

# Without the list the script stops instead of calling every file a project edit
if GG_ROLLOUT_ROOTS="$TMP/roots" GG_ROLLOUT_KNOWN="$TMP/missing.txt" bash "$HERE/rollout-projects.sh" list >/dev/null 2>&1; then
    bad "the script did not stop without the list"
else
    ok "the script stops without the list"
fi

# The real list is well-formed
real="$HERE/git-guards-known-blobs.txt"
malformed="$(grep -cvE '^[0-9a-f]{40}  files/[^ ]+$' "$real")"
[ "$malformed" = 0 ] && ok "the list format is valid" || bad "malformed lines in the list: $malformed"

[ "$fails" = 0 ] && { printf 'passed\n'; exit 0; }
printf 'failed: %s\n' "$fails"
exit 1
