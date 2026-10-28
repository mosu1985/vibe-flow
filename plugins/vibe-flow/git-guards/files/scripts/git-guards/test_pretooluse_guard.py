#!/usr/bin/env python3
"""Тесты PreToolUse-guard: что он блокирует, а что обязан пропускать.

Ложный отказ здесь опаснее пропуска — от него защиту сносят целиком, вместе
с настоящей пользой. Первая версия хука отклоняла `echo "…"` с этими словами
внутри и заблокировала собственную починку, поэтому набор кейсов ниже —
в основном про то, что пропускать ОБЯЗАНО.

Запуск: python3 scripts/git-guards/test_pretooluse_guard.py
"""

import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOOK = os.path.join(ROOT, ".claude", "hooks", "monitorex-git-guard.sh")

STAGE = "git" + " add"          # собираем из кусков, иначе хук блокирует
COMMIT = "git" + " commit"      # запуск самих тестов

CASES = [
    # (команда, ожидаем ли deny)
    (f"{STAGE} lib/x.ts", True),
    (f"{COMMIT} -m x", True),
    ("git -C {MAIN} add f.ts", True),
    (f"MONITOREX_ACTOR=x {STAGE} f.ts", True),
    (f"npm test && {STAGE} f.ts", True),
    # --- отметки обхода ставит только человек ---
    ("scripts/git-allow-delete.sh add a.txt", True),
    ("echo да | scripts/git-allow-delete.sh add a.txt", True),
    ("bash scripts/git-allow-push.sh add abc123", True),
    (f"cd {ROOT} && ./scripts/git-confirm.sh commit", True),
    ("sh -c 'echo да | scripts/git-confirm.sh commit'", True),
    ("MONITOREX_ACTOR=x scripts/git-allow-delete.sh add --yes a.txt", True),
    # --- обязаны пройти ---
    (f'echo "=== {COMMIT} прямо сейчас ==="', False),
    (f"echo {STAGE} | grep git", False),
    ("git status", False),
    ("git log --oneline -5", False),
    ("git diff --cached", False),
    ("git rev-parse HEAD", False),
    ("ls -la", False),
    (f"grep -rn '{STAGE}' docs/", False),
    ("scripts/git-allow-delete.sh list", False),
    ("scripts/git-allow-push.sh", False),
    ("scripts/git-confirm.sh status", False),
    ("scripts/git-confirm.sh clear", False),
    ("grep -n add scripts/git-allow-delete.sh", False),
    ("bash -n scripts/git-allow-push.sh", False),
    ("echo 'scripts/git-confirm.sh commit'", False),
    # --- release-gate: вердикт ставит только агент release-gate ---
    ("scripts/release-gate.sh override", True),
    ("scripts/release-gate.sh override --yes", True),
    ("scripts/release-gate.sh pass --report /tmp/r.md", True),       # основная сессия
    ("bash scripts/release-gate.sh pass --report r.md", True),
    ("echo pass > .git/monitorex-locks/release-gate/abc", True),
    ("touch .git/monitorex-locks/release-gate/abc", True),
    ("scripts/release-gate.sh", False),
    ("scripts/release-gate.sh scope", False),
    ("scripts/release-gate.sh status", False),
    ("ls .git/monitorex-locks/release-gate", False),
    ("cat .git/monitorex-locks/release-gate/abc", False),
    ("grep -n pass scripts/release-gate.sh", False),
    # обёртки и запись мимо скрипта (находки release-gate, круг 1)
    ("env X=1 scripts/release-gate.sh pass --head HEAD --report r.md", True),
    ("command scripts/release-gate.sh pass --head HEAD --report r.md", True),
    ("nohup scripts/release-gate.sh pass --head HEAD --report r.md", True),
    ("scripts/release-gate.sh status > .git/monitorex-locks/release-gate/abc", True),
    ("cp r.md .git/monitorex-locks/release-gate/abc", True),
    ("printf x >> .git/monitorex-locks/release-gate/abc", True),
    # чтение с перенаправлением stderr/stdout — НЕ запись в гейт
    ("ls .git/monitorex-locks/release-gate 2>/dev/null", False),
    ("ls .git/monitorex-locks/release-gate 2>&1 | head", False),
    ("cat .git/monitorex-locks/release-gate/abc > /tmp/copy", False),
    ("echo 'see monitorex-locks/release-gate dir'", False),
    ("cp a.ts /Users/x/bomond-wt/release-gate/lib/a.ts", False),   # дерево с таким именем
    # обход человека через обёртки (находки release-gate, круг 2)
    ("env X=1 scripts/release-gate.sh override --yes", True),
    ("nohup scripts/release-gate.sh override --yes", True),
    ("command scripts/release-gate.sh override --yes", True),
    ("env -u HOME scripts/release-gate.sh override --yes", True),
    ("nohup scripts/git-confirm.sh commit", True),
    ("env scripts/git-allow-push.sh add abc123", True),
    ("echo r.md | xargs scripts/release-gate.sh pass --head HEAD --report", True),
    ("printf x >| .git/monitorex-locks/release-gate/abc", True),
    ("env scripts/release-gate.sh status", False),
    # push в обход pre-push — только человеку
    ("git push --no-verify origin HEAD", True),
    ("git push origin HEAD --no-verify", True),
    ("git -C /tmp/wt push --no-verify", True),
    ("env X=1 git push --no-verify", True),
    ("git -c core.hooksPath=/dev/null push origin HEAD", True),
    ("git -ccore.hooksPath=/dev/null push", True),
    ("git push origin HEAD", False),
    ("git push -u origin wt/x", False),
    ("git push -n origin HEAD", False),
    ('echo "git push --no-verify"', False),
    # находки release-gate, круг 3
    ("scripts/release-gate.sh --report scope pass --head abc --report r.md", True),
    ("scripts/release-gate.sh --report status override --yes", True),
    ("scripts/release-gate.sh --report r.md status", False),
    ("git push --no-verif origin HEAD", True),
    ("git push --no-veri", True),
    ("GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/x git push", True),
    ("export GIT_CONFIG_PARAMETERS=x; git push", True),
    ("git --config-env=core.hooksPath=HP push", True),
    ("git config core.hooksPath /dev/null", True),
    ("git config --local core.hookspath /tmp/none", True),
    ("git config --unset core.hooksPath", True),
    ("git config --get core.hooksPath", False),
    ("git config core.hooksPath", False),
    ("git push --no-thin origin HEAD", False),
    # находки release-gate (hardening, круг 1): запись вердикта с редиректами
    ("cp /tmp/v .git/monitorex-locks/release-gate/abc 2>/dev/null", True),
    ("tee < /tmp/v .git/monitorex-locks/release-gate/abc", True),
    ("tee <<< 'verdict=pass' .git/monitorex-locks/release-gate/abc", True),
    ("cat /tmp/v | tee '' .git/monitorex-locks/release-gate/abc", True),
    ("mv /tmp/v .git/monitorex-locks/release-gate/abc 2>&1", True),
    ("cp /tmp/v .git/monitorex-locks/release-gate/abc &>/dev/null", True),
    ("cp /tmp/v .git/monitorex-locks/release-gate/abc 2> /dev/null", True),
    ('X="a override"; scripts/release-gate.sh --head $X scope --yes', True),
    ("scripts/release-gate.sh --head `echo a override` scope", True),
    ("scripts/release-gate.sh --head {a,override} scope --yes", True),
    ("scripts/release-gate.sh --report {r.md,pass} --head abc", True),
    ("scripts/release-gate.sh --report * status", True),
    ("scripts/release-gate.sh --report /tmp/claude-501/r_3.md status", False),
    ("git config get core.hooksPath", False),
    ("git config --file .git/config --get core.hooksPath", False),
    ("git config -f .git/config.worktree --get core.hooksPath", False),
    ("git config --type path --get core.hooksPath", False),
    ("git config --list --show-origin", False),
    ("grep -rn GIT_CONFIG_GLOBAL scripts && git push origin HEAD", False),
    ("git push origin HEAD; echo GIT_CONFIG_SYSTEM", False),
    ("git -C /tmp/webhookpath-fix push origin HEAD", False),
    ("GIT_CONFIG_GLOBAL=/tmp/g git push", True),
    ("cp /tmp/x .git/monitorex-locks/release-gate/abc", True),
    ("tee .git/monitorex-locks/release-gate/abc < /tmp/x", True),
    ("grep -n no-verify CLAUDE.md", False),
]

