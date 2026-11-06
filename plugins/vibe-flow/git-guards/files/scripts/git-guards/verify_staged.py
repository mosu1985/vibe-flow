#!/usr/bin/env python3
"""Compare lists of git paths over the NUL protocol.

Why not shell: with core.quotePath, `git diff --name-only` C-quotes non-ASCII
and unusual names, `sort`/`diff` break on a newline inside a name, and a
directory pathspec expands into several files. All of this happens in real
projects — paths like `dír/fïle with spaces.txt` are live.

Reads a NUL-separated list from stdin.

  --expect <paths…>     stdin ⊆ expected. Every path from stdin must either
                        be exactly one of the arguments or lie inside a
                        directory argument. An extra path → rc=1 with a list.
  --intersects <paths…> Whether stdin intersects the arguments.
                        Yes → rc=0 (for `if` in shell), no → rc=1.
"""

import os
import sys


def read_nul() -> list[str]:
    data = sys.stdin.buffer.read()
    return [p.decode("utf-8", "surrogateescape") for p in data.split(b"\0") if p]


def norm(p: str) -> str:
    return os.path.normpath(p).lstrip("./")


def covered_by(path: str, expected: list[str]) -> bool:
    p = norm(path)
    for e in expected:
        e = norm(e)
        if p == e or p.startswith(e + "/"):
            return True
    return False


def main() -> int:
    if len(sys.argv) < 2:
        print("mode required: --expect | --intersects", file=sys.stderr)
        return 2

    mode, expected = sys.argv[1], sys.argv[2:]
    actual = read_nul()

    if mode == "--expect":
        extra = [p for p in actual if not covered_by(p, expected)]
        if extra:
            print("🔴 the commit contains paths that were not requested:", file=sys.stderr)
            for p in extra:
                print(f"     {p}", file=sys.stderr)
            print("   This is someone else's work — commit stopped.", file=sys.stderr)
            return 1
        return 0

    if mode == "--intersects":
        hit = [p for p in actual if covered_by(p, expected)]
        if hit:
            print("🔴 overlap with someone else's changes:", file=sys.stderr)
            for p in hit:
                print(f"     {p}", file=sys.stderr)
            return 0     # there IS an overlap
        return 1         # no overlap

    print(f"unknown mode: {mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
