#!/usr/bin/env bash
# install-git-guards.sh — installs the canonical hooks OUTSIDE the working tree.
#
# Why not .husky: husky resolves the hook relative to the current checkout.
# A worktree on an old base, or switching the main working tree to a revision
# from before the guard existed, would hand git the OLD version of the hook —
# without any of its checks. A directory in git-common-dir does not depend on checkouts.
#
# 🔴 SOURCE = the protected branch on origin, not this working tree (H4). Old
# copies of this script live in every old worktree and run without any intent:
# `npm install` → `prepare`, wt-new.sh, a hint in pre-push. Copying from the tree
# they sit in silently rolled the shared hooks back to a version without the newer
# barriers — for every tree at once. Now every copy installs what is on origin,
# and a hook edited in a branch reaches the installed set only after it is merged.
#   Protected branch: refs/remotes/origin/HEAD → origin/main → origin/master.
#   origin configured but none of those fetched → refuse (`git fetch`), do NOT
#     fall back to the tree.
#   No origin remote, or origin has no githooks/pre-push yet (the project is just
#     adopting git-guards) → BOOTSTRAP from this working tree, said out loud.
#   githooks/pre-push exists on origin but cannot be read → error, not bootstrap.
# The source is recorded in monitorex-hooks/.source: origin@<sha> | bootstrap@<sha>.
#
# Idempotent: identical content is left alone, different content is overwritten.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
COMMON=$(git -C "$ROOT" rev-parse --git-common-dir)
case "$COMMON" in /*) ;; *) COMMON="$(cd "$ROOT/$COMMON" && pwd -P)" ;; esac
DEST="$COMMON/monitorex-hooks"
HOOKS="pre-commit pre-push plan-gate.sh"
die() { printf '\n🔴 install-git-guards: %s\n\n' "$*" >&2; exit 1; }

g() { git -C "$ROOT" "$@"; }

PROT_REF=""
if g remote get-url origin >/dev/null 2>&1; then
    h=$(g symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || h=""
    for b in "${h#refs/remotes/origin/}" main master; do
        [ -n "$b" ] || continue
        if g rev-parse -q --verify "refs/remotes/origin/$b^{commit}" >/dev/null 2>&1; then
            PROT_REF="refs/remotes/origin/$b"; break
        fi
    done
    [ -n "$PROT_REF" ] || die "origin is configured, but none of origin/HEAD, origin/main, origin/master is fetched.
   The hooks are installed from the protected branch on origin, not from this tree.
   Run: git fetch origin   — then run this script again."
fi

MODE=bootstrap
if [ -n "$PROT_REF" ] && g cat-file -e "$PROT_REF:githooks/pre-push" 2>/dev/null; then
    MODE=origin
fi

mkdir -p "$DEST"
if [ "$MODE" = origin ]; then
    SRC_SHA=$(g rev-parse "$PROT_REF^{commit}")
    echo "  source: ${PROT_REF#refs/remotes/} ($SRC_SHA)"
else
    SRC_SHA=$(g rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || echo none)
    echo "  ⚠️  first install: hooks come from this working tree ($ROOT)."
    echo "     After git-guards is merged into the protected branch, hooks will be installed from origin."
fi

for h in $HOOKS; do
    dst="$DEST/$h"; tmp="$dst.tmp.$$"
    if [ "$MODE" = origin ]; then
        if ! g cat-file -e "$PROT_REF:githooks/$h" 2>/dev/null; then
            # An older kit on origin that has no such file: install what origin has.
            echo "  - $h not on ${PROT_REF#refs/remotes/} — skipped"
            continue
        fi
        g show "$PROT_REF:githooks/$h" > "$tmp" 2>/dev/null \
            || { rm -f "$tmp"; die "githooks/$h exists on ${PROT_REF#refs/remotes/} but git show failed"; }
    else
        src="$ROOT/githooks/$h"
        if [ ! -f "$src" ]; then
            echo "  - $h not in this tree — skipped"
            continue
        fi
        cp "$src" "$tmp"
    fi
    if [ -f "$dst" ] && [ -x "$dst" ] && cmp -s "$tmp" "$dst"; then
        rm -f "$tmp"
        echo "  = $h unchanged"
    else
        chmod +x "$tmp"; mv "$tmp" "$dst"   # atomic swap
        echo "  + $h installed"
    fi
    shasum -a 256 "$dst" | cut -d' ' -f1 > "$DEST/$h.sha256"
done

printf '%s@%s\n' "$MODE" "$SRC_SHA" > "$DEST/.source.tmp.$$" && mv "$DEST/.source.tmp.$$" "$DEST/.source"

g config core.hooksPath "$DEST"
echo "  core.hooksPath = $DEST"
echo "Done. Check: scripts/git-lock.sh status"
