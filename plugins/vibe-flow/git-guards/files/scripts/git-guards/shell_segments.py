# ВЕНДОРЕНО из session-coordination-kit v1.0 (автор: Pavlo Rudomotov),
# получено 2026-09-02. Модель «множества возможных cwd» переписывалась
# четыре раза по итогам независимого аудита — не переписывать своё,
# при обновлении набора сверять с оригиналом.
#!/usr/bin/env python3
"""
shell_segments.py — общий quote-aware сегментатор Bash-команд.

Задача: НЕ полноценный shell-парсер (это невозможно надёжно без исполнения),
а practical best-effort ответ на вопрос «из каких top-level команд состоит
эта строка, и в каком/каких каталогах каждая из них может выполниться»,
нужный ОБОИМ хукам набора (resource-lock.sh и push-content-guard.sh), чтобы
не дублировать логику дважды.

Что умеет:
  - разбивать команду на "item"-ы (см. split_top_level_items) по ; && || |
    (одиночный) & и переносу строки — уважая кавычки ('...' и "...");
  - НЕ разрывать fd-редиректы (`2>&1`, `1>&2`, `&>file`) на мусорные
    сегменты — они НЕ являются background-оператором `&`;
  - пропускать ТЕЛО heredoc (`cmd <<EOF\n...\nEOF`) целиком — это
    ЛИТЕРАЛЬНЫЕ ДАННЫЕ команды-хозяина, а не отдельные top-level команды;
  - раскрывать subshell-группы `( ... )` КАК ИЗОЛИРОВАННЫЙ подпроход —
    команды внутри исполняются, но `cd` внутри `( ... )` НЕ меняет каталог
    вызывающей оболочки ПОСЛЕ закрывающей скобки (родной синтаксис bash,
    раскрывается на ЛЮБУЮ глубину вложенности — не требует повторного
    вызова внешнего интерпретатора);
  - раскрывать `{ ... }` (группа команд) КАК ЧАСТЬ ТОЙ ЖЕ ОБОЛОЧКИ — В
    ОТЛИЧИЕ от `( ... )`, фигурные скобки НЕ форкают подпроцесс: `cd`
    внутри `{ ... }` ДЕЙСТВУЕТ на всё, что идёт после (см. Д9 ниже —
    группу и подоболочку легко перепутать, они разведены сознательно);
  - раскрывать ОДИН уровень `bash -c '...'` / `sh -c "..."` — типовая
    обёртка (требует доверия к содержимому внешнего вызова интерпретатора,
    поэтому ограничена одним уровнем — в отличие от `( ... )`/`{ ... }`);
  - ИЗОЛИРОВАТЬ каждую стадию пайплайна `a | b | c` и каждую фоновую задачу
    `cmd &` ДРУГ ОТ ДРУГА и от того, что снаружи (см. Д9 ниже) — та же
    природа изоляции, что у `( ... )`, только без явных скобок;
  - ОТСЛЕЖИВАТЬ МНОЖЕСТВО ВОЗМОЖНЫХ cwd (не одно достоверное значение) по
    всей цепочке — см. блок «МОДЕЛЬ КАНДИДАТОВ cwd» ниже.

## МОДЕЛЬ КАНДИДАТОВ cwd (cybersec, независимая проверка — три захода)

Первые два захода (Д1/Д2, затем Д6) моделировали cwd как ОДНО достоверное
значение — сперва "ведущий cd", потом "cd, накопленный последовательно по
цепочке". Оба раза модель была НЕВЕРНА в одну и ту же сторону дважды: сперва
пропускала реальный риск (тихий allow — Д1/Д2/Д6), затем — после того как
cwd стал накапливаться безусловно по ЛЮБОМУ синтаксически найденному `cd` —
стала ЛОЖНО СРАБАТЫВАТЬ на законной работе (Д7/Д8/Д9): `cd` внутри `( ... )`
ошибочно "протекал" наружу (Д7), `cd` в ветке `||`, которая физически могла
не исполниться, безусловно считался исполнившимся (Д8), и `cd` СЛЕВА от
пайпа `|` (Д9) ошибочно считался действующим для того, что СПРАВА от `|` и
для того, что идёт ПОСЛЕ всего пайплайна — хотя КАЖДАЯ стадия пайплайна
исполняется в СВОЁМ форке (bash не даёт `lastpipe` по умолчанию), и то же
самое верно для одиночной фоновой задачи `cmd &` (тоже форк).

Корень: статический разбор ПРИНЦИПИАЛЬНО не может знать, исполнится ли
условная ветка (`cmd1 || cmd2` — cmd2 исполняется, ТОЛЬКО ЕСЛИ cmd1 упал;
это известно лишь в момент запуска). Значит модель обязана быть не «какой
каталог», а **«какие каталоги ВОЗМОЖНЫ»** — множество кандидатов, каждый из
которых — либо конкретный путь, либо явная неизвестность.

Правила по каждому оператору/конструкции:
  - `;`, `&&`, перенос строки — ДЕТЕРМИНИРОВАННОЕ продолжение В ПРЕДЕЛАХ
    ОДНОГО AND-OR-списка (см. `_group_units`): множество кандидатов
    заменяется на "все кандидаты, к которым применён эффект этого item".
    Для `&&` это оправдано семантикой bash (правая часть исполняется,
    ТОЛЬКО если левая успешна — значит, если сегмент ПОСЛЕ `cd X &&` вообще
    найден, `cd X` либо успел выполниться, либо цепочка не дошла до этого
    сегмента); тот же довод неявно принят и для `;`.
  - `||` — УСЛОВНОЕ ветвление ВНУТРИ списка: правая часть МОЖЕТ не
    исполниться (если левая была успешна). Новое множество кандидатов =
    ОБЪЕДИНЕНИЕ {кандидаты, как будто правая часть НЕ исполнилась} ∪
    {кандидаты, как будто исполнилась} — безопасная переоценка сверху.
  - `( ... )` (subshell) — ДЕТЕРМИНИРОВАННО ИЗОЛИРОВАНА: `cd` внутри
    вообще НЕ меняет кандидатов СНАРУЖИ. Содержимое разбирается РЕКУРСИВНО
    (поиск push/resource-сегментов) со своим ЛОКАЛЬНЫМ проходом, начинающимся
    с кандидатов, накопленных СНАРУЖИ на момент этой группы.
  - `{ ... }` (группа) — НЕ изолирована (та же оболочка, НЕ форк): её
    содержимое СПЛАЙСИТСЯ прямо в окружающую последовательность item-ов,
    как если бы фигурных скобок не было вовсе — `cd` внутри действует на
    всё, что после (Д9: не перепутать с `( ... )`, иначе вернётся дыра
    ПРОПУСКА push/resource-риска внутри `{ ... }`).
  - `a | b | c` (пайплайн, Д9) — КАЖДАЯ стадия — СВОЙ независимый форк.
    Ни одна стадия не видит `cd`-эффект другой (даже соседней), и ВЕСЬ
    пайплайн целиком НЕ меняет кандидатов снаружи. Каждая стадия
    разбирается РЕКУРСИВНО (поиск push/resource-сегментов), НЕЗАВИСИМО от
    остальных, начиная с кандидатов, накопленных ДО пайплайна.
  - `cmd &` (одиночная фоновая задача, Д9) — тоже форк: `cmd`, а если это
    целый AND/OR-список (`a && b &`) — ВЕСЬ список целиком (bash фонит
    список, не последнюю команду поодиночке) — исполняется изолированно
    от того, что стоит ПОСЛЕ `&`. Внутри самого списка `cd` продолжает
    действовать как обычно (Д9-тест "cd && push &" — push обязан увидеть
    cd из ТОГО ЖЕ списка); наружу, после `&`, эффект не просачивается.

Неразрешимый `cd` (`cd $VAR`, `cd -`, `cd` без аргумента, относительный путь
поверх уже неизвестной точки) — по-прежнему даёт кандидата «НЕИЗВЕСТНО»
(cd_dir=None, cd_ambiguous=True), эта ветка НЕ ослаблена: хук-потребитель
обязан трактовать присутствие такого кандидата в множестве как отказ
(нельзя исключить, что именно в НЕИЗВЕСТНОМ каталоге и есть реальный риск).

⚠️ ОСТАТОЧНЫЙ УГОЛ (сознательно, не спрятано — см. README «Ограничения»):
`true || cd $X` — УСЛОВНАЯ ветка (`||`) вдобавок НЕРАЗРЕШИМАЯ (`cd $X`).
Множество кандидатов получает «НЕИЗВЕСТНО» (по правилу выше) → отказ, ХОТЯ
сама команда может быть полностью законной (RHS вообще не исполнится).
Цена признана приемлемой (форма редкая, ошибка в БЕЗОПАСНУЮ сторону —
лишний отказ, не лишний пропуск), но должна быть прочитана заранее, а не
обнаружена получателем на своей работе.

Границы (сознательно, не дыры): `eval '...'`, значение внутри `$VAR`,
интерпретируемый код (`python3 -c '...'`) — статически не раскрываются
(это требует исполнения). Символические ссылки — состояние файловой
системы, тоже не резолвятся здесь (TOCTOU). Второй уровень вложенности
`bash -c 'bash -c "..."'` не раскрывается (тот же исторический предел, что
у extract_bash_c_inner) — `( ... )`/`{ ... }` этого предела НЕ имеют, они
раскрываются на любую глубину. Эти пределы — общий предел любой статики без
исполнения, не только этого модуля (см. README «Ограничения» — полный
список форм, которые парсер по-прежнему не видит).

ЛИМИТ РАЗМЕРА: очень длинная команда (> SIZE_CAP символов) не парсится
полноценно (защита от O(n²)-скана на гигантском адверсариальном входе) —
возвращается пустой безопасный результат (fail-open: вызывающий хук
увидит «сегментов нет» и не станет ничего блокировать).

ЛИМИТ ЧИСЛА КАНДИДАТОВ: MAX_CANDIDATES (см. ниже) — защита от
комбинаторного взрыва на адверсариальной команде с множеством `||`.
Превышение схлопывает множество в единственного кандидата «НЕИЗВЕСТНО»
(безопасная сторона — это ведёт к отказу, не к пропуску).

Вызов как модуль (import) — так его используют resource-lock.sh (через
свой CLI-обвязчик) и git_push_parse.py. Есть и собственный CLI:
  printf '%s' "$CMD" | python3 shell_segments.py
выводит JSON: {"cd_dir":..., "cd_ambiguous":..., "segments":[...],
"segments_detail":[{"segment":..., "cwd_candidates":[{"cd_dir":...,
"cd_ambiguous":...}, ...]}, ...]}

Любая внутренняя ошибка → безопасный пустой результат, никогда traceback
наружу (вызывающий хук — предохранитель, обязан fail-open).
"""
import json
import re
import shlex
import sys

