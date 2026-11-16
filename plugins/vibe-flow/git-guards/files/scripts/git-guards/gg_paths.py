"""gg_paths.py — one path model for the kit's Python, identity on macOS/Linux.

Why a module: on native Windows (Git Bash) the same directory reaches the hooks as
`C:\\x`, `C:/x` or `/c/x`, `~` means HOME (Git Bash) but os.path.expanduser reads
USERPROFILE, `ntpath.isabs('/c/x')` changed between 3.12 and 3.13, and
`commonpath` across drives raises. Every decision that compares paths goes through
these few functions, so the answer is the same whatever form a path arrives in.

Contract (K6 in the vibe-flow 1.3.0 plan; the guard and its tests rely on it):
  - path functions never raise; `None` means "cannot tell", and every caller takes
    the denying branch on it;
  - on macOS/Linux the path functions are identity (to_native) or plain posixpath;
  - cmd_name() is the same on EVERY OS: APFS and NTFS are case-insensitive, so
    `GIT`, `git.exe` and `/usr/bin/git` all run git;
  - cygpath is started only on Windows, only for a leading `/` that is not a drive
    (`/tmp/x`), lazily and at most once per distinct path (lru_cache): the guard
    runs on every tool call, and a process start costs tens of milliseconds there.

_configure() is the test seam: it switches the whole module to Windows or POSIX
behaviour (ntpath / posixpath) with an injected cygpath, so the Windows logic is
tested on macOS and Linux too.
"""
from __future__ import annotations

import functools
import ntpath
import os
import posixpath
import re
import subprocess
import sys
from typing import Callable, Optional

CYGPATH_TIMEOUT = 5          # seconds; a hung cygpath must not hang the hook
CYGPATH_CACHE_SIZE = 256
EXE_SUFFIX = ".exe"

_MSYS_DRIVE = re.compile(r"/([A-Za-z])(?=/|$)")      # /c or /c/... (Git Bash form)
_DRIVE = re.compile(r"[A-Za-z]:")                    # C: — absolute or drive-relative
_DRIVE_ABS = re.compile(r"[A-Za-z]:/")               # C:/ — after slashes are unified
_WIN_ABS = re.compile(r"(?:/|[A-Za-z]:[\\/])")       # /x, C:/x, C:\x (UNC is //x after to_native)

# The current mode. Public for readers (the guard branches on it); changed only by
# _configure(), the test seam.
WINDOWS = sys.platform == "win32"


def _run_cygpath(path: str) -> Optional[str]:
    """`cygpath -m <path>` → C:/Long/Form, or None on any failure."""
    proc = subprocess.run(["cygpath", "-m", path], capture_output=True, encoding="utf-8",
                          errors="surrogateescape", timeout=CYGPATH_TIMEOUT,
                          stdin=subprocess.DEVNULL)
    out = proc.stdout.strip()
    return out if proc.returncode == 0 and out else None


class _Mode:
    """The module's configuration; every function reads it at call time."""

    def __init__(self) -> None:
        self.windows = WINDOWS
        self.path = ntpath if WINDOWS else posixpath
        self.cygpath: Callable[[str], Optional[str]] = _run_cygpath


_mode = _Mode()


def _configure(windows: bool, cygpath: Optional[Callable[[str], Optional[str]]] = None) -> None:
    """Test seam: Windows (ntpath) or POSIX (posixpath) behaviour, with this cygpath."""
    global WINDOWS
    WINDOWS = bool(windows)
    _mode.windows = WINDOWS
    _mode.path = ntpath if WINDOWS else posixpath
    _mode.cygpath = cygpath if cygpath is not None else _run_cygpath
    _cygpath_cached.cache_clear()


def _upper_drive(path: str) -> str:
    return path[0].upper() + path[1:] if _DRIVE.match(path) else path


@functools.lru_cache(maxsize=CYGPATH_CACHE_SIZE)
def _cygpath_cached(path: str) -> Optional[str]:
    try:
        out = _mode.cygpath(path)
    except Exception:            # noqa: BLE001 — any failure means "cannot tell"
        return None
    if not isinstance(out, str):
        return None
    out = out.strip().replace("\\", "/")
    if not (_DRIVE_ABS.match(out) or out.startswith("//")):
        return None
    return _upper_drive(out)


