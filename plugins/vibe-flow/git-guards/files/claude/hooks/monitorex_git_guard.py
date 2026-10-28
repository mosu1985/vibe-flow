#!/usr/bin/env python3
"""PreToolUse-guard: запрет стейджинга и коммита в общем рабочем дереве.

Отдельный файл, а не heredoc внутри shell: при `python3 - <<EOF` heredoc
занимает stdin, и полезный ввод хука до скрипта не доходит.

Полное обоснование — в monitorex-git-guard.sh рядом.
"""

import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "scripts", "git-guards"))
raw = sys.stdin.read()


def allow():
    sys.exit(0)


try:
    payload = json.loads(raw)
except Exception:
    allow()

if payload.get("tool_name") != "Bash":
    allow()

cmd = (payload.get("tool_input") or {}).get("command") or ""
cwd = payload.get("cwd") or os.getcwd()
if not cmd.strip():
    allow()

try:
    from shell_segments import (parse, strip_env_prefix, safe_split,
                                first_word, basename_matches)
    detail = parse(cmd)["segments_detail"]
    segments = [s["segment"] for s in detail]
except Exception:
    allow()

GUARDED = ("add", "commit")
# Флаги git, забирающие следующее слово как значение.
TAKES_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}


def guarded_target(seg: str):
    """(хит 'git add'/'git commit', [значения -C по порядку], есть ли
    --git-dir/--work-tree) — если сегмент ЭТО И ЕСТЬ, иначе None.

    🔴 Первая версия искала слово "git" где угодно в сегменте — и хук
    отклонял `echo "git commit"`, где эти слова просто текст. Он заблокировал
    собственную диагностику, а потом и попытку себя починить. Ложный отказ на
    законной работе опаснее пропуска: от него защиту сносят целиком.

    Поэтому `git` обязан стоять В ПОЗИЦИИ КОМАНДЫ (после возможного префикса
    `VAR=1`), а флаги со значениями пропускаются, чтобы `git -C dir add`
    распознавался как `add`, а не как путь `dir`.

    Значения `-C` возвращаются, чтобы решать по дереву, где git РЕАЛЬНО
    выполнится, а не по cwd сессии (25.10.2026): `git -C <worktree> add` из
    основного дерева — работа в своём worktree, а не в общем индексе, и
    раньше она ложно отклонялась.
    """
    body = strip_env_prefix(seg)
    head = first_word(body)
    if not head or not basename_matches(head, "git"):
        return None
    words = safe_split(body)[1:]
    c_dirs, explicit = [], False
    i = 0
    while i < len(words):
        w = words[i]
        if w in TAKES_VALUE:
            if w == "-C" and i + 1 < len(words):
                c_dirs.append(words[i + 1])
            if w in ("--git-dir", "--work-tree"):
                explicit = True
            i += 2
            continue
        if w.startswith("--git-dir=") or w.startswith("--work-tree="):
            explicit = True
        if w.startswith("-"):
            i += 1
            continue
        return (f"git {w}", c_dirs, explicit) if w in GUARDED else None
    return None


# Скрипты осознанных обходов. Отметку ставит ЧЕЛОВЕК — ради этого у них вопрос
# «да/нет». Но вопрос от агента не защищает: `echo да | git-allow-delete.sh add`
# проходит молча. Поэтому режимы, СТАВЯЩИЕ отметку, модели запрещены в любом
# дереве (отметки лежат в общем $GIT_COMMON_DIR). Чтение и снятие — можно.
# Человеку хук не мешает: команды, набранные через `!`, идут мимо PreToolUse.
OWNER_MARK_SAFE_MODES = {
    "git-confirm.sh": {"status", "clear"},
    "git-allow-push.sh": {"list", "clear"},
    "git-allow-delete.sh": {"list", "clear"},
    # pass разрешён здесь, но отдельно проверяется ниже: только агент release-gate
    "release-gate.sh": {"scope", "status", "pass"},
}
SHELLS = {"bash", "sh", "zsh"}
# Флаги скриптов отметок, забирающие следующее слово как значение.
MARK_VALUE_FLAGS = {"--report", "--head"}
MARK_VALUE_SAFE = re.compile(r"[A-Za-z0-9._/@:+%=-]+")
# Обёртки, после которых идёт настоящая команда: `env X=1 cmd`, `nohup cmd`.
# Без их снятия `nohup scripts/git-confirm.sh commit` проходил мимо проверки.
WRAPPERS = {"env", "command", "nohup", "time", "exec", "builtin", "xargs"}
# Флаги обёрток, забирающие следующее слово: `env -u VAR cmd`, `exec -a имя cmd`.
WRAPPER_VALUE_FLAGS = {"-u", "--unset", "-C", "--chdir", "-S", "-a", "-I", "-n", "-L", "-P"}


