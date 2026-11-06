#!/usr/bin/env bash
# git-recovery.sh — lifecycle of refs/monitorex/recovery/*.
# These refs hold commits that did not land on the branch because of a CAS conflict.
# Unless explicitly deleted, they keep their trees from garbage collection forever.
set -eu
case "${1:-list}" in
  list)
    git for-each-ref --format='%(refname:short)  %(objectname:short)  %(committerdate:iso)  %(contents:subject)' refs/monitorex/recovery \
      | sed 's/^/  /' ; git for-each-ref refs/monitorex/recovery | grep -q . || echo "  (empty)" ;;
  show) [ $# -ge 2 ] || { echo "token required"; exit 2; }; git show --stat "refs/monitorex/recovery/$2" ;;
  drop)
    [ $# -ge 2 ] || { echo "token required"; exit 2; }
    git show --stat "refs/monitorex/recovery/$2" | head -20
    printf '\nDelete this ref? The commit will become unreachable. [yes/no] '
    read -r a; { [ "$a" = "yes" ] || [ "$a" = "да" ]; } || { echo "cancelled"; exit 1; }  # "да" kept for existing Russian-speaking users
    git update-ref -d "refs/monitorex/recovery/$2"; echo "deleted" ;;
  *) echo "usage: git-recovery.sh [list|show <token>|drop <token>]"; exit 2 ;;
esac