SIZE_CAP = 50_000
MAX_CANDIDATES = 20

HEREDOC_RE = re.compile(r"<<(-)?\s*(?:'([^']*)'|\"([^\"]*)\"|([^\s;&|()<>]+))")


def _empty_result():
    return {"cd_dir": None, "cd_ambiguous": False, "segments": [], "segments_detail": []}


def split_top_level_items(s, heredocs=None):
    """Разбить `s` на ПОСЛЕДОВАТЕЛЬНОСТЬ верхнеуровневых item-ов — обычных
    команд, subshell-групп `( ... )`, или содержимого `{ ... }` (сплайснутого
    прямо в поток, см. ниже) — уважая кавычки/heredoc/fd-редиректы.

    Возвращает список [op, kind, text, bg]:
      op   — оператор, СТОЯЩИЙ ПЕРЕД этим item (None для самого первого):
             ';' '&&' '||' '&' '|' '\\n'
      kind — 'cmd' (text — обычный текст команды) или 'subshell' (text —
             СОДЕРЖИМОЕ МЕЖДУ внешними скобками `( ... )`, БЕЗ самих скобок;
             может рекурсивно содержать вложенные скобки — произвольная
             глубина, разбирается тем же вызовом рекурсивно потребителем).
      bg   — True, если этот КОНКРЕТНЫЙ item был непосредственно завершён
             одиночным `&` (background-оператором), т.е. этот item — ПОСЛЕДНИЙ
             в фоновом job'е (Д9, см. модуль docstring — используется
             `_group_units` для изоляции ВСЕГО фонового AND-OR-списка).

    Subshell `( ... )` распознаётся ТОЛЬКО когда `(` встречается в позиции,
    где ожидается НАЧАЛО новой команды (буфер пуст/пробелы) — отличает
    `( cmd )` от `$(...)` (буфер непуст, содержит `$`) и от `foo(...)`
    (буфер содержит "foo").

    `{ ... }` (группа команд, Д9) распознаётся АНАЛОГИЧНО (буфер пуст,
    следующий символ после `{` — пробел/таб/перевод строки, что отличает
    реальную группу от brace-expansion `{a,b,c}`, у которой пробела после
    `{` не бывает), НО, В ОТЛИЧИЕ от `( ... )`, её содержимое НЕ становится
    отдельным изолированным подпроходом — оно рекурсивно разбирается ЭТОЙ
    ЖЕ функцией и СПЛАЙСИТСЯ (splice) прямо в общий поток item-ов, как если
    бы фигурных скобок не было вовсе (та же оболочка, НЕ форк — `cd`
    внутри `{ ... }` обязан действовать на то, что после неё).
    """
    items = []
    buf = []
    i = 0
    n = len(s)
    quote = None
    pending_heredocs = []
    pending_op = [None]  # изменяемая "ячейка" для вложенной функции

    def flush_cmd():
        text = ''.join(buf).strip()
        del buf[:]
        if text:
            items.append([pending_op[0], 'cmd', text, False])
            pending_op[0] = None

    def scan_balanced(open_ch, close_ch, start):
        """От индекса `start` (сразу после открывающего символа) найти
        индекс ПОСЛЕ соответствующего закрывающего символа той же
        глубины, уважая кавычки. Возвращает (inner_text, index_after_close)."""
        depth = 1
        j = start
        inner_quote = None
        while j < n and depth > 0:
            cj = s[j]
            if inner_quote:
                if cj == inner_quote and s[j - 1] != '\\':
                    inner_quote = None
                j += 1
                continue
            if cj in ('"', "'"):
                inner_quote = cj
                j += 1
                continue
            if cj == open_ch:
                depth += 1
                j += 1
                continue
            if cj == close_ch:
                depth -= 1
                j += 1
                continue
            j += 1
        inner_end = j - 1 if depth == 0 else j
        return s[start:inner_end], j

    while i < n:
        c = s[i]
        if quote:
            buf.append(c)
            if c == quote and (i == 0 or s[i - 1] != '\\'):
                quote = None
            i += 1
            continue
        if c in ('"', "'"):
            quote = c
            buf.append(c)
            i += 1
            continue
        if c == '(' and not ''.join(buf).strip():
            del buf[:]
            inner_text, j = scan_balanced('(', ')', i + 1)
            items.append([pending_op[0], 'subshell', inner_text, False])
            pending_op[0] = None
            i = j
            continue
        if c == '{' and not ''.join(buf).strip() and i + 1 < n and s[i + 1] in (' ', '\t', '\n'):
            del buf[:]
            inner_text, j = scan_balanced('{', '}', i + 1)
            # НЕ subshell — сплайсим содержимое ПРЯМО в поток (та же
            # оболочка, cd внутри должен продолжать действовать наружу).
            inner_items = split_top_level_items(inner_text, heredocs=heredocs)
            for k, it in enumerate(inner_items):
                if k == 0:
                    items.append([pending_op[0], it[1], it[2], it[3]])
                else:
                    items.append(it)
            pending_op[0] = None
            i = j
            continue
        if c == '<' and s[i:i + 3] == '<<<':
            buf.append('<<<')
            i += 3
            continue
        if c == '<' and i + 1 < n and s[i + 1] == '<':
            m = HEREDOC_RE.match(s, i)
            delim = (m.group(2) or m.group(3) or m.group(4)) if m else None
            if m and delim:
                strip_tabs = bool(m.group(1))
                pending_heredocs.append((delim, strip_tabs))
                buf.append(s[i:m.end()])
                i = m.end()
                continue
        if c == '\n':
            if pending_heredocs:
                owner_seg = ''.join(buf).strip()
                if owner_seg:
                    items.append([pending_op[0], 'cmd', owner_seg, False])
                    pending_op[0] = None
                del buf[:]
                j = i + 1
                for delim, strip_tabs in pending_heredocs:
                    body_lines = []
                    while True:
                        line_end = s.find('\n', j)
                        end = line_end if line_end != -1 else n
                        line = s[j:end]
                        check = line.lstrip('\t') if strip_tabs else line
                        if check == delim or line_end == -1:
                            if line_end == -1 and check != delim:
                                body_lines.append(line)
                            j = end + 1 if line_end != -1 else n
                            break
                        body_lines.append(line)
                        j = end + 1
                    if heredocs is not None and owner_seg:
                        heredocs.append({"cmd": owner_seg, "body": '\n'.join(body_lines)})
                pending_heredocs = []
                i = j
                continue
            flush_cmd()
            pending_op[0] = '\n'
            i += 1
            continue
        if c == '|':
            if i + 1 < n and s[i + 1] == '|':
                flush_cmd(); pending_op[0] = '||'; i += 2; continue
            # `>|` noclobber-override — часть редиректа, не разделитель пайпа
            k = len(buf) - 1
            while k >= 0 and buf[k] in (' ', '\t'):
                k -= 1
            if k >= 0 and buf[k] == '>':
                buf.append(c); i += 1; continue
            flush_cmd(); pending_op[0] = '|'; i += 1; continue
        if c == ';':
            flush_cmd(); pending_op[0] = ';'; i += 1; continue
        if c == '&':
            if i + 1 < n and s[i + 1] == '&':
                flush_cmd(); pending_op[0] = '&&'; i += 2; continue
            if buf and buf[-1] in ('>', '<'):
                buf.append(c); i += 1; continue
            if i + 1 < n and s[i + 1] == '>':
                buf.append(c); i += 1; continue
            # Одиночный `&` — фоновый оператор (Д9): помечаем ТОЛЬКО ЧТО
            # завершённый item как bg=True (это последний member фонового
            # AND-OR-списка — см. _group_units). Следующий item НЕ несёт
            # "ведущего" оператора в обычном смысле — bash исполняет его
            # синхронно сразу после запуска фона, эквивалент ';'.
            flush_cmd()
            if items:
                items[-1][3] = True
            pending_op[0] = None
            i += 1
            continue
        buf.append(c)
        i += 1
    flush_cmd()
    return items