# (команда, agent_type, ожидаем ли deny) — вызовы изнутри субагента
AGENT_CASES = [
    ("scripts/release-gate.sh pass --report r.md", "release-gate", False),
    ("scripts/release-gate.sh pass --report r.md", "general-purpose", True),
    ("scripts/release-gate.sh pass --report r.md", "vibe-flow:release-gate", False),
    ("scripts/release-gate.sh pass --report r.md", "evil:release-gate", True),
    ("scripts/release-gate.sh pass --report r.md", "senior-backend-engineer", True),
    ("scripts/release-gate.sh override --yes", "release-gate", True),   # обход — человеку
    ("touch .git/monitorex-locks/release-gate/abc", "release-gate", True),  # мимо скрипта
    ("ls .git/monitorex-locks/release-gate 2>&1 | head", "release-gate", False),
    ("env scripts/release-gate.sh override --yes", "release-gate", True),
    ("git push --no-verify", "release-gate", True),
    ("cp /tmp/v .git/monitorex-locks/release-gate/abc 2>/dev/null", "release-gate", True),
]


def run(cmd: str, cwd: str = ROOT, agent_type: str | None = None) -> bool:
    body = {
        "tool_name": "Bash",
        "tool_input": {"command": cmd},
        "cwd": cwd,
    }
    if agent_type:
        body.update(agent_id="test-agent", agent_type=agent_type)
    payload = json.dumps(body)
    out = subprocess.run(["bash", HOOK], input=payload, capture_output=True,
                         text=True, timeout=20).stdout.strip()
    return bool(out)


