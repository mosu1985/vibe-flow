#!/usr/bin/env bash
# Tests tools/rollout-projects.sh: which project file may be replaced, the CLAUDE.md rules
# block, the pinned run (list → prepare → ship) and the `plugins` command.
# Runs in a temp directory; touches neither real projects nor this repository.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
GG="$SRC/plugins/vibe-flow/git-guards"
RB="$SRC/plugins/vibe-flow/scripts/rules-block.py"
TPL="$SRC/plugins/vibe-flow/templates/CLAUDE.flow.md"
CUR="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' \
    "$SRC/plugins/vibe-flow/.claude-plugin/plugin.json")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
has()  { printf '%s\n' "$1" | grep -qxF -- "$2"; }      # exact line
hasp() { printf '%s\n' "$1" | grep -qF -- "$2"; }       # substring
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1

# ── A vibe-flow source repository with a local origin ───────────────────────
# A clone keeps the full history (the history fallback needs it); the code under
# test is overlaid on top and pushed to origin/main — the only source rollout trusts.
VF="$TMP/vf"
git clone -q "$SRC" "$VF" 2>/dev/null
git clone -q --bare "$VF" "$TMP/vf-origin.git"
git -C "$VF" remote set-url origin "$TMP/vf-origin.git"
rm -rf "$VF/plugins" "$VF/tools" "$VF/.claude-plugin"
cp -R "$SRC/plugins" "$SRC/tools" "$SRC/.claude-plugin" "$VF/"
git -C "$VF" add -A && git -C "$VF" commit -qm overlay --allow-empty
git -C "$VF" push -q origin HEAD:main
vf_sha() { git -C "$TMP/vf-origin.git" rev-parse refs/heads/main; }
export GG_ROLLOUT_REPO="$VF" GG_ROLLOUT_STATE="$TMP/state"
rollout() { bash "$HERE/rollout-projects.sh" "$@"; }