def strip_env_prefix(seg):
    """Убрать ведущие FOO=bar присвоения перед реальной командой."""
    parts = seg.split()
    while parts and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', parts[0]):
        parts.pop(0)
    return ' '.join(parts)


def safe_split(seg):
    try:
        return shlex.split(seg, posix=True)
    except ValueError:
        return seg.split()


def first_word(seg):
    toks = safe_split(strip_env_prefix(seg))
    return toks[0] if toks else ''


def basename_matches(word, name):
    return word.rstrip('/').split('/')[-1] == name


def extract_bash_c_inner(seg):
    """`bash -c '...'` / `sh -c "..."` → внутренняя строка (один уровень)."""
    toks = safe_split(strip_env_prefix(seg))
    if len(toks) >= 3 and (basename_matches(toks[0], 'bash') or basename_matches(toks[0], 'sh')):
        if toks[1] == '-c':
            return toks[2]
    return None


def _resolve_cd_arg(state, arg):
    """Применить ОДИН `cd arg` к ОДНОМУ кандидату состояния cwd. state —
    (cd_dir, cd_ambiguous) ДО этого cd. Возвращает НОВОЕ состояние.

    Модель одного кандидата — три исхода: (а) резолвлено — известен путь;
    (б) cd в цепочке не было (cd_dir=None, cd_ambiguous=False); (в) cd
    есть, но не резолвится (cd_dir=None, cd_ambiguous=True). Ветвление
    между "исполнится/не исполнится" (`||`) и изоляция (`( )`/`|`/`&`) —
    забота ВЫЗЫВАЮЩЕГО кода (см. _advance_candidates/_group_units), эта
    функция работает с ОДНИМ конкретным кандидатом-состоянием.
    """
    if arg is None or arg == '-' or '$' in arg or '`' in arg:
        # `cd` без аргумента / `cd -` / переменная или подстановка команды —
        # статически не резолвится → случай (в).
        return (None, True)
    if arg.startswith('/') or arg.startswith('~'):
        # Абсолютный (или домашний `~`) путь НЕ зависит от предыдущего
        # состояния — полностью его сбрасывает, снимая неоднозначность.
        return (arg, False)
    cur_dir, cur_amb = state
    if cur_amb:
        return (None, True)
    if cur_dir is None:
        return (arg, False)
    return (cur_dir.rstrip('/') + '/' + arg, False)


