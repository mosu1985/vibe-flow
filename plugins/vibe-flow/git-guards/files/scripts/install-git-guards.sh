#!/usr/bin/env bash
# install-git-guards.sh — installs the canonical hooks OUTSIDE the working tree.
#
# Why not .husky: husky resolves the hook relative to the current checkout.
# A worktree on an old base, or switching the main working tree to a revision
# from before the guard existed, would hand git the OLD version of the hook —
# without any of its checks. A directory in git-common-dir does not depend on checkouts.
#
# Idempotent: identical content is left alone, different content is overwritten.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
COMMON=$(git -C "$ROOT" rev-parse --git-common-dir)
case "$COMMON" in /*) ;; *) COMMON="$(cd "$ROOT/$COMMON" && pwd -P)" ;; esac
DEST="$COMMON/monitorex-hooks"
mkdir -p "$DEST"

for h in pre-commit pre-push; do
    src="$ROOT/githooks/$h"; dst="$DEST/$h"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        echo "  = $h unchanged"
    else
        tmp="$dst.tmp.$$"
        cp "$src" "$tmp"; chmod +x "$tmp"; mv "$tmp" "$dst"   # atomic swap
        echo "  + $h installed"
    fi
    shasum -a 256 "$src" | cut -d' ' -f1 > "$DEST/$h.sha256"
done

git -C "$ROOT" config core.hooksPath "$DEST"
echo "  core.hooksPath = $DEST"
echo "Done. Check: scripts/git-lock.sh status"