def worktree_cases(tmp: str):
    """Решение — по дереву, где git РЕАЛЬНО выполнится (25.10.2026).

    Сессия всегда стоит в основном дереве, а работа идёт в своём worktree:
    `git -C <wt> add` раньше ложно отклонялся, и merge-коммит после
    конфликтов агент сделать не мог. Основное дерево по-прежнему закрыто.
    """
    main = os.path.join(tmp, "main")
    wt = os.path.join(tmp, "wt")
    sh = lambda *a: subprocess.run(a, capture_output=True, check=True)
    sh("git", "init", "-q", main)
    sh("git", "-C", main, "-c", "user.email=t@t", "-c", "user.name=t",
       "commit", "-q", "--allow-empty", "-m", "init")
    sh("git", "-C", main, "worktree", "add", "-q", wt, "-b", "wtb")
    return main, [
        (f"git -C {wt} add f.ts", False),
        (f"git -C {wt} commit --no-edit", False),
        (f"cd {wt} && {STAGE} f.ts", False),
        (f"cd {wt} && npm test && {COMMIT} -m x", False),
        (f"cd {wt}; {STAGE} -A", False),
        (f"git -C {tmp} -C wt add f.ts", False),           # -C складываются
        (f"git -C {main} add f.ts", True),
        (f"{STAGE} f.ts", True),                           # cwd сессии = main
        (f"(cd {wt}) && {STAGE} f.ts", True),              # подоболочка не меняет cwd
        (f"cd $WT && {STAGE} f.ts", True),                 # не вычислить → запрет
        (f"git --git-dir={wt}/.git add f.ts", True),       # явный git-dir не угадываем
        (f"git -C {tmp}/nope add f.ts", True),             # каталога нет
        (f"cd {wt} && {STAGE} f && cd {main} && {COMMIT} -m x", True),
    ]


def main() -> int:
    ok = fail = 0
    tmp = tempfile.mkdtemp(prefix="guard-wt-")
    main_repo, wt_cases = worktree_cases(os.path.realpath(tmp))
    # Базовые кейсы — тоже против временного ОСНОВНОГО дерева: раньше cwd был
    # ROOT, и при запуске из worktree проекта они ложно «проваливались».
    cases = [(c.replace("{MAIN}", main_repo), d, main_repo, None) for c, d in CASES]
    cases += [(c, d, main_repo, None) for c, d in wt_cases]
    cases += [(c, d, main_repo, a) for c, a, d in AGENT_CASES]
    for cmd, want_deny, cwd, agent in cases:
        got = run(cmd, cwd, agent)
        label = ("deny " if want_deny else "allow") + (f" [{agent}]" if agent else "")
        if got == want_deny:
            ok += 1
            print(f"  ok   - {label} | {cmd}")
        else:
            fail += 1
            print(f"  FAIL - ожидался {label}, получен "
                  f"{'deny' if got else 'allow'} | {cmd}")
    print(f"\n  прошло: {ok}   провалено: {fail}")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