def _dedup_candidates(candidates):
    seen = []
    for c in candidates:
        if c not in seen:
            seen.append(c)
    return seen


def _cap_candidates(candidates):
    """Комбинаторный взрыв кандидатов (много `||` подряд) → безопасно
    схлопнуть в единственного «НЕИЗВЕСТНО» (fail-safe в сторону отказа,
    не пропуска — см. докстринг модуля)."""
    if len(candidates) > MAX_CANDIDATES:
        return [(None, True)]
    return candidates


def _collapse_candidates(candidates):
    """Схлопнуть множество кандидатов в ОДНО (cd_dir, cd_ambiguous) — для
    информационных полей верхнего уровня (final_top_level_cwd/parse()),
    которым не нужен полный per-сегмент разбор. Единственный кандидат —
    как есть (в т.ч. легитимное (None, False), "cd не было"); несколько —
    неоднозначность."""
    uniq = _dedup_candidates(candidates)
    if len(uniq) == 1:
        return uniq[0]
    return (None, True)


def _advance_candidates(candidates, op, kind, text):
    """Применить ОДИН cmd-item (op, kind, text) ко МНОЖЕСТВУ кандидатов
    cwd, вернуть НОВОЕ множество (см. блок «МОДЕЛЬ КАНДИДАТОВ cwd» в
    докстринге модуля). Вызывается ТОЛЬКО для kind == 'cmd' внутри ОДНОГО
    AND-OR-списка (см. `_group_units`/`_advance_group`) — изоляция
    subshell/pipeline/background — забота вызывающего, не эта функция."""
    stripped = strip_env_prefix(text)
    if not stripped:
        return candidates
    toks = safe_split(stripped)
    if not toks or toks[0] != 'cd':
        return candidates
    arg = toks[1] if len(toks) >= 2 else None
    advanced = _dedup_candidates([_resolve_cd_arg(c, arg) for c in candidates])
    if op == '||':
        # правая часть || МОЖЕТ не исполниться (Д8) — объединяем "как было"
        # (RHS не исполнилась) с "как если бы исполнилась" (безопасная
        # переоценка сверху, см. докстринг модуля).
        return _cap_candidates(_dedup_candidates(candidates + advanced))
    return _cap_candidates(advanced)