def basename(word: str) -> str:
    return word.rstrip("/").split("/")[-1]


def command_words(seg: str) -> list[str]:
    """Слова сегмента, начиная с настоящей команды — без VAR=, shell и обёрток."""
    words = safe_split(strip_env_prefix(seg))
    while words:
        head = basename(words[0])
        if head not in SHELLS and head not in WRAPPERS:
            break
        words = words[1:]
        while words and (words[0].startswith("-")
                         or (head in WRAPPERS and "=" in words[0])):
            takes = head in WRAPPERS and words[0] in WRAPPER_VALUE_FLAGS
            words = words[2:] if takes else words[1:]
    return words


def is_owner_mark(seg: str) -> str | None:
    """Вернуть имя скрипта, если сегмент ставит owner-отметку."""
    words = command_words(seg)
    if not words:
        return None
    name = words[0].rstrip("/").split("/")[-1]
    if name not in OWNER_MARK_SAFE_MODES:
        return None
    # Значения флагов (`--report r.md`) — не режим: иначе `r.md` в позиции
    # режима давал ложный отказ на законном `status`.
    args, rest = [], words[1:]
    while rest:
        # Значение пропускаем, только если оболочка его не развернёт в
        # несколько слов: `--head $X scope`, `--head {a,override} scope` bash
        # превращает в режим override. Белый список, а не перечень опасного.
        if (name == "release-gate.sh" and rest[0] in MARK_VALUE_FLAGS
                and len(rest) > 1 and MARK_VALUE_SAFE.fullmatch(rest[1])):
            rest = rest[2:]
            continue
        if not rest[0].startswith("-"):
            args.append(rest[0])
        rest = rest[1:]
    if not args:
        return None                  # без аргументов скрипт только показывает
    return None if args[0] in OWNER_MARK_SAFE_MODES[name] else name


mark = next((m for s in segments if (m := is_owner_mark(s))), None)
if mark:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": f"""🔴 `{mark}` ставит отметку обхода защиты — это решение человека, не агента.

Покажите пользователю, что именно будет разрешено и зачем, и попросите
запустить команду самому — в строке ввода Claude Code через `!` с флагом
--yes (там на вопрос ответить нечем) или в обычном терминале без флага.
Хук этого не заметит: команды через `!` идут мимо PreToolUse.

