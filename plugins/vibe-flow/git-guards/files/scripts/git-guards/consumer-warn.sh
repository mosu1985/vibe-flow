#!/usr/bin/env bash
# consumer-warn.sh — a warning (NOT a rejection) about a new exporting module
# that nothing references. Covers part of incident #3, "dead code in
# production": typecheck accepts correctly typed code that has no consumers.
# It must not block: there are legitimate cases (a module behind a flag, a cron entry point).
set -eu
COMMIT="$1"; shift
for p in "$@"; do
  case "$p" in lib/*|components/*) ;; *) continue ;; esac
  [ -f "$p" ] || continue
  git cat-file -e "$COMMIT^:$p" 2>/dev/null && continue      # not a new file
  grep -qE '^export ' "$p" 2>/dev/null || continue
  base="${p%.*}"; stem="${base##*/}"
  if ! grep -rqE "from ['\"].*${stem}['\"]|require\(['\"].*${stem}" \
        --include='*.ts' --include='*.tsx' app lib components 2>/dev/null; then
    printf '⚠️  new module with no consumers: %s\n' "$p" >&2
    printf '   Is it wired into a route/component/cron? (incident #3: dead code in production)\n' >&2
  fi
done