def _group_units(items):
    """Сгруппировать плоский список item-ов (см. split_top_level_items) в
    ЮНИТЫ с явной ИЗОЛЯЦИЕЙ (Д9 — каждая стадия пайплайна `|` и каждая
    фоновая задача `&` исполняются в СВОЁМ форке, их `cd` не может
    поменять cwd того, что происходит СНАРУЖИ).

    Возвращает список (group, group_bg):
      group     — список logical item-ов [op, kind, payload, bg] ОДНОГО
                  AND-OR-списка (item-ы, связанные && / ||; новый список
                  начинается там, где ведущий item НЕ связан &&/|| с
                  предыдущим — т.е. на ';', переносе строки, начале строки,
                  или сразу после фонового '&' предыдущего списка).
                  kind внутри group — 'cmd', 'subshell' или 'pipeline'
                  (payload для pipeline — список стадий [(kind, text), ...],
                  КАЖДАЯ стадия — независимый форк, см. модуль docstring).
      group_bg  — True, если ВЕСЬ этот AND-OR-список завершается одиночным
                  `&` (взято с bg последнего logical item-а в группе) —
                  тогда список исполняется как ОДИН фоновый job, изолированный
                  от того, что идёт после `&` (но НЕ от самого себя —
                  внутри списка `cd` продолжает действовать как обычно).
    """
    # Шаг 1: схлопнуть pipeline-стадии (последовательные item-ы, связанные
    # '|') в один logical item kind='pipeline'.
    logical = []
    i = 0
    n = len(items)
    while i < n:
        op, kind, text, bg = items[i]
        stages = [(kind, text)]
        j = i + 1
        while j < n and items[j][0] == '|':
            stages.append((items[j][1], items[j][2]))
            bg = items[j][3]
            j += 1
        if len(stages) > 1:
            logical.append([op, 'pipeline', stages, bg])
        else:
            logical.append([op, kind, text, bg])
        i = j

    # Шаг 2: сгруппировать logical item-ы в AND-OR-списки.
    units = []
    idx = 0
    m = len(logical)
    while idx < m:
        group = [logical[idx]]
        idx += 1
        while idx < m and logical[idx][0] in ('&&', '||'):
            group.append(logical[idx])
            idx += 1
        group_bg = group[-1][3]
        units.append((group, group_bg))
    return units


