#!/usr/bin/env python3
"""plan-size.py check <plan.md> | archive <plan.md> (--section TEXT | --line N)... [--note TEXT]

Claude Code's plan approval window (ExitPlanMode) refuses to offer approval for a
plan it cannot show in full: the only choices left are "send feedback" and Esc.
The plan text has to pass three limits (measured on Claude Code 2.1.3xx; if the
window says "too large" while this script says it fits, trust the window):

  1. at most 200,000 characters (UTF-16 code units, as JavaScript counts them);
  2. no line longer than 4,096 characters;
  3. a budget on LONG LINES: the sum of the squared lengths of all lines must stay
     within 4 * 4096^2 (about 67 million). A 2,000-character line costs as much as
     400 lines of 100 characters, so a few wide table rows or one-line prompts use
     the budget up long before the plan gets long.
  4. no run of 9 or more invisible characters (combining marks, zero-width format
     characters) in a row.

`check` measures the plan and, when it is heavy, names the heaviest sections and
lines.
  exit 0: fits (a warning is printed above 85% of a limit) · exit 1: over a limit,
  the window will withhold approval · exit 2: usage or read error

`archive` moves whole `## ` sections out of the plan into the companion file
<plan>-history.md in the same directory (created on first use, appended after) and
leaves a `## 📚 Plan history` section in the plan that points there. Use it when
nothing else writes the plan: no reviewer, critic or crew planner running.
Sections are chosen by their exact heading text without the `## ` (repeat
--section) or by the line number of the heading (repeat --line). `## ` lines inside
code fences are not headings.
  exit 0: moved · exit 2: nothing moved (unknown or ambiguous heading, the plan
  changed during the move, read or write error)
"""
import datetime
import hashlib
import os
import re
import sys
import tempfile
import unicodedata

MAX_CHARS = 200000
MAX_LINE = 4096
LINE_BUDGET = 4 * MAX_LINE * MAX_LINE
MAX_INVISIBLE_RUN = 8
WARN_SHARE = 0.85
LONG_LINE = 1000
HISTORY_HEADING = "## 📚 Plan history"

# The same gate line the plan-approved hook looks for (git-guards plan-approved.py).
GATE_LINE = re.compile(r"(?m)^(Гейт: ✅ пройден|Gate: ✅ passed)")
FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^#{1,2} ")
# Claude Code drops the emoji/text variation selectors before it measures lines.
VARIATION_SELECTORS = re.compile("[︎️]")


def u16(text):
    """Length as JavaScript counts it: characters above U+FFFF are two units."""
    return len(text) + sum(1 for ch in text if ord(ch) > 0xFFFF)


def invisible(ch):
    if ch == "\n":
        return False
    cat = unicodedata.category(ch)
    return cat.startswith("M") or cat == "Cf"


def read_plan(path):
    with open(path, "rb") as f:
        raw = f.read()
    return raw, raw.decode("utf-8", "surrogateescape")


def structure(lines):
    """[(index, heading)] of the top-level headings (`# ` and `## `) outside code fences."""
    out, fenced = [], False
    for i, line in enumerate(lines):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if not fenced and HEADING.match(line):
            out.append((i, line.rstrip("\r")))
    return out


def section_of(heads, i):
    name = "(top of the plan)"
    for start, head in heads:
        if start > i:
            break
        name = head
    return name


def measure(text):
    lines = text.split("\n")
    measured = [u16(VARIATION_SELECTORS.sub("", line)) for line in lines]
    run = longest_run = run_line = 0
    for i, line in enumerate(lines):
        run = 0
        for ch in VARIATION_SELECTORS.sub("", line):
            run = run + 1 if invisible(ch) else 0
            if run > longest_run:
                longest_run, run_line = run, i
    return {
        "lines": lines,
        "measured": measured,
        "chars": u16(text),
        "squares": sum(n * n for n in measured),
        "longest": max(measured) if measured else 0,
        "longest_at": measured.index(max(measured)) if measured else 0,
        "invisible_run": longest_run,
        "invisible_at": run_line,
    }