def home() -> str:
    """HOME first (Git Bash sets it), then the OS's own idea of the home directory."""
    return os.environ.get("HOME") or os.path.expanduser("~")


def _to_native_windows(path: str) -> Optional[str]:
    if path == "~" or path.startswith(("~/", "~\\")):
        path = home() + path[1:]
    elif path.startswith("~"):
        return None                          # ~user: no reliable answer on Windows
    unified = ntpath.normpath(path).replace("\\", "/")
    msys = _MSYS_DRIVE.match(unified)
    if msys:
        return msys.group(1).upper() + ":" + (unified[2:] or "/")
    if _DRIVE.match(unified):
        return _upper_drive(unified)
    if unified.startswith("//"):             # UNC: \\server\share
        return unified
    if unified.startswith("/"):              # an MSYS path that is not a drive: /tmp/x
        return _cygpath_cached(unified)
    return unified                           # relative: the caller joins it to a base


def to_native(p: str) -> Optional[str]:
    """The path in this OS's native form; None = cannot tell (the caller denies).

    POSIX: p unchanged. Windows: `~` from home(), normpath first, `/x/...` →
    `X:/...`, `X:\\...` kept; any other leading `/` through cygpath. The result
    uses forward slashes and an upper-case drive letter."""
    if not isinstance(p, str):
        return None
    if not _mode.windows:
        return p
    if not p:
        return None
    try:
        return _to_native_windows(p)
    except Exception:            # noqa: BLE001 — never raises, by contract
        return None


def is_abs(p: str) -> bool:
    """Windows: `/...`, `X:/...`, `X:\\...`; POSIX: posixpath.isabs."""
    if not isinstance(p, str):
        return False
    if _mode.windows:
        return bool(_WIN_ABS.match(p))
    return posixpath.isabs(p)


def same_path(a: str, b: str) -> Optional[bool]:
    """Do a and b name the same file (realpath + normcase)? None = cannot tell.
    Different drives compare unequal instead of raising."""
    try:
        if not (isinstance(a, str) and isinstance(b, str)) or not a or not b:
            return None
        # No file name holds a NUL; realpath before 3.10 swallows the error and answers.
        if "\0" in a or "\0" in b:
            return None
        if _mode.windows:
            a, b = to_native(a), to_native(b)
            if a is None or b is None:
                return None
        pm = _mode.path
        return pm.normcase(pm.realpath(a)) == pm.normcase(pm.realpath(b))
    except Exception:            # noqa: BLE001 — never raises, by contract
        return None


def posix_rel(p: str, base: str) -> Optional[str]:
    """p relative to base with forward slashes; None if p is outside base, on
    another drive, or anything fails."""
    try:
        if not (isinstance(p, str) and isinstance(base, str)) or not p or not base:
            return None
        if _mode.windows:
            p, base = to_native(p), to_native(base)
            if p is None or base is None:
                return None
            if ntpath.splitdrive(p)[0].casefold() != ntpath.splitdrive(base)[0].casefold():
                return None
        pm = _mode.path
        rel = pm.relpath(p, base)
        if _mode.windows:
            rel = rel.replace("\\", "/")
        if rel == ".." or rel.startswith("../") or pm.isabs(rel):
            return None
        return rel
    except Exception:            # noqa: BLE001 — never raises, by contract
        return None


def cmd_name(word: str) -> str:
    """The program a command word runs, on EVERY OS: basename on both separators,
    casefolded, one trailing `.exe` stripped. "C:\\Program Files\\Git\\cmd\\git.exe"
    → "git", "BASH.EXE" → "bash", "scripts\\Git-Confirm.SH" → "git-confirm.sh"."""
    name = str(word).replace("\\", "/").rstrip("/").split("/")[-1].casefold()
    return name[:-len(EXE_SUFFIX)] if name.endswith(EXE_SUFFIX) else name