def _process_group(candidates, group, heredocs, bash_c_depth):
    """Обработать ОДИН AND-OR-список (см. _group_units), начиная с
    candidates. Возвращает (segments_out, final_candidates) — segments_out
    включает сегменты, найденные ВНУТРИ pipeline-стадий и subshell-групп
    этого списка (рекурсивно); final_candidates — состояние ПОСЛЕ обработки
    всего списка (используется вызывающим ТОЛЬКО если список НЕ фоновый —
    см. group_bg в _group_units)."""
    out = []
    cur = list(candidates)
    for op, kind, payload, _bg in group:
        if kind == 'pipeline':
            # КАЖДАЯ стадия пайплайна — свой независимый форк (Д9): все
            # стартуют с ОДНОГО и того же cur (состояние ДО пайплайна),
            # ни одна не видит эффект другой, пайплайн целиком не меняет cur.
            for skind, stext in payload:
                if skind == 'subshell':
                    out.extend(collect_segments_with_candidates(
                        stext, heredocs=heredocs, initial_candidates=cur,
                        bash_c_depth=bash_c_depth))
                else:
                    out.append((stext, _dedup_candidates(cur)))
                    if bash_c_depth < 1:
                        inner = extract_bash_c_inner(stext)
                        if inner:
                            out.extend(collect_segments_with_candidates(
                                inner, heredocs=heredocs, initial_candidates=cur,
                                bash_c_depth=bash_c_depth + 1))
            continue
        if kind == 'subshell':
            out.extend(collect_segments_with_candidates(
                payload, heredocs=heredocs, initial_candidates=cur,
                bash_c_depth=bash_c_depth))
            continue
        # kind == 'cmd'
        out.append((payload, _dedup_candidates(cur)))
        next_cur = _advance_candidates(cur, op, kind, payload)
        if bash_c_depth < 1:
            inner = extract_bash_c_inner(payload)
            if inner:
                out.extend(collect_segments_with_candidates(
                    inner, heredocs=heredocs, initial_candidates=next_cur,
                    bash_c_depth=bash_c_depth + 1))
        cur = next_cur
    return out, cur


