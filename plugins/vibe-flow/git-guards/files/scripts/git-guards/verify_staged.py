#!/usr/bin/env python3
"""Сверка списков путей git по NUL-протоколу.

Зачем не shell: `git diff --name-only` при core.quotePath C-квотит кириллицу
и необычные имена, `sort`/`diff` ломаются на переводе строки внутри имени,
а pathspec-каталог раскрывается в несколько файлов. Всё это в проекте
встречается — пути вида `дир/файл с пробелом.txt` живые.

Читает NUL-разделённый список с stdin.

  --expect <пути…>     stdin ⊆ ожидаемых. Каждый путь из stdin обязан быть
                       либо ровно одним из аргументов, либо лежать внутри
                       аргумента-каталога. Лишний путь → rc=1 со списком.
  --intersects <пути…> Есть ли пересечение stdin с аргументами.
                       Есть → rc=0 (для `if` в shell), нет → rc=1.
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
        print("нужен режим: --expect | --intersects", file=sys.stderr)
        return 2

    mode, expected = sys.argv[1], sys.argv[2:]
    actual = read_nul()

    if mode == "--expect":
        extra = [p for p in actual if not covered_by(p, expected)]
        if extra:
            print("🔴 в коммит попали пути, которых не просили:", file=sys.stderr)
            for p in extra:
                print(f"     {p}", file=sys.stderr)
            print("   Это чужая работа — коммит остановлен.", file=sys.stderr)
            return 1
        return 0

    if mode == "--intersects":
        hit = [p for p in actual if covered_by(p, expected)]
        if hit:
            print("🔴 пересечение с чужими изменениями:", file=sys.stderr)
            for p in hit:
                print(f"     {p}", file=sys.stderr)
            return 0     # пересечение ЕСТЬ
        return 1         # пересечения нет

    print(f"неизвестный режим: {mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