Смотреть и снимать отметки агенту можно: list / status / clear.""",
    }}, ensure_ascii=False))
    sys.exit(0)


# Вердикт release-gate ставит только сам ревьюер. Иначе основная сессия,
# которой гейт мешает запушить, «одобрила» бы собственный код одной строкой.
# Внутри субагента хук получает agent_type — по нему и отличаем.
# Имя агента: свой файл в .claude/agents → `release-gate`; из плагина
# vibe-flow → `vibe-flow:release-gate` (плагинные агенты получают префикс).
GATE_AGENTS = {"release-gate", "vibe-flow:release-gate"}
GATE_PATH = "monitorex-locks/release-gate"
# Команды, которые пишут в файлы-аргументы. echo/printf сюда не входят: они
# пишут в stdout, а их запись в файл — это перенаправление, оно ловится ниже.
WRITERS = {"cp", "mv", "tee", "touch", "ln", "install", "rsync", "dd"}
# Перенаправление ИМЕННО в каталог вердиктов (`>`, `>>`, `>|`). Любой `>`
# (2>/dev/null, 2>&1) давал ложный отказ на чтении — а от ложных отказов
# защиту сносят целиком.
GATE_REDIRECT = re.compile(r">[>|]?\s*['\"]?[^\s;|&'\"]*" + re.escape(GATE_PATH))


def gate_violation(seg: str) -> str | None:
    words = command_words(seg)
    if not words:
        return None
    name = basename(words[0])
    if name == "release-gate.sh":
        # Режим ищем среди ВСЕХ слов, а не первым аргументом: скрипт забирает
        # слово после --report/--head как значение, и `--report scope pass …`
        # для него — режим pass, а для «первого слова без -» — безобидный scope.
        rest = set(words[1:])
        # Обход — решение человека даже для самого ревьюера.
        if "override" in rest:
            return "pass"
        if "pass" in rest and payload.get("agent_type") not in GATE_AGENTS:
            return "pass"
    # Запись в каталог вердиктов мимо скрипта — при любом первом слове, даже
    # `release-gate.sh status > …/<tree>`. Чтение (ls, cat, grep) — можно.
    if GATE_REDIRECT.search(seg):
        return "write"
    # Любой аргумент с путём каталога — даже если это источник (`cp gate/x /tmp`).
    # Различать источник и получателя пробовали (28.10): хвостовой `2>/dev/null`
    # становился «последним аргументом», и `cp /tmp/v gate/<tree> 2>/dev/null`
    # проходил. Ложный отказ на копировании вердикта наружу дешевле.
    if name in WRITERS and any(GATE_PATH in w for w in words[1:]):
        return "write"
    return None


gate = next((g for s in segments if (g := gate_violation(s))), None)
if gate:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": """🔴 Вердикт release-gate ставит только агент `release-gate` — ревьюер на Opus.

Основная сессия не может одобрить собственный код: в этом весь смысл гейта.
Запустите агента release-gate на текущем дереве. Если он вернул замечания —
исправьте их, закоммитьте и запустите его снова.

Обход без ревью — решение человека: попросите пользователя запустить
`! scripts/release-gate.sh override --yes`.""",
    }}, ensure_ascii=False))
    sys.exit(0)

# `git push --no-verify` выключает pre-push целиком: typecheck, барьеры
# параллельных сессий и release-gate разом. Человеку можно (через `!` хук не
# срабатывает), модели — нет. Тот же обход — подмена core.hooksPath: через
# `-c`, `--config-env`, переменные GIT_CONFIG_* или `git config` заранее.
# Закрыты прямые формы; косвенные (include.path, --remove-section core,
# правка .git/config руками) PreToolUse не поймать — их видно в ревью.
HOOKS_PATH = re.compile(r"hooks?path", re.I)
GIT_CONFIG_ENV = re.compile(r"GIT_CONFIG_(COUNT|KEY_\w*|VALUE_\w*|PARAMETERS|GLOBAL|SYSTEM)=")
CONFIG_WRITE_FLAGS = {"--unset", "--unset-all", "--add", "--replace-all", "--edit", "-e"}
CONFIG_READ_FLAGS = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l"}
CONFIG_VALUE_FLAGS = {"-f", "--file", "--blob", "--type", "--default", "--comment"}
ENV_SETTERS = {"export", "declare", "typeset", "env"}


def git_config_env(seg_text: str) -> bool:
    """GIT_CONFIG_* задан как окружение: префиксом `X=… git` или export/env."""
    toks = safe_split(seg_text)
    head = []
    for t in toks:
        if basename(t) == "git":
            break
        head.append(t)
    if any(GIT_CONFIG_ENV.match(t) for t in head):
        return True
    return bool(toks) and toks[0] in ENV_SETTERS and any(GIT_CONFIG_ENV.match(t) for t in toks[1:])


def push_bypass(seg: str) -> bool:
    words = command_words(seg)
    if not words or basename(words[0]) != "git":
        return False
    rest, conf = words[1:], []     # conf — только значения -c/--config-env, не путь -C
    while rest and rest[0].startswith("-"):
        w = rest[0]
        if w in ("-c", "--config-env"):
            conf.extend(rest[1:2])
        elif w.startswith("-c") or w.startswith("--config-env="):
            conf.append(w)
        if w in TAKES_VALUE or w == "--config-env":
            rest = rest[2:]
        else:
            rest = rest[1:]
    if not rest:
        return False
    sub, args = rest[0], rest[1:]
    if sub == "config":
        # Чтение (`git config --get core.hooksPath`, `git config get …`) — можно.
        if not any(HOOKS_PATH.search(a) for a in args):
            return False
        pos, i = [], 0
        while i < len(args):
            if args[i] in CONFIG_VALUE_FLAGS:
                i += 2
                continue
            if not args[i].startswith("-"):
                pos.append(args[i])
            i += 1
        if CONFIG_READ_FLAGS & set(args) or pos[:1] in (["get"], ["list"]):
            return False
        return (len(pos) >= 2 or bool(CONFIG_WRITE_FLAGS & set(args))
                or pos[:1] in (["set"], ["unset"]))
    if sub != "push":
        return False
    if any(HOOKS_PATH.search(w) for w in conf):
        return True
    if git_config_env(seg) or any(git_config_env(s) for s in segments):
        return True
    # git принимает сокращения длинных опций: `--no-verif` = `--no-verify`.
    return any(len(w) >= 6 and "--no-verify".startswith(w) for w in args)


if any(push_bypass(s) for s in segments):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": """🔴 `git push` в обход pre-push (--no-verify / подмена core.hooksPath) модели запрещён.