def _advance_group(candidates, group):
    """Как _process_group, но БЕЗ сбора сегментов — только продвижение
    candidates по ОДНОМУ AND-OR-списку (используется final_top_level_cwd,
    которому не нужен разбор вложенных сегментов; pipeline/subshell не
    меняют candidates по определению — пропускаются)."""
    cur = list(candidates)
    for op, kind, payload, _bg in group:
        if kind in ('pipeline', 'subshell'):
            continue
        cur = _advance_candidates(cur, op, kind, payload)
    return cur


def collect_segments_with_candidates(cmd, heredocs=None, initial_candidates=None, bash_c_depth=0):
    """Вернуть список (segment_text, candidates) — candidates — СПИСОК
    ВОЗМОЖНЫХ (cd_dir, cd_ambiguous) для этого сегмента (см. блок «МОДЕЛЬ
    КАНДИДАТОВ cwd» в докстринге модуля), а НЕ единственное значение.

    Правило раскрытия:
      - `( ... )` (subshell) — раскрывается ВСЕГДА (любая глубина
        вложенности), локальный проход стартует с ТЕКУЩИХ candidates,
        результат ВЫБРАСЫВАЕТСЯ для внешнего множества (Д7);
      - `{ ... }` (группа) — НЕ отдельный проход вовсе: её содержимое уже
        СПЛАЙСНУТО в плоский список item-ов на уровне split_top_level_items
        (та же оболочка — Д9);
      - `a | b | c` (пайплайн) — КАЖДАЯ стадия раскрывается независимо,
        стартуя с candidates ДО пайплайна; пайплайн целиком не меняет
        candidates снаружи (Д9);
      - фоновый AND-OR-список (`... &`) — обрабатывается как обычно
        ВНУТРИ себя, но его итоговый эффект НЕ коммитится в candidates,
        видимые ПОСЛЕ него (Д9);
      - `bash -c '...'` — раскрывается ОДИН уровень (bash_c_depth<1, тот же
        исторический предел, что у extract_bash_c_inner), стартует с
        candidates НА МОМЕНТ этой обёртки, изменения внутри НЕ
        просачиваются наружу (дочерний процесс).
    """
    if initial_candidates is None:
        initial_candidates = [(None, False)]
    out = []
    candidates = list(initial_candidates)
    items = split_top_level_items(cmd, heredocs=heredocs)
    for group, group_bg in _group_units(items):
        seg_out, final_cur = _process_group(candidates, group, heredocs, bash_c_depth)
        out.extend(seg_out)
        if not group_bg:
            candidates = final_cur
        # group_bg=True — весь список форкнулся в фон (Д9): candidates
        # снаружи НЕ меняем, даже если внутри списка были свои cd.
    return out


