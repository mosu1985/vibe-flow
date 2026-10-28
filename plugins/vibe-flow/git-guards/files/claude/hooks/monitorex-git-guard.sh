#!/usr/bin/env bash
# monitorex-git-guard.sh — PreToolUse (Bash): запрет `git add` и `git commit`
# в ОБЩЕМ рабочем дереве.
#
# ЗАЧЕМ ОТДЕЛЬНО ОТ GIT-ХУКОВ. У git нет хука на `git add` — именно поэтому
# первая редакция схемы не работала: сосед успевал застейджить файл, пока шёл
# чужой коммит. Хук Claude Code видит команду ДО запуска и может её отклонить.
# Git-хуки остаются backstop-ом для человека в терминале, Codex и IDE, которые
# этот слой не проходят вовсе.
#
# Разбор сегментов команды — библиотека из session-coordination-kit
# (автор Pavlo Rudomotov): умеет `cd` по цепочке, `bash -c`, subshell, `||`,
# пайпы. Своя реализация была бы заведомо хуже.
#
# FAIL-OPEN на любой поломке инфраструктуры (нет python3, битый ввод, не
# git-каталог): предохранитель не должен ломать работу, когда сам не уверен.
set -u
command -v python3 >/dev/null 2>&1 || exit 0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
[ -f "$DIR/monitorex_git_guard.py" ] || exit 0
exec python3 -B "$DIR/monitorex_git_guard.py"   # -B: без __pycache__ в проекте