def cmd_check(path):
    try:
        _, text = read_plan(path)
    except OSError as e:
        print("plan-size: cannot read %s: %s" % (path, e))
        return 2
    m = measure(text)
    lines, measured = m["lines"], m["measured"]
    heads = structure(lines)
    shares = [
        ("characters", m["chars"] / MAX_CHARS, "%s of %s" % (f"{m['chars']:,}", f"{MAX_CHARS:,}")),
        ("longest line", m["longest"] / MAX_LINE,
         "%s of %s (line %d)" % (f"{m['longest']:,}", f"{MAX_LINE:,}", m["longest_at"] + 1)),
        ("long-line budget", m["squares"] / LINE_BUDGET,
         "%d lines over %s characters" % (sum(1 for n in measured if n > LONG_LINE), f"{LONG_LINE:,}")),
    ]
    over = [name for name, share, _ in shares if share > 1]
    if m["invisible_run"] > MAX_INVISIBLE_RUN:
        over.append("invisible characters")
    worst = max(share for _, share, _ in shares)
    print("plan-size: %s" % os.path.basename(path))
    for name, share, detail in shares:
        mark = "❌" if share > 1 else ("⚠️" if share >= WARN_SHARE else "✅")
        print("  %s %-17s %4.0f%%  %s" % (mark, name, share * 100, detail))
    if m["invisible_run"] > MAX_INVISIBLE_RUN:
        print("  ❌ invisible characters: %d in a row on line %d (more than %d hides the plan)"
              % (m["invisible_run"], m["invisible_at"] + 1, MAX_INVISIBLE_RUN))
    if over:
        print("Verdict: ❌ over the limit (%s): the approval window will withhold approval." % ", ".join(over))
    elif worst >= WARN_SHARE:
        print("Verdict: ⚠️ fits, but close to the limit: every reviewer round adds to it.")
    else:
        print("Verdict: ✅ fits.")
    if over or worst >= WARN_SHARE:
        sections = []
        bounds = heads + [(len(lines), None)]
        if not heads or heads[0][0] > 0:
            bounds = [(0, "(top of the plan)")] + bounds
        for (start, head), (end, _) in zip(bounds, bounds[1:]):
            chars = sum(measured[start:end]) + (end - start)
            squares = sum(n * n for n in measured[start:end])
            sections.append((chars, squares, start, head))
        print("Heaviest sections (characters · share of the long-line budget):")
        for chars, squares, start, head in sorted(sections, reverse=True)[:8]:
            print("  line %-5d %-48s %8s  %3.0f%%" % (start + 1, head[:48], f"{chars:,}",
                                                       squares / LINE_BUDGET * 100))
        longest = sorted(range(len(measured)), key=lambda i: measured[i], reverse=True)[:5]
        longest = [i for i in longest if measured[i] > LONG_LINE]
        if longest:
            print("Longest lines (split them: a long table cell goes into a list below the table):")
            for i in longest:
                print("  line %-5d %6s chars  in %s" % (i + 1, f"{measured[i]:,}", section_of(heads, i)[:60]))
    return 1 if over else 0


def history_path(path):
    stem, ext = os.path.splitext(path)
    return stem + "-history" + ext


