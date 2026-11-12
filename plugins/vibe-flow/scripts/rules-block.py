#!/usr/bin/env python3
"""rules-block.py — the vibe-flow rules block in a project's CLAUDE.md.

usage: rules-block.py <CLAUDE.md> <template> <version> [--check | --diff] [--append-if-missing]
                      [--follow-symlink-within=<dir>]

The block is the text between `<!-- vibe-flow:begin vX -->` and `<!-- vibe-flow:end -->`;
everything outside the markers belongs to the project and is never changed.
Used by init.sh (with --append-if-missing) and by tools/rollout-projects.sh.

Prints one status line:
  same                  the block equals the template (compared as a whole, not by version)
  update vA → vB        a block of another version
  edited vA             same version, but the text inside the markers was changed
  no-block              the file has no markers (left alone without --append-if-missing)
  missing               no file (left alone without --append-if-missing)
  symlink               CLAUDE.md is a symlink — not written through (init passes
                        --follow-symlink-within=<project> to write a target inside the project)
  appended / created    only with --append-if-missing
--check prints the status and writes nothing; --diff prints a unified diff of the block
(old → new) and writes nothing. A write is atomic: temp file in the same folder + rename.
"""
import difflib
import os
import re
import sys
import tempfile

PAT = re.compile(r"<!-- vibe-flow:begin([^>]*)-->.*?<!-- vibe-flow:end -->", re.S)


def build(template: str, version: str) -> str:
    with open(template, encoding="utf-8") as f:
        body = f.read().rstrip()
    return f"<!-- vibe-flow:begin v{version} -->\n{body}\n<!-- vibe-flow:end -->"


def write_atomic(path: str, text: str) -> None:
    folder = os.path.dirname(os.path.abspath(path))
    mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644
    fd, tmp = tempfile.mkstemp(prefix=".CLAUDE.md.", dir=folder)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main(argv: list) -> int:
    within = None
    for a in argv:
        if a.startswith("--follow-symlink-within="):
            within = os.path.realpath(a.split("=", 1)[1])
    flags = {a for a in argv if a.startswith("--") and not a.startswith("--follow-symlink-within=")}
    args = [a for a in argv if not a.startswith("--")]
    unknown = flags - {"--check", "--diff", "--append-if-missing"}
    if len(args) != 3 or unknown:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    path, template, version = args
    check, diff, append = "--check" in flags, "--diff" in flags, "--append-if-missing" in flags
    block = build(template, version)

    if os.path.islink(path):
        target = os.path.realpath(path)
        if within is None or os.path.commonpath([target, within]) != within or os.path.islink(target):
            print("symlink")
            return 0
        path = target
    exists = os.path.exists(path)
    text = open(path, encoding="utf-8").read() if exists else ""
    m = PAT.search(text)

    if m is None:
        if not append:
            print("no-block" if exists else "missing")
            return 0
        if text.strip():
            new, status = text.rstrip() + "\n\n" + block + "\n", "appended"
        else:
            new, status = "# Project rules\n\n" + block + "\n", "created"
        old_block = ""
    else:
        old_block = m.group(0)
        if old_block == block:
            print("same")
            return 0
        old_version = m.group(1).strip() or "v?"
        if old_version == f"v{version}":
            status = f"edited {old_version}"
        else:
            status = f"update {old_version} → v{version}"
        new = text[: m.start()] + block + text[m.end():]

    if diff:
        old_lines = (old_block + "\n").splitlines(keepends=True) if old_block else []
        sys.stdout.writelines(difflib.unified_diff(
            old_lines, (block + "\n").splitlines(keepends=True),
            fromfile="rules block (project)", tofile=f"rules block v{version}"))
        return 0
    if check:
        print(status)
        return 0
    write_atomic(path, new)
    print(status)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