Он выключает разом проверку типов, барьеры параллельных сессий и release-gate —
код уйдёт непроверенным. Пусть хук отработает; отказ означает, что есть что
чинить (или запустить агента release-gate).

Удаление ветки на remote — через `gh api -X DELETE …/git/refs/heads/<ветка>`.
Осознанный обход — решение человека: попросите пользователя выполнить push
сам через `! git push --no-verify …` и объясните, что именно пропускается.""",
    }}, ensure_ascii=False))
    sys.exit(0)


def git(where: str, *args) -> str:
    return subprocess.run(("git", "-C", where) + args, capture_output=True,
                          text=True, timeout=5).stdout.strip()


def is_linked_worktree(where: str) -> bool | None:
    """True — linked worktree (свой индекс), False — общее дерево,
    None — не репозиторий (такой git сам упадёт, блокировать нечего)."""
    if not os.path.isdir(where):
        return False                 # каталога нет — безопасная сторона
    gd = git(where, "rev-parse", "--git-dir")
    if not gd:
        return None
    return gd != git(where, "rev-parse", "--git-common-dir")


def resolve(base: str, path: str) -> str:
    path = os.path.expanduser(path)
    return os.path.normpath(path if os.path.isabs(path) else os.path.join(base, path))


def target_dirs(candidates, c_dirs):
    """Все каталоги, где может выполниться git этого сегмента.
    None в списке — каталог не вычислить (cd $VAR и т.п.)."""
    out = []
    for cand in candidates or [{"cd_dir": None, "cd_ambiguous": False}]:
        if cand.get("cd_ambiguous"):
            out.append(None)
            continue
        where = resolve(cwd, cand["cd_dir"]) if cand.get("cd_dir") else cwd
        for c in c_dirs:            # `-C a -C b` — относительные складываются
            where = resolve(where, c)
        out.append(where)
    return out


hit = None
for d in detail:
    g = guarded_target(d["segment"])
    if not g:
        continue
    name, c_dirs, explicit = g
    if explicit:                     # --git-dir/--work-tree: не гадаем
        hit = name
        break
    for where in target_dirs(d.get("cwd_candidates"), c_dirs):
        state = None if where is None else is_linked_worktree(where)
        # Разрешено, только если КАЖДЫЙ возможный каталог — linked worktree
        # (или вовсе не репозиторий). Неизвестный каталог → общее дерево.
        if where is None or state is False:
            hit = name
            break
    if hit:
        break

if not hit:
    allow()

reason = f"""🔴 `{hit}` в общем рабочем дереве запрещён.

Индекс git здесь ОБЩИЙ для всех параллельных сессий: застейдженные файлы
уезжают в чужой коммит за секунды (так уже было 2026-08-06 — 7 файлов
security-фикса ушли в коммит про вёрстку фильтров).

Коммитить так:
  scripts/git-safe-commit.sh --message-file <файл> -- <пути>

Он собирает коммит в изолированном индексе и двигает ветку атомарно.
Нужен частичный стейджинг — работайте в отдельном worktree:
  scripts/wt-new.sh <имя>

Разовый осознанный обход (человеком, с подтверждением):
  scripts/git-confirm.sh commit"""

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": reason,
}}, ensure_ascii=False))