def collect_segments(cmd, heredocs=None):
    """Плоский список ВСЕХ leaf-текстов команд (обратная совместимость —
    без cwd-контекста), включая найденные внутри subshell `( ... )`,
    `{ ... }`, стадий пайплайна и раскрытого `bash -c '...'`."""
    return [text for text, _candidates in collect_segments_with_candidates(cmd, heredocs=heredocs)]


def final_top_level_cwd(cmd):
    """Итоговое состояние cwd (cd_dir, cd_ambiguous), СХЛОПНУТОЕ в одно
    значение (см. _collapse_candidates), ПОСЛЕ обработки ВСЕЙ цепочки
    top-level item-ов команды — информационное поле верхнего уровня для
    parse()/git_push_parse.py, обратная совместимость для простых
    потребителей, которым не нужен полный per-сегмент разбор кандидатов.
    Subshell/pipeline-группы и фоновые списки НЕ учитываются (не меняют
    внешний cwd по определению — см. блок «МОДЕЛЬ КАНДИДАТОВ cwd»), их
    содержимое здесь не разбирается.
    """
    candidates = [(None, False)]
    for group, group_bg in _group_units(split_top_level_items(cmd)):
        if group_bg:
            continue
        candidates = _advance_group(candidates, group)
    return _collapse_candidates(candidates)


def normalize_command(raw):
    """Нормализация переноса строк ДО сегментации:
      - `\\<newline>` (line continuation) схлопывается в НИЧЕГО (не в
        пробел — bash тоже так делает; пробел уже стоит перед `\\`);
      - CRLF/CR → LF.
    """
    cmd = raw.replace('\r\n', '\n').replace('\r', '\n')
    cmd = re.sub(r'\\\n', '', cmd)
    return cmd


def parse(raw):
    """Полный разбор: {"cd_dir":..., "cd_ambiguous":..., "segments":[...],
    "segments_detail":[{"segment":...,
    "cwd_candidates":[{"cd_dir":...,"cd_ambiguous":...}, ...]}, ...]}.

    "cd_dir"/"cd_ambiguous" (верхнего уровня) — СХЛОПНУТЫЙ итоговый cwd
    после ВСЕЙ цепочки (см. final_top_level_cwd) — обратная совместимость
    для простых потребителей, которым не нужен разбор кандидатов.
    "segments_detail[].cwd_candidates" — МНОЖЕСТВО возможных cwd для
    КАЖДОГО конкретного сегмента (см. collect_segments_with_candidates) —
    то, что реально нужно security-критичному потребителю
    (push-content-guard.sh): проверить КАЖДОГО кандидата, отказ — если хоть
    один показывает риск (удаления в защищённой ветке) или неразрешим.

    Вход длиннее SIZE_CAP символов → безопасный пустой результат (см.
    докстринг модуля, раздел «ЛИМИТ РАЗМЕРА»).
    """
    if raw is None or len(raw) > SIZE_CAP:
        return _empty_result()
    try:
        cmd = normalize_command(raw)
        cd_dir, cd_ambiguous = final_top_level_cwd(cmd)
        detail = collect_segments_with_candidates(cmd)
        segments = [d[0] for d in detail]
        segments_detail = [
            {"segment": s, "cwd_candidates": [{"cd_dir": c, "cd_ambiguous": a} for c, a in cands]}
            for s, cands in detail
        ]
        return {"cd_dir": cd_dir, "cd_ambiguous": cd_ambiguous,
                "segments": segments, "segments_detail": segments_detail}
    except Exception:
        return _empty_result()


def main():
    try:
        raw = sys.stdin.read()
    except Exception:
        print(json.dumps(_empty_result()))
        return
    print(json.dumps(parse(raw)))


if __name__ == '__main__':
    main()