def write_atomic(path, data):
    """A temp file next to the target (same filesystem), then a rename over it."""
    fd, tmp = tempfile.mkstemp(prefix=".plan-size.", dir=os.path.dirname(os.path.abspath(path)))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def cmd_archive(path, wanted_text, wanted_lines, note):
    if not wanted_text and not wanted_lines:
        print("plan-size: archive needs at least one --section or --line")
        return 2
    try:
        raw, text = read_plan(path)
    except OSError as e:
        print("plan-size: cannot read %s: %s" % (path, e))
        return 2
    lines = text.split("\n")
    heads = [(i, h) for i, h in structure(lines) if h.startswith("## ")]
    starts = set()
    for want in wanted_text:
        hits = [i for i, h in heads if h[3:].strip() == want.strip()]
        if not hits:
            print("plan-size: no `## %s` heading in the plan; nothing moved" % want)
            return 2
        if len(hits) > 1:
            print("plan-size: `## %s` heads %d sections (lines %s): pick one with --line; nothing moved"
                  % (want, len(hits), ", ".join(str(i + 1) for i in hits)))
            return 2
        starts.add(hits[0])
    for n in wanted_lines:
        if (n - 1) not in {i for i, _ in heads}:
            print("plan-size: line %d is not a `## ` heading outside a code fence; nothing moved" % n)
            return 2
        starts.add(n - 1)
    if any(lines[i].rstrip("\r") == HISTORY_HEADING for i in starts):
        print("plan-size: the `%s` section stays in the plan; nothing moved" % HISTORY_HEADING)
        return 2
    bounds = [i for i, _ in structure(lines)] + [len(lines)]
    moved, keep, skip_until = [], [], -1
    for i, line in enumerate(lines):
        if i in starts:
            skip_until = min(b for b in bounds if b > i)
            moved.append("\n".join(lines[i:skip_until]).rstrip("\r\n"))
        if i < skip_until:
            continue
        keep.append(line)
    name = os.path.basename(path)
    hist = history_path(path)
    hist_name = os.path.basename(hist)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    block = "\n\n# 📦 Moved out of the plan %s%s\n\n%s\n" % (
        stamp, (" — " + note.strip()) if note and note.strip() else "", "\n\n".join(moved))
    try:
        with open(hist, "rb") as f:
            old_hist = f.read().decode("utf-8", "surrogateescape")
    except FileNotFoundError:
        old_hist = ("# 📚 History of %s\n\nSections moved out of the main plan so that the "
                    "approval window can show it in full. Read-only: the plan is the source "
                    "of truth.\n" % name)
    new_plan = "\n".join(keep).rstrip("\r\n") + "\n"
    if not any(line.rstrip("\r") == HISTORY_HEADING for line in keep):
        new_plan += ("\n%s\n\nEarlier iterations, superseded review sections and full critic rounds "
                     "are in `%s` (same directory).\n" % (HISTORY_HEADING, hist_name))
    try:
        # A reviewer that is still writing would lose its edit: compare before replacing.
        with open(path, "rb") as f:
            if hashlib.sha256(f.read()).digest() != hashlib.sha256(raw).digest():
                print("plan-size: the plan changed during the move (an agent is still writing "
                      "it?); nothing moved, retry when it is done")
                return 2
        write_atomic(hist, (old_hist.rstrip("\n") + block).encode("utf-8", "surrogateescape"))
        write_atomic(path, new_plan.encode("utf-8", "surrogateescape"))
    except OSError as e:
        print("plan-size: write failed: %s" % e)
        return 2
    print("plan-size: moved %d section(s) to %s:" % (len(moved), hist_name))
    for chunk in moved:
        print("  " + chunk.split("\n", 1)[0])
    if not GATE_LINE.search(new_plan):
        print("⚠️ The plan has no `Gate: ✅ passed` line now: write the current gate table "
              "before ExitPlanMode.")
    if not re.search(r"(?m)^## .*Codex", new_plan) and not re.search(r"(?m)^[ \t]*\|[ \t]*Codex\b", new_plan):
        print("⚠️ The plan has no `## … Codex` section and no `| Codex` gate row now: the approval "
              "hook needs one of them in the plan itself, not in the history file.")
    return 0


def main(argv):
    if len(argv) < 2 or argv[0] not in ("check", "archive"):
        print(__doc__)
        return 2
    if argv[0] == "check":
        if len(argv) != 2:
            print(__doc__)
            return 2
        return cmd_check(argv[1])
    path, texts, nums, note = argv[1], [], [], ""
    rest = argv[2:]
    while rest:
        flag = rest.pop(0)
        if flag not in ("--section", "--line", "--note") or not rest:
            print(__doc__)
            return 2
        value = rest.pop(0)
        if flag == "--section":
            texts.append(value)
        elif flag == "--line":
            if not value.isdigit() or int(value) < 1:
                print("plan-size: --line takes a line number, got %r" % value)
                return 2
            nums.append(int(value))
        else:
            note = value
    return cmd_archive(path, texts, nums, note)


if __name__ == "__main__":
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass
    sys.exit(main(sys.argv[1:]))
