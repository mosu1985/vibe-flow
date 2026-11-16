#!/usr/bin/env python3
"""attributes.py TARGET — the kit's eol=lf block in TARGET/.gitattributes.

WHY. Git for Windows ships with core.autocrlf=true: without attributes, every kit
script is checked out with CRLF in a worktree on Windows, and bash dies on the
first `$'\\r'`. A marked block pins the kit's own paths to LF on every clone, on
every OS, whatever the machine's settings:

    # vibe-flow:git-guards:begin (managed by vibe-flow, do not edit inside)
    ...kit paths... text eol=lf
    # vibe-flow:git-guards:end

An existing block is replaced in place; an absent one is appended (after a newline
if the file does not end with one). Lines outside the markers stay byte-identical,
CRLF ones included, and a rerun leaves the file byte-identical. TARGET may be any
directory (a repository is not required). Called by install.sh and by
tools/rollout-projects.sh prepare — the two delivery paths of the kit.

Exit 0 on success; 1 with a message on stderr otherwise (a malformed block is
reported, never guessed at).
"""
from __future__ import annotations

import os
import sys
import tempfile
from typing import List, Optional, Tuple

BEGIN = "# vibe-flow:git-guards:begin (managed by vibe-flow, do not edit inside)"
END = "# vibe-flow:git-guards:end"
# The kit's path list (K11): the same paths git-safe-commit.sh keeps executable.
KIT_PATHS = (
    "scripts/*.sh",
    "scripts/git-guards/**",
    "githooks/**",
    ".claude/hooks/**",
    ".gitguards.conf",
)
BLOCK = [BEGIN] + ["%s text eol=lf" % p for p in KIT_PATHS] + [END]
FILE_NAME = ".gitattributes"


class BlockError(Exception):
    """The file has markers that do not form exactly one begin/end pair."""


def marker_of(line: str) -> str:
    """The line as compared with the markers: no trailing CR, no surrounding blanks."""
    return line.rstrip("\r").strip()


def find_block(lines: List[str]) -> Optional[Tuple[int, int]]:
    """(begin, end) indexes of the one managed block, None when there is none."""
    begins = [i for i, l in enumerate(lines) if marker_of(l) == BEGIN]
    ends = [i for i, l in enumerate(lines) if marker_of(l) == END]
    if not begins and not ends:
        return None
    if len(begins) != 1 or len(ends) != 1 or ends[0] < begins[0]:
        raise BlockError(
            "%s has %d begin and %d end markers of the vibe-flow block — expected one pair; "
            "fix the file by hand and run again" % (FILE_NAME, len(begins), len(ends)))
    return begins[0], ends[0]


def render(text: str) -> str:
    """The new file content. Pure: the same input always gives the same output."""
    if not text:
        return "\n".join(BLOCK) + "\n"
    lines = text.split("\n")          # the last item is what follows the final "\n"
    span = find_block(lines)
    if span is not None:
        start, end = span
        return "\n".join(lines[:start] + BLOCK + lines[end + 1:])
    prefix = text if text.endswith("\n") else text + "\n"
    return prefix + "\n".join(BLOCK) + "\n"


def read_text(path: str) -> str:
    """The file as text, bytes preserved (CR kept, undecodable bytes round-trip)."""
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as fh:
        return fh.read()


def write_atomically(path: str, text: str) -> None:
    """Replace the file in one rename, so no reader ever sees half of it."""
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".gitattributes.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape", newline="\n") as fh:
            fh.write(text)
        if os.path.exists(path):
            os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        else:
            os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def apply(target: str) -> bool:
    """Bring TARGET/.gitattributes up to date; True when the file changed."""
    if not os.path.isdir(target):
        raise BlockError("%s is not a directory" % target)
    path = os.path.join(target, FILE_NAME)
    if os.path.islink(path):
        raise BlockError("%s is a symlink — left alone; add the vibe-flow block by hand" % path)
    old = read_text(path)
    new = render(old)
    if new == old and os.path.exists(path):
        return False
    write_atomically(path, new)
    return True


def main(argv: List[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: attributes.py TARGET\n")
        return 2
    try:
        apply(argv[1])
    except (BlockError, OSError) as exc:
        sys.stderr.write("attributes.py: %s\n" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
