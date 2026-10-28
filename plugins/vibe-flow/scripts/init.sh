#!/usr/bin/env bash
# init.sh [путь-к-проекту] [--no-gate] — развернуть vibe-flow в проекте.
#
# Делает механическую часть, одинаковую у всех:
#   1. git-guards: скрипты worktree/коммита, git-хуки, PreToolUse-хук Claude Code
#   2. флаг финального гейта release-gate в .gitguards.conf
#   3. блок правил vibe-flow в CLAUDE.md (между метками — обновляется повторным запуском)
# Раздел «Проект» в CLAUDE.md (стек, команды) пишет модель по скиллу init —
# там нужно суждение, а не шаблон.
#
# Идемпотентен: повторный запуск обновляет файлы git-guards и блок правил,
# но не трогает существующий .gitguards.conf и текст CLAUDE.md вне меток.
set -eu

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$PWD"; GATE=1
for a in "$@"; do
    case "$a" in
      --no-gate) GATE=0 ;;
      -*) echo "неизвестный флаг: $a" >&2; exit 2 ;;
      *) TARGET="$a" ;;
    esac
done
TARGET="$(cd "$TARGET" && pwd)"

die() { printf '\n🔴 %s\n' "$*" >&2; exit 1; }

for bin in git python3; do
    command -v "$bin" >/dev/null 2>&1 || die "нужен $bin — установите его и запустите снова"
done
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 \
    || die "$TARGET — не git-репозиторий. Сначала: git init && git add -A && git commit -m init"
git -C "$TARGET" rev-parse --verify -q HEAD >/dev/null \
    || die "в репозитории нет ни одного коммита — сделайте первый коммит и запустите снова"

VERSION=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("version","dev"))' \
    "$PLUGIN/.claude-plugin/plugin.json")

# ── 1. git-guards ────────────────────────────────────────────────────────────
GG_EMBEDDED=1 bash "$PLUGIN/git-guards/install.sh" "$TARGET"

# ── 2. финальный гейт ────────────────────────────────────────────────────────
CONF="$TARGET/.gitguards.conf"
printf '\n\033[1m%s\033[0m\n' "vibe-flow: финальный гейт"
if grep -q '^GG_RELEASE_GATE=' "$CONF" 2>/dev/null; then
    echo "  = GG_RELEASE_GATE уже задан: $(grep '^GG_RELEASE_GATE=' "$CONF" | tail -1)"
else
    {
        echo ""
        echo "# Финальное ревью vibe-flow:release-gate (Opus) перед push: без вердикта"
        echo "# pre-push откажет. 0 — выключить. Маска файлов, которым ревью не нужно."
        echo "GG_RELEASE_GATE=$GATE"
        echo 'GG_RELEASE_GATE_SKIP="*.md"'
    } >> "$CONF"
    echo "  + GG_RELEASE_GATE=$GATE"
fi

# ── 3. CLAUDE.md ─────────────────────────────────────────────────────────────
printf '\n\033[1m%s\033[0m\n' "vibe-flow: CLAUDE.md"
python3 - "$TARGET/CLAUDE.md" "$PLUGIN/templates/CLAUDE.flow.md" "$VERSION" <<'PY'
import os, re, sys
path, tpl, version = sys.argv[1:4]
block = (f"<!-- vibe-flow:begin v{version} -->\n"
         + open(tpl, encoding="utf-8").read().rstrip() + "\n"
         + "<!-- vibe-flow:end -->")
text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
pat = re.compile(r"<!-- vibe-flow:begin[^>]*-->.*?<!-- vibe-flow:end -->", re.S)
if pat.search(text):
    new, how = pat.sub(lambda _: block, text, count=1), "обновлён"
elif text.strip():
    new, how = text.rstrip() + "\n\n" + block + "\n", "добавлен в конец"
else:
    new, how = "# Правила проекта\n\n" + block + "\n", "создан"
if new != text:
    open(path, "w", encoding="utf-8").write(new)
    print(f"  + блок правил {how} (v{version})")
else:
    print(f"  = блок правил актуален (v{version})")
has_project = "<!-- vibe-flow:project:begin -->" in new
print("  = раздел «Проект» есть" if has_project else "  ! раздела «Проект» нет — его заполнит /vibe-flow:init")
PY

printf '\n✅ vibe-flow %s развёрнут в %s\n' "$VERSION" "$TARGET"