kit() { # a directory with the full canonical kit
    mkdir -p "$1/scripts/git-guards" "$1/githooks" "$1/.claude/hooks"
    cp "$GG"/files/scripts/*.sh "$1/scripts/"
    cp "$GG"/files/scripts/git-guards/* "$1/scripts/git-guards/"
    cp "$GG"/files/githooks/* "$1/githooks/"
    cp "$GG"/files/claude/hooks/* "$1/.claude/hooks/"
    [ -f "$1/.gitguards.conf" ] || : > "$1/.gitguards.conf"
}
block() { # a rules block of version $1 built from the current template
    printf '<!-- vibe-flow:begin v%s -->\n%s\n<!-- vibe-flow:end -->' "$1" "$(cat "$TPL")"
}
claude_md() { # $1 file, $2 version → own text around the block
    { printf '# Own rules\n\nkeep me\n\n'; block "$2"; printf '\n\n## After\ntail text\n'; } > "$1"
}
own_text() { # the text outside the markers
    python3 - "$1" <<'PY'
import re,sys
t=open(sys.argv[1]).read()
print(re.sub(r"<!-- vibe-flow:begin[^>]*-->.*?<!-- vibe-flow:end -->","@@",t,flags=re.S),end="")
PY
}

echo "== git-guards files (list)"
P="$TMP/roots/demo"
kit "$P"
# Three cases: a version from the list, an unknown version, a missing file
printf '# an older version from the list\n' > "$P/scripts/wt-new.sh"
printf '# edited by the project\n' > "$P/scripts/wt-done.sh"
rm "$P/scripts/wt-status.sh"
KNOWN="$TMP/known.txt"
printf '%s  files/scripts/wt-new.sh\n' "$(git hash-object "$P/scripts/wt-new.sh")" > "$KNOWN"

out="$(GG_ROLLOUT_ROOTS="$TMP/roots" GG_ROLLOUT_KNOWN="$KNOWN" rollout list)"
has "$out" '    ~ scripts/wt-new.sh' \
    && ok "a listed version gets replaced" || bad "a listed version does not get replaced"
has "$out" '    ! scripts/wt-done.sh (edited by the project)' \
    && ok "an unknown version counts as a project edit" || bad "an unknown version does not count as a project edit"
has "$out" '    + scripts/wt-status.sh' \
    && ok "a missing file gets added" || bad "a missing file does not get added"
hasp "$out" 'demo: 3 change(s)' \
    && ok "identical files are untouched" || bad "unexpected changes: $(printf '%s' "$out" | head -1)"
has "$out" '    ? CLAUDE.md (missing)' \
    && ok "a missing CLAUDE.md is a note, not a change" || bad "no note for a missing CLAUDE.md"

# A listed hash is valid only for its own file
printf '%s  files/scripts/wt-done.sh\n' "$(git hash-object "$P/scripts/wt-new.sh")" > "$KNOWN"
out="$(GG_ROLLOUT_ROOTS="$TMP/roots" GG_ROLLOUT_KNOWN="$KNOWN" rollout list)"
has "$out" '    ! scripts/wt-new.sh (edited by the project)' \
    && ok "another file's hash does not allow a replacement" || bad "another file's hash allowed a replacement"

# A version known only from git history also gets replaced — also when the files come
# from the snapshot of origin/main, which has no history of its own (Codex C1)
current="$(git hash-object "$GG/files/scripts/wt-new.sh")"
old="$(git -C "$SRC" log --all -m --format= --raw --no-abbrev -- plugins/vibe-flow/git-guards/files/scripts/wt-new.sh \
    | awk '{print $4}' | grep -v '^0\{40\}$' | grep -vx "$current" | head -1)"
if [ -z "$old" ]; then
    bad "no older version of wt-new.sh in git history (shallow clone?)"
else
    git -C "$SRC" cat-file -p "$old" > "$P/scripts/wt-new.sh"
    : > "$KNOWN"
    out="$(GG_ROLLOUT_ROOTS="$TMP/roots" GG_ROLLOUT_KNOWN="$KNOWN" rollout list)"
    has "$out" '    ~ scripts/wt-new.sh' \
        && ok "a version from git history gets replaced" || bad "a version from git history does not get replaced"
fi

# Without the list the script stops instead of calling every file a project edit
if GG_ROLLOUT_ROOTS="$TMP/roots" GG_ROLLOUT_KNOWN="$TMP/missing.txt" rollout list >/dev/null 2>&1; then
    bad "the script did not stop without the list"
else
    ok "the script stops without the list"
fi

# Files come from origin/main, not from the working tree of vibe-flow
printf '#!/bin/sh\necho untracked\n' > "$VF/plugins/vibe-flow/git-guards/files/scripts/zz-untracked.sh"
out="$(GG_ROLLOUT_ROOTS="$TMP/roots" rollout list)"
hasp "$out" 'zz-untracked.sh' \
    && bad "an untracked file in the vibe-flow working tree reached the rollout" \
    || ok "an untracked file in the vibe-flow working tree is ignored"
rm "$VF/plugins/vibe-flow/git-guards/files/scripts/zz-untracked.sh"

echo "== rules-block.py"
F="$TMP/rb/CLAUDE.md"; mkdir -p "$TMP/rb"
claude_md "$F" 0.0.1
before="$(own_text "$F")"
r="$(python3 "$RB" "$F" "$TPL" 9.9.9 2>&1)"
[ "$r" = "update v0.0.1 → v9.9.9" ] && ok "an old block is updated" || bad "update: got '$r'"
[ "$(own_text "$F")" = "$before" ] && ok "text outside the markers is kept byte for byte" || bad "text outside the markers changed"
grep -q '<!-- vibe-flow:begin v9.9.9 -->' "$F" && ok "the new version is in the marker" || bad "the marker has no new version"
sum="$(cksum < "$F")"
r="$(python3 "$RB" "$F" "$TPL" 9.9.9 2>&1)"
[ "$r" = "same" ] && [ "$(cksum < "$F")" = "$sum" ] && ok "a re-run says same and writes nothing" || bad "re-run: got '$r'"
python3 - "$F" <<'PY'
import sys; p=sys.argv[1]; t=open(p).read(); open(p,"w").write(t.replace("<!-- vibe-flow:end -->","injected line\n<!-- vibe-flow:end -->"))
PY
r="$(python3 "$RB" "$F" "$TPL" 9.9.9 --check 2>&1)"
[ "$r" = "edited v9.9.9" ] && ok "an edit inside the block at the same version is detected" || bad "edited: got '$r'"
grep -q 'injected line' "$F" && ok "--check writes nothing" || bad "--check wrote the file"
python3 "$RB" "$F" "$TPL" 9.9.9 >/dev/null
grep -q 'injected line' "$F" && bad "the edit inside the block survived" || ok "an edited block is restored"
printf '# no block here\n' > "$TMP/rb/plain.md"
r="$(python3 "$RB" "$TMP/rb/plain.md" "$TPL" 9.9.9 2>&1)"
[ "$r" = "no-block" ] && [ "$(cat "$TMP/rb/plain.md")" = "# no block here" ] \
    && ok "without --append-if-missing a file without a block is left alone" || bad "no-block: got '$r'"
r="$(python3 "$RB" "$TMP/rb/plain.md" "$TPL" 9.9.9 --append-if-missing 2>&1)"
[ "$r" = "appended" ] && head -1 "$TMP/rb/plain.md" | grep -q '# no block here' && grep -q 'vibe-flow:begin v9.9.9' "$TMP/rb/plain.md" \
    && ok "--append-if-missing appends the block" || bad "append: got '$r'"
r="$(python3 "$RB" "$TMP/rb/new.md" "$TPL" 9.9.9 --append-if-missing 2>&1)"
[ "$r" = "created" ] && grep -q 'vibe-flow:begin v9.9.9' "$TMP/rb/new.md" \
    && ok "--append-if-missing creates a missing file" || bad "create: got '$r'"
r="$(python3 "$RB" "$TMP/rb/none.md" "$TPL" 9.9.9 2>&1)"
[ "$r" = "missing" ] && [ ! -e "$TMP/rb/none.md" ] && ok "a missing file is not created by default" || bad "missing: got '$r'"
claude_md "$TMP/rb/target.md" 0.0.1; ln -s "$TMP/rb/target.md" "$TMP/rb/link.md"
sum="$(cksum < "$TMP/rb/target.md")"
r="$(python3 "$RB" "$TMP/rb/link.md" "$TPL" 9.9.9 2>&1)"
[ "$r" = "symlink" ] && [ "$(cksum < "$TMP/rb/target.md")" = "$sum" ] \
    && ok "a symlink is not written through" || bad "symlink: got '$r'"
r="$(python3 "$RB" "$TMP/rb/link.md" "$TPL" 9.9.9 "--follow-symlink-within=$TMP/rb" 2>&1)"
[ "$r" = "update v0.0.1 → v9.9.9" ] && [ -L "$TMP/rb/link.md" ] && grep -q 'vibe-flow:begin v9.9.9' "$TMP/rb/target.md" \
    && ok "init mode: a symlink to a file inside the project is written through (link kept)" || bad "follow-within: got '$r'"
mkdir -p "$TMP/rb-out"; claude_md "$TMP/rb-out/t.md" 0.0.1; ln -s "$TMP/rb-out/t.md" "$TMP/rb/out-link.md"
r="$(python3 "$RB" "$TMP/rb/out-link.md" "$TPL" 9.9.9 "--follow-symlink-within=$TMP/rb" 2>&1)"
[ "$r" = "symlink" ] && grep -q 'vibe-flow:begin v0.0.1' "$TMP/rb-out/t.md" \
    && ok "init mode: a symlink pointing outside the project is not written" || bad "follow-outside: got '$r'"
claude_md "$F" 0.0.1
d="$(python3 "$RB" "$F" "$TPL" 9.9.9 --diff 2>&1)"
hasp "$d" '-<!-- vibe-flow:begin v0.0.1 -->' && hasp "$d" '+<!-- vibe-flow:begin v9.9.9 -->' \
    && grep -q 'vibe-flow:begin v0.0.1' "$F" && ok "--diff shows the change and writes nothing" || bad "--diff output wrong"

echo "== init.sh uses rules-block.py"
grep -q 'rules-block.py' "$SRC/plugins/vibe-flow/scripts/init.sh" \
    && grep -q -- '--append-if-missing' "$SRC/plugins/vibe-flow/scripts/init.sh" \
    && ! grep -q 'import os, re, sys' "$SRC/plugins/vibe-flow/scripts/init.sh" \
    && ok "init.sh calls rules-block.py --append-if-missing instead of inline Python" \
    || bad "init.sh still has its own rules-block code"

echo "== CLAUDE.md in list"
R2="$TMP/roots2"
mkrepo() { # $1 dir: a git project with the canonical kit and a first commit
    kit "$1"; git -C "$1" init -q -b main
    git -C "$1" add -A && git -C "$1" commit -qm init
}
mkrepo "$R2/p-old";     claude_md "$R2/p-old/CLAUDE.md" 0.0.1;  git -C "$R2/p-old" add CLAUDE.md;  git -C "$R2/p-old" commit -qm c
mkrepo "$R2/p-same";    claude_md "$R2/p-same/CLAUDE.md" "$CUR"; git -C "$R2/p-same" add CLAUDE.md; git -C "$R2/p-same" commit -qm c
mkrepo "$R2/p-noblock"; printf '# just text\n' > "$R2/p-noblock/CLAUDE.md"; git -C "$R2/p-noblock" add CLAUDE.md; git -C "$R2/p-noblock" commit -qm c
mkrepo "$R2/p-ignored"; printf 'CLAUDE.md\n' > "$R2/p-ignored/.gitignore"; claude_md "$R2/p-ignored/CLAUDE.md" 0.0.1
git -C "$R2/p-ignored" add .gitignore; git -C "$R2/p-ignored" commit -qm c
out="$(GG_ROLLOUT_ROOTS="$R2" rollout list)"
SHA="$(vf_sha)"
has "$out" "    ~ CLAUDE.md (rules block v0.0.1 → v$CUR)" && hasp "$out" 'p-old: 1 change(s)' \
    && ok "an old block is a change" || bad "old block not reported"
hasp "$out" 'p-same: 0 change(s)' && ok "an up-to-date block is not a change" || bad "up-to-date block reported"
has "$out" '    ? CLAUDE.md (no vibe-flow block — run /vibe-flow:init)' && hasp "$out" 'p-noblock: 0 change(s)' \
    && ok "a file without a block is a note, not counted" || bad "no-block handling wrong"
hasp "$out" 'p-ignored: 1 change(s)' && hasp "$out" '· CLAUDE.md not in git' \
    && ok "a CLAUDE.md outside git is marked" || bad "not-in-git mark missing"
[ -f "$TMP/state/$SHA/rules.diff" ] && grep -q '^-<!-- vibe-flow:begin v0.0.1 -->' "$TMP/state/$SHA/rules.diff" \
    && grep -q 'p-old' "$TMP/state/$SHA/rules.diff" \
    && ok "list writes the rules diff for the human, per run" || bad "rules.diff missing or empty"
hasp "$out" "GG_ROLLOUT_SHA=$SHA" && ok "list names the pinned sha for prepare" || bad "list does not print the sha"

echo "== prepare / ship (pinned run)"
R3="$TMP/roots3"
mkorigin() { # $1 project dir → bare origin next to it, GG_WT_DIR set
    git clone -q --bare "$1" "$1.origin.git"
    git -C "$1" remote add origin "$1.origin.git"; git -C "$1" fetch -q origin
    printf 'GG_PROTECTED="main"\nGG_WT_DIR="%s"\n' "$TMP/wt/$(basename "$1")" > "$1/.gitguards.conf"
    git -C "$1" add .gitguards.conf; git -C "$1" commit -qm conf; git -C "$1" push -q origin main
}
mkrepo "$R3/pt"; claude_md "$R3/pt/CLAUDE.md" 0.0.1; git -C "$R3/pt" add CLAUDE.md; git -C "$R3/pt" commit -qm c; mkorigin "$R3/pt"
mkrepo "$R3/pi"; printf 'CLAUDE.md\n' > "$R3/pi/.gitignore"; claude_md "$R3/pi/CLAUDE.md" 0.0.1
git -C "$R3/pi" add .gitignore; git -C "$R3/pi" commit -qm c; mkorigin "$R3/pi"
mkrepo "$R3/pn"; claude_md "$R3/pn/CLAUDE.md" 0.0.1; git -C "$R3/pn" add CLAUDE.md; git -C "$R3/pn" commit -qm c

# gh stub: PRs against the local bare origins
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$GH_LOG"
org="$(git remote get-url origin 2>/dev/null)"
case "$1 $2" in
  "pr view")
    br="$3"; f="$GH_STATE/$(basename "$org").pr"
    case "$*" in
      *headRefOid*) [ -f "$f" ] && git --git-dir="$org" rev-parse "refs/heads/$(cat "$f")" ;;
      *state*)      [ -f "$f.merged" ] && echo MERGED || echo OPEN ;;
      *number*)     [ -f "$f" ] && [ "$br" != "1" ] && [ "$(cat "$f")" = "$br" ] && echo 1 || exit 1 ;;
      *) exit 1 ;;
    esac ;;
  "pr create")
    br=""; while [ $# -gt 0 ]; do [ "$1" = "--head" ] && br="$2"; shift; done
    printf '%s' "$br" > "$GH_STATE/$(basename "$org").pr"; echo "https://example.invalid/pull/1" ;;
  "pr merge")
    if [ -f "$GH_STATE/refuse-once" ]; then
        rm -f "$GH_STATE/refuse-once"; echo "X Pull request is not mergeable: the base branch policy prohibits the merge." >&2; exit 1
    fi
    f="$GH_STATE/$(basename "$org").pr"; br="$(cat "$f")"; want=""
    while [ $# -gt 0 ]; do [ "$1" = "--match-head-commit" ] && want="$2"; shift; done
    head="$(git --git-dir="$org" rev-parse "refs/heads/$br")"
    [ -n "$want" ] && [ "$want" = "$head" ] || exit 1
    git --git-dir="$org" update-ref refs/heads/main "$head" && touch "$f.merged" ;;
  "repo view") exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMP/bin/gh"
export GH_LOG="$TMP/gh.log" GH_STATE="$TMP/ghstate"; mkdir -p "$GH_STATE"; : > "$GH_LOG"
export PATH="$TMP/bin:$PATH"

out="$(GG_ROLLOUT_ROOTS="$R3" rollout list)"; SHA="$(vf_sha)"
GG_ROLLOUT_ROOTS="$R3" rollout prepare >/dev/null 2>&1 \
    && bad "prepare ran without GG_ROLLOUT_SHA" || ok "prepare refuses without GG_ROLLOUT_SHA"
GG_ROLLOUT_SHA=0123456789abcdef0123456789abcdef01234567 GG_ROLLOUT_ROOTS="$R3" rollout prepare >/dev/null 2>&1 \
    && bad "prepare ran with an unmerged sha" || ok "prepare refuses a sha that is not in origin/main"

# origin/main moves on after list: prepare must still roll out the reviewed sha (Codex C2)
printf '\nNEW RULE AFTER REVIEW\n' >> "$VF/plugins/vibe-flow/templates/CLAUDE.flow.md"
git -C "$VF" commit -qam "rules changed after review" && git -C "$VF" push -q origin HEAD:main
pi_before="$(cksum < "$R3/pi/CLAUDE.md")"
out="$(GG_ROLLOUT_SHA="$SHA" GG_ROLLOUT_ROOTS="$R3" rollout prepare 2>&1)"
W="$TMP/wt/pt/gg-update-${SHA:0:8}"
[ -d "$W" ] && grep -q "vibe-flow:begin v$CUR" "$W/CLAUDE.md" && [ "$(git -C "$W" log -1 --format=%s)" != c ] \
    && ok "tracked CLAUDE.md: updated in the worktree and committed" || bad "tracked CLAUDE.md not prepared: $out"
grep -q 'NEW RULE AFTER REVIEW' "$W/CLAUDE.md" 2>/dev/null \
    && bad "prepare took rules newer than the reviewed sha" || ok "prepare rolls out the reviewed sha, not the newer origin/main"
[ "$(cksum < "$R3/pi/CLAUDE.md")" = "$pi_before" ] && hasp "$out" 'would update' \
    && ok "CLAUDE.md outside git: untouched on prepare" || bad "CLAUDE.md outside git touched on prepare"
grep -q "vibe-flow:begin v$CUR" "$R3/pn/CLAUDE.md" && [ -z "$(git -C "$R3/pn" status --porcelain CLAUDE.md)" ] \
    && ok "no origin: committed straight to the main folder" || bad "no-origin project not committed"
[ -f "$TMP/state/$SHA/projects/pt" ] && grep -q "^commit=$(git -C "$W" rev-parse HEAD)$" "$TMP/state/$SHA/projects/pt" \
    && ok "the run manifest records the prepared commit" || bad "manifest missing"

# a dirty worktree must survive ship (Codex C4)
printf 'local edit\n' >> "$W/CLAUDE.md"
printf 'x\n' > "$W/untracked-note.sh"
out="$(GG_ROLLOUT_SHA="$SHA" GG_ROLLOUT_ROOTS="$R3" rollout ship 2>&1)"; rc=$?
grep -q -- "--match-head-commit" "$GH_LOG" && ok "merge is pinned to the manifest commit" || bad "merge without --match-head-commit"
[ "$(git --git-dir="$R3/pt.origin.git" rev-parse refs/heads/main)" = "$(git -C "$W" rev-parse HEAD 2>/dev/null)" ] \
    && ok "ship merged exactly the manifest commit" || bad "ship merged something else: $out"
grep -q "vibe-flow:begin v$CUR" "$R3/pi/CLAUDE.md" && [ "$(own_text "$R3/pi/CLAUDE.md")" = "$(cd "$TMP" && claude_md x.md 0.0.1 && own_text x.md)" ] \
    && ls "$TMP/state/$SHA/backup/"pi-CLAUDE-*.md >/dev/null 2>&1 \
    && ok "CLAUDE.md outside git: updated on ship, own text kept, backup made" || bad "CLAUDE.md outside git not updated on ship"
grep -q 'NEW RULE AFTER REVIEW' "$R3/pi/CLAUDE.md" && bad "ship wrote rules newer than the reviewed sha" \
    || ok "ship writes the reviewed sha"
[ -d "$W" ] && [ -f "$W/untracked-note.sh" ] && grep -q 'local edit' "$W/CLAUDE.md" && [ "$rc" != 0 ] && hasp "$out" 'left in place' \
    && ok "a dirty worktree is left in place after ship" || bad "dirty worktree removed or not reported (rc=$rc)"

# push fails, an old commit sits on the remote branch: nothing is merged (Codex C3)
R4="$TMP/roots4"; : > "$GH_LOG"
mkrepo "$R4/pr"; claude_md "$R4/pr/CLAUDE.md" 0.0.1; git -C "$R4/pr" add CLAUDE.md; git -C "$R4/pr" commit -qm c; mkorigin "$R4/pr"
out="$(GG_ROLLOUT_ROOTS="$R4" rollout list)"; SHA4="$(vf_sha)"
GG_ROLLOUT_SHA="$SHA4" GG_ROLLOUT_ROOTS="$R4" rollout prepare >/dev/null 2>&1
W4="$TMP/wt/pr/gg-update-${SHA4:0:8}"
git clone -q "$R4/pr.origin.git" "$TMP/other" && git -C "$TMP/other" checkout -qb "wt/gg-update-${SHA4:0:8}" \
    && printf 'A\n' > "$TMP/other/a.txt" && git -C "$TMP/other" add a.txt && git -C "$TMP/other" commit -qm A \
    && git -C "$TMP/other" push -q origin HEAD
sed -i '' 's/^ignored_claude=no$/ignored_claude=yes/' "$TMP/state/$SHA4/projects/pr"
pr_before="$(cksum < "$R4/pr/CLAUDE.md")"
out="$(GG_ROLLOUT_SHA="$SHA4" GG_ROLLOUT_ROOTS="$R4" rollout ship 2>&1)"; rc=$?
grep -q 'pr merge' "$GH_LOG" && bad "a PR was merged after a failed push" || ok "a failed push stops the project: no merge"
[ "$rc" != 0 ] && [ -d "$W4" ] && [ "$(cksum < "$R4/pr/CLAUDE.md")" = "$pr_before" ] && hasp "$out" 'push refused' \
    && ok "after a failed push: worktree kept, CLAUDE.md untouched, exit 1" || bad "failed push handling wrong (rc=$rc)"

# a review limited by GG_ROLLOUT_ONLY does not cover a wider prepare
out="$(GG_ROLLOUT_ONLY="pr" GG_ROLLOUT_ROOTS="$R4" rollout list)"; SHA5="$(vf_sha)"
GG_ROLLOUT_SHA="$SHA5" GG_ROLLOUT_ROOTS="$R4" rollout prepare >/dev/null 2>&1 \
    && bad "prepare widened a review limited by GG_ROLLOUT_ONLY" || ok "a review limited by GG_ROLLOUT_ONLY cannot be widened"
GG_ROLLOUT_SHA="$SHA5" GG_ROLLOUT_ONLY="other" GG_ROLLOUT_ROOTS="$R4" rollout prepare >/dev/null 2>&1 \
    && bad "prepare ran for a project outside the review" || ok "a project outside the reviewed set is refused"

echo "== list compares with origin; ship waits for checks; build caches; dev route types"
R6="$TMP/roots6"; KNOWN6="$TMP/known6.txt"; : > "$GH_LOG"
printf '# old\n' > "$TMP/old-wt-new.sh"
printf '%s  files/scripts/wt-new.sh\n' "$(git hash-object "$TMP/old-wt-new.sh")" > "$KNOWN6"
push_from_clone() { # $1 project, $2 command run inside a clone of its origin, then pushed
    rm -rf "$TMP/c6"; git clone -q "$1.origin.git" "$TMP/c6"
    (cd "$TMP/c6" && eval "$2" && git add -A && git commit -qm upd && git push -q origin main)
}
# pb: origin already has the current kit, the main folder lags one commit behind
mkrepo "$R6/pb"; cp "$TMP/old-wt-new.sh" "$R6/pb/scripts/wt-new.sh"; git -C "$R6/pb" commit -qam old; mkorigin "$R6/pb"
push_from_clone "$R6/pb" "cp '$GG/files/scripts/wt-new.sh' scripts/wt-new.sh"
# pc: origin has the old file, the main folder has the new one uncommitted; a tracked build cache
mkrepo "$R6/pc"; cp "$TMP/old-wt-new.sh" "$R6/pc/scripts/wt-new.sh"; printf '{}\n' > "$R6/pc/tsconfig.tsbuildinfo"
git -C "$R6/pc" add -A; git -C "$R6/pc" commit -qm old; mkorigin "$R6/pc"
cp "$GG/files/scripts/wt-new.sh" "$R6/pc/scripts/wt-new.sh"
# pd: Next route types required, no `next typegen` — prepare starts GG_DEV_CMD once
mkrepo "$R6/pd"; cp "$TMP/old-wt-new.sh" "$R6/pd/scripts/wt-new.sh"; printf '.next/\n' > "$R6/pd/.gitignore"
git -C "$R6/pd" add -A; git -C "$R6/pd" commit -qm old; mkorigin "$R6/pd"
cat >> "$R6/pd/.gitguards.conf" <<'CONF'
GG_REQUIRE_DEV_READY=1
GG_DEV_READY_GLOBS=".next/types"
GG_DEV_CMD="mkdir -p .next/types && echo \"// \$PORT\" > .next/types/a.ts && exec sleep 37.5"
CONF
git -C "$R6/pd" commit -qam devconf; git -C "$R6/pd" push -q origin main

out="$(GG_ROLLOUT_ROOTS="$R6" GG_ROLLOUT_KNOWN="$KNOWN6" rollout list)"; SHA6="$(vf_sha)"
hasp "$out" 'pb: 0 change(s)' && hasp "$out" 'main folder 1 commit(s) behind origin' \
    && ok "list: a file already updated on origin is not a change (main folder behind is noted)" \
    || bad "list compares with the main folder instead of origin: $(printf '%s' "$out" | grep -A2 '^pb')"
has "$out" '    ~ scripts/wt-new.sh' && hasp "$out" 'pc: 1 change(s)' \
    && ok "list: an old file on origin is a change even if the main folder has the new one" \
    || bad "list missed a change on origin: $(printf '%s' "$out" | grep -A2 '^pc')"

out="$(GG_ROLLOUT_SHA="$SHA6" GG_ROLLOUT_ROOTS="$R6" GG_ROLLOUT_KNOWN="$KNOWN6" rollout prepare 2>&1)"
WC="$TMP/wt/pc/gg-update-${SHA6:0:8}"; WD="$TMP/wt/pd/gg-update-${SHA6:0:8}"
[ -f "$WD/.next/types/a.ts" ] && hasp "$out" 'route types via dev' \
    && ok "prepare: no typegen → GG_DEV_CMD run once writes the route types" \
    || bad "route types not generated: $(printf '%s' "$out" | grep -A4 '== pd')"
grep -qE '// [0-9]+$' "$WD/.next/types/a.ts" 2>/dev/null \
    && ok "the dev run gets a port in GG_DEV_PORT_ENV" || bad "the dev run got no port"
pgrep -f 'sleep 37.5' >/dev/null && { bad "the dev process is still running"; pkill -f 'sleep 37.5'; } \
    || ok "the dev process is stopped after the types appear"

printf '{"changed":1}\n' > "$WC/tsconfig.tsbuildinfo"     # the pre-push typecheck rewrites it
touch "$GH_STATE/refuse-once"                             # required checks still running
out="$(GG_ROLLOUT_SHA="$SHA6" GG_ROLLOUT_ROOTS="$R6" rollout ship 2>&1)"
[ "$(git --git-dir="$R6/pc.origin.git" rev-parse refs/heads/main)" != "$(git -C "$R6/pc" rev-parse main)" ] \
    && grep -q 'pr checks' "$GH_LOG" && ! hasp "$out" 'not merged' \
    && ok "ship: a merge refused while checks run waits for them and merges" \
    || bad "ship did not wait for checks: $(printf '%s' "$out" | grep -E 'PR|merge' | head -3)"
[ ! -d "$WC" ] && ! hasp "$out" 'left in place' \
    && ok "ship: a typecheck-rewritten build cache does not keep the worktree" \
    || bad "worktree kept because of tsconfig.tsbuildinfo"

echo "== plugins"
R5="$TMP/roots5"
for d in "p1" "p2" "loc" "Vibe school" 'x$(touch pwned)`touch pwned2`' "$(printf 'tab\there')"; do kit "$R5/$d"; done
mkdir -p "$R5/noconf/scripts"; : > "$R5/noconf/scripts/wt-new.sh"          # no .gitguards.conf
kit "$TMP/outside/proj"; ln -s "$TMP/outside/proj" "$R5/linkout"
kit "$TMP/roots5-evil/x"
REG="$TMP/installed_plugins.json"
python3 - "$REG" "$R5" "$TMP" <<'PY'
import json,sys
reg,r,t=sys.argv[1:4]
def e(scope,path=None):
    d={"scope":scope,"version":"1.0.0","installPath":"/x"}
    if path is not None: d["projectPath"]=path
    return d
ent=[e("project",f"{r}/p1"),e("project",f"{r}/p2"),e("local",f"{r}/loc"),
     e("project",f"{r}/Vibe school"),e("project",r+"/x$(touch pwned)`touch pwned2`"),
     e("project",f"{r}/missing"),e("project",f"{r}/../outside/proj"),e("project",f"{t}/roots5-evil/x"),
     e("project",f"{r}/linkout"),e("project",f"{r}/noconf"),e("project",f"{r}/tab\there"),e("user")]
json.dump({"version":2,"plugins":{"vibe-flow@vibe-school":ent,
    "other@elsewhere":[e("project",f"{r}/p1")]}},open(reg,"w"))
PY
cat > "$TMP/bin/claude-stub" <<'SH'
#!/usr/bin/env bash
cat >/dev/null   # reads stdin: must not eat the rollout's loop
printf '%s|%s\n' "$PWD" "$*" >> "$STUB_LOG"
if [ "$1 $2" = "plugin update" ]; then
    python3 - "$GG_ROLLOUT_PLUGINS_JSON" "$3" "$5" "$PWD" "$STUB_VERSION" <<'PY'
import json,sys
reg,key,scope,cwd,v=sys.argv[1:6]
d=json.load(open(reg))
for e in d["plugins"].get(key,[]):
    if e["scope"]==scope and (scope=="user" or e.get("projectPath")==cwd): e["version"]=v
json.dump(d,open(reg,"w"))
PY
fi
exit "${STUB_RC:-0}"
SH
chmod +x "$TMP/bin/claude-stub"
export STUB_LOG="$TMP/stub.log" GG_ROLLOUT_PLUGINS_JSON="$REG" GG_ROLLOUT_CLAUDE="$TMP/bin/claude-stub"
: > "$STUB_LOG"
out="$(cd "$TMP" && STUB_VERSION="$CUR" GG_ROLLOUT_ROOTS="$R5" rollout plugins 2>&1)"; rc=$?
calls="$(grep -c 'plugin update' "$STUB_LOG")"
[ "$calls" = 6 ] && ok "updates every valid install (5 project/local + 1 user): $calls" || bad "expected 6 update calls, got $calls: $out"
grep -qxF "$R5/Vibe school|plugin update vibe-flow@vibe-school --scope project" "$STUB_LOG" \
    && ok "a path with a space is used verbatim" || bad "path with a space mangled"
grep -qF 'x$(touch pwned)`touch pwned2`|plugin update' "$STUB_LOG" && [ ! -e "$TMP/pwned" ] && [ ! -e "$R5/pwned" ] && [ ! -e "$TMP/pwned2" ] \
    && ok "a path with \$(…) and backticks is not executed" || bad "special characters in a path were executed"
grep -qxF "$R5/loc|plugin update vibe-flow@vibe-school --scope local" "$STUB_LOG" && ok "local scope is updated" || bad "local scope missed"
grep -qxF "$HOME|plugin update vibe-flow@vibe-school --scope user" "$STUB_LOG" && ok "user scope runs from \$HOME" || bad "user scope wrong"
grep -q 'plugin marketplace update vibe-school' "$STUB_LOG" && ok "the marketplace is refreshed first" || bad "no marketplace update"
grep -q 'other@elsewhere' "$STUB_LOG" && bad "a foreign marketplace was touched" || ok "a foreign marketplace is left alone"
for bad_path in missing outside roots5-evil linkout noconf 'tab'; do
    grep -q "$bad_path" "$STUB_LOG" && bad "invalid path was used: $bad_path"
done
[ "$(grep -c 'skipped' <<< "$out")" -ge 6 ] && ok "invalid entries are reported as skipped" || bad "skips not reported: $out"
[ "$rc" = 1 ] && ok "skips make the exit code 1" || bad "exit code $rc, expected 1"
hasp "$out" "p1 vibe-flow: 1.0.0 → $CUR" && ok "the result is read from the registry" || bad "no before → after line"

: > "$STUB_LOG"; python3 - "$REG" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
d["plugins"]["vibe-flow@vibe-school"]=[e for e in d["plugins"]["vibe-flow@vibe-school"] if e["scope"]!="project" or e["projectPath"].endswith(("/p1","/p2"))]
json.dump(d,open(sys.argv[1],"w"))
PY
# a plugin that is gone from the marketplace: no expected version, the path must not shift
python3 - "$REG" "$R5" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
d["plugins"]["gone@vibe-school"]=[{"scope":"project","projectPath":sys.argv[2]+"/p2","version":"1.0.0"}]
json.dump(d,open(sys.argv[1],"w"))
PY
: > "$STUB_LOG"
out="$(cd "$TMP" && STUB_VERSION="$CUR" GG_ROLLOUT_ONLY="p2" GG_ROLLOUT_ROOTS="$R5" rollout plugins 2>&1)"; rc=$?
hasp "$out" "not a vibe-flow project" && bad "GG_ROLLOUT_ONLY produced false 'not a vibe-flow project' warnings" \
    || ok "GG_ROLLOUT_ONLY does not report the other projects as invalid"
grep -qxF "$R5/p2|plugin update gone@vibe-school --scope project" "$STUB_LOG" \
    && ! grep -q "^$TMP|plugin update" "$STUB_LOG" \
    && ok "an empty expected version does not shift the path field" || bad "field shift: $(cat "$STUB_LOG")"
: > "$STUB_LOG"
out="$(cd "$TMP" && STUB_VERSION=0.0.0 STUB_RC=1 GG_ROLLOUT_ONLY="p1 p2" GG_ROLLOUT_ROOTS="$R5" rollout plugins 2>&1)"; rc=$?
[ "$(grep -c 'plugin update vibe-flow' "$STUB_LOG")" = 2 ] && ok "GG_ROLLOUT_ONLY limits the run; a failure does not stop the loop" \
    || bad "ONLY/continue wrong: $(cat "$STUB_LOG")"
[ "$rc" = 1 ] && hasp "$out" '⚠️' && ok "a failed or stale update is a warning and exit 1" || bad "failure not reported (rc=$rc)"
GG_ROLLOUT_PLUGINS_JSON="$TMP/none.json" GG_ROLLOUT_ROOTS="$R5" rollout plugins >/dev/null 2>&1 \
    && bad "ran without a registry" || ok "a missing registry is an error"

echo "== the real known-blobs list"
real="$HERE/git-guards-known-blobs.txt"
malformed="$(grep -cvE '^[0-9a-f]{40}  files/[^ ]+$' "$real")"
[ "$malformed" = 0 ] && ok "the list format is valid" || bad "malformed lines in the list: $malformed"
# The list holds the versions from before the move; it can grow but must never shrink
lines="$(grep -c . "$real")"
[ "$lines" -ge 118 ] && ok "the list is complete" || bad "the list shrank: $lines lines, expected at least 118"

[ "$fails" = 0 ] && { printf 'passed\n'; exit 0; }
printf 'failed: %s\n' "$fails"
exit 1
