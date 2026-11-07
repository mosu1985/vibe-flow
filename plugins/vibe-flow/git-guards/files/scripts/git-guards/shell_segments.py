# VENDORED code (upstream v1.0), obtained 2026-09-02. The "set of possible
# cwds" model was rewritten four times after an independent audit: do not
# rewrite it on your own, and when updating the kit, diff against the original.
#!/usr/bin/env python3
"""
shell_segments.py — shared quote-aware segmenter for Bash commands.

Goal: NOT a full shell parser (that cannot be done reliably without
executing), but a practical best-effort answer to "which top-level commands
make up this string, and in which directory (or directories) can each of them
run", needed by BOTH hooks that consume this module, so the logic is not
duplicated.

What it does:
  - splits the command into "items" (see split_top_level_items) on ; && || |
    (single) & and newline, respecting quotes ('...' and "...");
  - does NOT break fd redirects (`2>&1`, `1>&2`, `&>file`) into garbage
    segments: they are NOT the background operator `&`;
  - skips a heredoc BODY (`cmd <<EOF\n...\nEOF`) entirely: it is LITERAL
    DATA of the owning command, not separate top-level commands;
  - expands subshell groups `( ... )` AS AN ISOLATED sub-pass: the commands
    inside do run, but a `cd` inside `( ... )` does NOT change the calling
    shell's directory AFTER the closing paren (native bash syntax, expanded
    to ANY nesting depth, no repeated call to an external interpreter
    needed);
  - expands `{ ... }` (command group) AS PART OF THE SAME SHELL: UNLIKE
    `( ... )`, braces do NOT fork a subprocess, so a `cd` inside `{ ... }`
    DOES apply to everything after it (see D9 below: group and subshell are
    easy to confuse, and they are kept apart on purpose);
  - expands ONE level of `bash -c '...'` / `sh -c "..."`, the typical
    wrapper (this requires trusting the content of an external interpreter
    call, so it is limited to one level, unlike `( ... )`/`{ ... }`);
  - ISOLATES each pipeline stage `a | b | c` and each background job
    `cmd &` FROM EACH OTHER and from the outside (see D9 below): the same
    kind of isolation as `( ... )`, just without explicit parens;
  - TRACKS A SET OF POSSIBLE cwds (not one definite value) along the whole
    chain; see the "cwd CANDIDATE MODEL" section below.

## cwd CANDIDATE MODEL (cybersec, independent review, three rounds)

The first two rounds (D1/D2, then D6) modeled cwd as ONE definite value:
first "the leading cd", then "cd accumulated sequentially along the chain".
Both times the model was WRONG in the same direction twice: first it missed
a real risk (silent allow: D1/D2/D6), then, once cwd started accumulating
unconditionally from ANY syntactically found `cd`, it started FALSE-FIRING on
legitimate work (D7/D8/D9): a `cd` inside `( ... )` wrongly "leaked" outside
(D7), a `cd` in an `||` branch that might physically never run was
unconditionally treated as executed (D8), and a `cd` to the LEFT of a pipe
`|` (D9) was wrongly treated as in effect for what is to the RIGHT of `|` and
for what comes AFTER the whole pipeline, even though EACH pipeline stage runs
in ITS OWN fork (bash has no `lastpipe` by default), and the same holds for a
lone background job `cmd &` (also a fork).

Root cause: static analysis FUNDAMENTALLY cannot know whether a conditional
branch will run (`cmd1 || cmd2`: cmd2 runs ONLY IF cmd1 failed, which is
known only at run time). So the model must answer not "which directory" but
**"which directories are POSSIBLE"**: a set of candidates, each of which is
either a concrete path or an explicit unknown.

Rules per operator/construct:
  - `;`, `&&`, newline: DETERMINISTIC continuation WITHIN ONE AND-OR list
    (see `_group_units`): the candidate set is replaced with "all candidates
    with this item's effect applied". For `&&` this is justified by bash
    semantics (the right side runs ONLY if the left side succeeded, so if a
    segment AFTER `cd X &&` is found at all, either `cd X` has run or the
    chain never reached that segment); the same argument is implicitly
    accepted for `;`.
  - `||`: CONDITIONAL branching INSIDE a list: the right side MAY not run
    (if the left side succeeded). New candidate set = UNION of {candidates
    as if the right side did NOT run} ∪ {candidates as if it did}, a safe
    over-approximation.
  - `( ... )` (subshell): DETERMINISTICALLY ISOLATED: a `cd` inside does not
    change the candidates OUTSIDE at all. The content is parsed RECURSIVELY
    (looking for push/resource segments) in its own LOCAL pass, starting
    from the candidates accumulated OUTSIDE at the point of this group.
  - `{ ... }` (group): NOT isolated (same shell, NOT a fork): its content is
    SPLICED directly into the surrounding item sequence, as if the braces
    were not there at all, so a `cd` inside applies to everything after it
    (D9: do not confuse with `( ... )`, or the hole that MISSES a
    push/resource risk inside `{ ... }` comes back).
  - `a | b | c` (pipeline, D9): EACH stage is its own independent fork.
    No stage sees another stage's `cd` effect (not even its neighbor's), and
    the WHOLE pipeline does NOT change the candidates outside. Each stage is
    parsed RECURSIVELY (looking for push/resource segments), INDEPENDENTLY of
    the others, starting from the candidates accumulated BEFORE the pipeline.
  - `cmd &` (lone background job, D9): also a fork: `cmd`, or if it is a
    whole AND/OR list (`a && b &`), the WHOLE list (bash backgrounds the
    list, not just the last command) runs isolated from what comes AFTER
    `&`. Inside the list itself `cd` keeps working as usual (D9 test
    "cd && push &": push must see the cd from the SAME list); the effect does
    not leak out past `&`.

An unresolvable `cd` (`cd $VAR`, `cd -`, `cd` with no argument, a relative
path on top of an already unknown point) still yields an "UNKNOWN" candidate
(cd_dir=None, cd_ambiguous=True), and this branch is NOT weakened: the
consuming hook must treat the presence of such a candidate in the set as a
deny (it cannot rule out that the real risk is in exactly that UNKNOWN
directory).

⚠️ RESIDUAL CORNER (deliberate, not hidden; see README "Limitations"):
`true || cd $X` is a CONDITIONAL branch (`||`) that is also UNRESOLVABLE
(`cd $X`). The candidate set gets "UNKNOWN" (by the rule above), so the
result is a deny, EVEN THOUGH the command itself may be perfectly legitimate
(the RHS never runs). The cost was judged acceptable (the form is rare, and
the error is on the SAFE side: an extra deny, not an extra allow), but it
must be read up front rather than discovered by a recipient in their own
work.

Boundaries (deliberate, not holes): `eval '...'`, a value inside `$VAR`,
interpreted code (`python3 -c '...'`) are not expanded statically (that would
require execution). Symlinks are filesystem state and are not resolved here
either (TOCTOU). A second nesting level `bash -c 'bash -c "..."'` is not
expanded (the same historical limit as extract_bash_c_inner); `( ... )`/
`{ ... }` do NOT have this limit and are expanded to any depth. These limits
are the general limit of any static analysis without execution, not just of
this module (see README "Limitations" for the full list of forms the parser
still cannot see).

SIZE LIMIT: a very long command (> SIZE_CAP characters) is not fully parsed
(protection against an O(n²) scan on a huge adversarial input): a safe empty
result is returned (fail-open: the calling hook sees "no segments" and blocks
nothing).

CANDIDATE COUNT LIMIT: MAX_CANDIDATES (see below) protects against a
combinatorial explosion on an adversarial command with many `||`. Exceeding
it collapses the set into a single "UNKNOWN" candidate (the safe side: it
leads to a deny, not an allow).

Called as a module (import): that is how the consuming hooks use it (via
their own CLI wrapper) and git_push_parse.py. There is also a standalone CLI:
  printf '%s' "$CMD" | python3 shell_segments.py
prints JSON: {"cd_dir":..., "cd_ambiguous":..., "segments":[...],
"segments_detail":[{"segment":..., "cwd_candidates":[{"cd_dir":...,
"cd_ambiguous":...}, ...]}, ...]}

Any internal error → a safe empty result, never a traceback to the caller
(the calling hook is a safety net and must fail open).
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
    """Split `s` into a SEQUENCE of top-level items (plain commands, subshell
    groups `( ... )`, or the content of `{ ... }` spliced directly into the
    stream, see below), respecting quotes/heredocs/fd redirects.

    Returns a list of [op, kind, text, bg]:
      op   — the operator that PRECEDES this item (None for the very first):
             ';' '&&' '||' '&' '|' '\\n'
      kind — 'cmd' (text is plain command text) or 'subshell' (text is the
             CONTENT BETWEEN the outer parens `( ... )`, WITHOUT the parens;
             may recursively contain nested parens of any depth, which the
             consumer parses recursively with the same call).
      bg   — True if this PARTICULAR item was directly terminated by a single
             `&` (the background operator), i.e. this item is the LAST one in
             a background job (D9, see the module docstring; `_group_units`
             uses it to isolate the WHOLE background AND-OR list).

    A subshell `( ... )` is recognized ONLY when `(` appears where the START
    of a new command is expected (buffer empty/whitespace); this tells
    `( cmd )` apart from `$(...)` (buffer non-empty, contains `$`) and from
    `foo(...)` (buffer contains "foo").

    A `{ ... }` command group (D9) is recognized THE SAME WAY (buffer empty,
    and the character after `{` is a space/tab/newline, which tells a real
    group apart from brace expansion `{a,b,c}`, where there is never a space
    after `{`), BUT, UNLIKE `( ... )`, its content does NOT become a separate
    isolated sub-pass: it is parsed recursively by THIS SAME function and
    SPLICED directly into the shared item stream, as if the braces were not
    there at all (same shell, NOT a fork: a `cd` inside `{ ... }` must apply
    to what comes after it).
    """
    items = []
    buf = []
    i = 0
    n = len(s)
    quote = None
    pending_heredocs = []
    pending_op = [None]  # mutable "cell" for the nested function

    def flush_cmd():
        text = ''.join(buf).strip()
        del buf[:]
        if text:
            items.append([pending_op[0], 'cmd', text, False])
            pending_op[0] = None

    def scan_balanced(open_ch, close_ch, start):
        """From index `start` (right after the opening character) find the
        index AFTER the matching closing character at the same depth,
        respecting quotes. Returns (inner_text, index_after_close)."""
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
            # NOT a subshell: splice the content DIRECTLY into the stream (same
            # shell, a cd inside must keep applying outside).
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
            # `>|` noclobber override is part of a redirect, not a pipe separator
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
            # A single `&` is the background operator (D9): mark the item that
            # JUST ended as bg=True (it is the last member of a background
            # AND-OR list, see _group_units). The next item carries no
            # "leading" operator in the usual sense: bash runs it
            # synchronously right after launching the background job, same as ';'.
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
    """Drop leading FOO=bar assignments before the real command."""
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
    """`bash -c '...'` / `sh -c "..."` → the inner string (one level)."""
    toks = safe_split(strip_env_prefix(seg))
    if len(toks) >= 3 and (basename_matches(toks[0], 'bash') or basename_matches(toks[0], 'sh')):
        if toks[1] == '-c':
            return toks[2]
    return None


def _resolve_cd_arg(state, arg):
    """Apply ONE `cd arg` to ONE cwd candidate state. state is
    (cd_dir, cd_ambiguous) BEFORE this cd. Returns the NEW state.

    A single candidate has three outcomes: (a) resolved, the path is known;
    (b) there was no cd in the chain (cd_dir=None, cd_ambiguous=False); (c) a
    cd exists but does not resolve (cd_dir=None, cd_ambiguous=True).
    Branching between "will run / will not run" (`||`) and isolation
    (`( )`/`|`/`&`) are the CALLER's job (see _advance_candidates/
    _group_units); this function works on ONE concrete candidate state.
    """
    if arg is None or arg == '-' or '$' in arg or '`' in arg:
        # `cd` with no argument / `cd -` / a variable or command substitution
        # does not resolve statically → case (c).
        return (None, True)
    if arg.startswith('/') or arg.startswith('~'):
        # An absolute (or home `~`) path does NOT depend on the previous
        # state: it resets it completely, clearing the ambiguity.
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
    """A combinatorial explosion of candidates (many `||` in a row) → safely
    collapse into a single "UNKNOWN" (fail-safe toward deny, not allow; see
    the module docstring)."""
    if len(candidates) > MAX_CANDIDATES:
        return [(None, True)]
    return candidates


def _collapse_candidates(candidates):
    """Collapse the candidate set into ONE (cd_dir, cd_ambiguous), for the
    informational top-level fields (final_top_level_cwd/parse()) that do not
    need the full per-segment analysis. A single candidate is returned as is
    (including the legitimate (None, False), "there was no cd"); several mean
    ambiguity."""
    uniq = _dedup_candidates(candidates)
    if len(uniq) == 1:
        return uniq[0]
    return (None, True)


def _advance_candidates(candidates, op, kind, text):
    """Apply ONE cmd item (op, kind, text) to the SET of cwd candidates and
    return the NEW set (see the "cwd CANDIDATE MODEL" section in the module
    docstring). Called ONLY for kind == 'cmd' inside ONE AND-OR list (see
    `_group_units`/`_advance_group`); subshell/pipeline/background isolation
    is the caller's job, not this function's."""
    stripped = strip_env_prefix(text)
    if not stripped:
        return candidates
    toks = safe_split(stripped)
    # `pushd dir` changes the cwd exactly like `cd dir`; `popd` goes back to a
    # directory we do not track → unknown.
    if not toks or toks[0] not in ('cd', 'pushd', 'popd'):
        return candidates
    args = [t for t in toks[1:] if not t.startswith('-') or t == '-']
    arg = None if toks[0] == 'popd' else (args[0] if args else None)
    advanced = _dedup_candidates([_resolve_cd_arg(c, arg) for c in candidates])
    if op == '||':
        # the right side of || MAY not run (D8): union "as it was" (the RHS
        # did not run) with "as if it ran" (a safe over-approximation, see
        # the module docstring).
        return _cap_candidates(_dedup_candidates(candidates + advanced))
    return _cap_candidates(advanced)


def _group_units(items):
    """Group a flat list of items (see split_top_level_items) into UNITS with
    explicit ISOLATION (D9: each pipeline stage `|` and each background job
    `&` runs in ITS OWN fork, so its `cd` cannot change the cwd of what
    happens OUTSIDE).

    Returns a list of (group, group_bg):
      group     — a list of logical items [op, kind, payload, bg] of ONE
                  AND-OR list (items joined by && / ||; a new list starts
                  where the leading item is NOT joined by &&/|| to the
                  previous one, i.e. at ';', a newline, the start of the
                  string, or right after the background '&' of the previous
                  list). kind inside a group is 'cmd', 'subshell' or
                  'pipeline' (the payload of a pipeline is a list of stages
                  [(kind, text), ...], EACH stage an independent fork, see
                  the module docstring).
      group_bg  — True if this WHOLE AND-OR list ends with a single `&`
                  (taken from the bg of the last logical item in the group);
                  then the list runs as ONE background job, isolated from
                  what comes after `&` (but NOT from itself: inside the list
                  `cd` keeps working as usual).
    """
    # Step 1: collapse pipeline stages (consecutive items joined by '|') into
    # one logical item with kind='pipeline'.
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

    # Step 2: group logical items into AND-OR lists.
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
    """Process ONE AND-OR list (see _group_units), starting from candidates.
    Returns (segments_out, final_candidates): segments_out includes the
    segments found INSIDE this list's pipeline stages and subshell groups
    (recursively); final_candidates is the state AFTER processing the whole
    list (the caller uses it ONLY if the list is NOT a background one, see
    group_bg in _group_units)."""
    out = []
    cur = list(candidates)
    for op, kind, payload, _bg in group:
        if kind == 'pipeline':
            # EACH pipeline stage is its own independent fork (D9): all of
            # them start from the SAME cur (the state BEFORE the pipeline),
            # none sees another's effect, and the pipeline as a whole does not change cur.
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
    """Like _process_group, but WITHOUT collecting segments: it only advances
    candidates through ONE AND-OR list (used by final_top_level_cwd, which
    does not need nested segments; pipeline/subshell do not change
    candidates by definition and are skipped)."""
    cur = list(candidates)
    for op, kind, payload, _bg in group:
        if kind in ('pipeline', 'subshell'):
            continue
        cur = _advance_candidates(cur, op, kind, payload)
    return cur


def collect_segments_with_candidates(cmd, heredocs=None, initial_candidates=None, bash_c_depth=0):
    """Return a list of (segment_text, candidates), where candidates is a LIST
    of POSSIBLE (cd_dir, cd_ambiguous) for that segment (see the "cwd
    CANDIDATE MODEL" section in the module docstring), NOT a single value.

    Expansion rules:
      - `( ... )` (subshell) is ALWAYS expanded (any nesting depth); the
        local pass starts from the CURRENT candidates, and its result is
        DISCARDED for the outer set (D7);
      - `{ ... }` (group) is not a separate pass at all: its content is
        already SPLICED into the flat item list by split_top_level_items
        (same shell, D9);
      - `a | b | c` (pipeline): EACH stage is expanded independently,
        starting from the candidates BEFORE the pipeline; the pipeline as a
        whole does not change the candidates outside (D9);
      - a background AND-OR list (`... &`) is processed as usual INSIDE
        itself, but its final effect is NOT committed to the candidates
        visible AFTER it (D9);
      - `bash -c '...'` is expanded ONE level (bash_c_depth<1, the same
        historical limit as extract_bash_c_inner), starts from the
        candidates AT THE POINT of this wrapper, and changes inside do NOT
        leak outside (child process).
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
        # group_bg=True: the whole list forked into the background (D9), so
        # the outer candidates do NOT change even if the list had its own cds.
    return out


def collect_segments(cmd, heredocs=None):
    """Flat list of ALL leaf command texts (backward compatibility, no cwd
    context), including those found inside a subshell `( ... )`, `{ ... }`,
    pipeline stages and an expanded `bash -c '...'`."""
    return [text for text, _candidates in collect_segments_with_candidates(cmd, heredocs=heredocs)]


def final_top_level_cwd(cmd):
    """The final cwd state (cd_dir, cd_ambiguous), COLLAPSED into one value
    (see _collapse_candidates), AFTER processing the WHOLE chain of the
    command's top-level items: an informational top-level field for
    parse()/git_push_parse.py, kept for backward compatibility with simple
    consumers that do not need the full per-segment candidate analysis.
    Subshell/pipeline groups and background lists are NOT taken into account
    (by definition they do not change the outer cwd, see the "cwd CANDIDATE
    MODEL" section); their content is not parsed here.
    """
    candidates = [(None, False)]
    for group, group_bg in _group_units(split_top_level_items(cmd)):
        if group_bg:
            continue
        candidates = _advance_group(candidates, group)
    return _collapse_candidates(candidates)


def normalize_command(raw):
    """Normalize line breaks BEFORE segmentation:
      - `\\<newline>` (line continuation) collapses to NOTHING (not to a
        space: bash does the same; the space is already before the `\\`);
      - CRLF/CR → LF.
    """
    cmd = raw.replace('\r\n', '\n').replace('\r', '\n')
    cmd = re.sub(r'\\\n', '', cmd)
    return cmd


def parse(raw):
    """Full parse: {"cd_dir":..., "cd_ambiguous":..., "segments":[...],
    "segments_detail":[{"segment":...,
    "cwd_candidates":[{"cd_dir":...,"cd_ambiguous":...}, ...]}, ...]}.

    Top-level "cd_dir"/"cd_ambiguous" is the COLLAPSED final cwd after the
    WHOLE chain (see final_top_level_cwd), kept for backward compatibility
    with simple consumers that do not need candidate analysis.
    "segments_detail[].cwd_candidates" is the SET of possible cwds for EACH
    individual segment (see collect_segments_with_candidates), which is what
    a security-critical consumer (a push content guard) actually needs:
    check EVERY candidate and deny if even one shows a risk (deletions in a
    protected branch) or is unresolvable.

    Input longer than SIZE_CAP characters → a safe empty result (see the
    "SIZE LIMIT" section of the module docstring).
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
