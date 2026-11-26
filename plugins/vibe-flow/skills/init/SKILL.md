---
name: init
description: Deploy or update vibe-flow in the current project — git-guards (a worktree per task, safe commit, git hooks, bypass prohibition), the release-gate final gate before push, the rules block in CLAUDE.md and a "Project" section with the stack and commands. Use when the user writes "/vibe-flow:init", "set up vibe-flow", "install the flow in this project", "update vibe-flow".
---

# Deploy vibe-flow in a project

The user invoked the installation themselves — that is consent to write files into the project. Commit and push — only on a separate explicit "yes" (step 8). Talk to the user in their language.

## 1. Check the project

```bash
git rev-parse --show-toplevel && git rev-parse --git-dir --git-common-dir && git log --oneline -1 && git remote -v
```

- `bash`, `git` and Python 3.9+ are required. Supported: macOS, Linux, Windows **via WSL 2**, and native Windows through **Git for Windows (Git Bash)**, which is in **beta** until students confirm it. The protection suite runs in CI on Ubuntu, macOS and Windows. `lsof` is optional (free-port detection and dev-server cleanup in worktrees).
- **Native Windows:** the installer proceeds in Git Bash (`uname` reports MINGW). Python must be a real 3.9+ from python.org, not the Microsoft Store `python3` alias (it only opens the Store). In an **MSYS2 or Cygwin** shell (`uname` reports MSYS / CYGWIN) the installer stops before writing anything and says: use Git for Windows (Git Bash) or WSL 2. Relay that to the user in their language, and say plainly that the plugin's agents and skills still work without the git protection. There is no switch to force an unsupported shell through.
- **The install ends with a guard self-test** that really tries a forbidden command and fails loudly when the guard does not block on this machine (for example a broken Python). Do not continue past a failed self-test: tell the user why it failed and what to fix, then rerun init.
- **The session sits in a linked worktree** (git-dir ≠ git-common-dir) → install into the main tree: take the path `git-common-dir/..`.
- **Not a git repository, or no commits** → ask via `AskUserQuestion`: "Run `git init` and make a first commit?". No → stop. Yes:
  1. `git init`, if needed
  2. Append to `.gitignore` (create it if missing) whatever is missing from the standard set for the stack: `.env*`, `node_modules/`, `.venv/`, `venv/`, `__pycache__/`, `dist/`, `build/`, `.next/`, `.DS_Store`, `*.log`
  3. Show the user what will go into the commit: `git add -A --dry-run | head -50` and the total file count. If anything looks suspicious (keys, big binaries, DB dumps) — ask before committing
  4. `git add -A && git commit -m "[chore]: first commit"` — there is no vibe-flow hook yet, so this is allowed here

## 2. Ask one decision

Via `AskUserQuestion` (one question):
- **Final gate before push** — "Enable (Recommended)": every push is first checked by the `vibe-flow:release-gate` agent on Opus — that is minutes and Opus tokens per push, but code from any model never leaves unreviewed. "Disable": it can be enabled later with the line `GG_RELEASE_GATE=1` in `.gitguards.conf`.

## 3. Run the installer

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" "<project root>"            # gate enabled
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" "<project root>" --no-gate  # gate disabled
```

Bash timeout — 600000: the installer runs the protection acceptance tests. A non-zero exit code, or a non-zero failure count in the test summary printed at the end — investigate and tell the user; do not continue silently.

## 3b. Session store

The installer's `vibe-flow: session store` section says `status=affected` when Claude Code's session data folder (auto memory, saved tool outputs, transcripts) is reached through a link into a protected `.claude` directory. That is the usual layout of a launcher that gives each profile its own `CLAUDE_CONFIG_DIR` and links its `projects` back to `~/.claude/projects`. For a write through such a link, auto mode does not let the classifier decide: it stops and asks a person, and neither allow rules nor auto-mode rules lift it. Every time an agent cleans up its memory or slices a saved tool output with `sed`, it waits for a click, so agents cannot work unattended. Prompts saying "…which is a sensitive file… resolves through a symlink…" are this case.

`status=ok` → nothing to do, go on. `status=affected` → ask via `AskUserQuestion`:
- **"Move the session data out of `.claude` (Recommended)"**: the folder is renamed on the same disk to `~/claude-projects`, a link stays in its old place, memory and history stay shared. It is machine-wide: it covers every project, current and future. One command undoes it; `fix` prints that command.
- **"Leave as is"**: the prompts stay.

On a "yes" (the folder holds all the user's sessions, so only on an explicit one):
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/session-store.py" fix --yes
```
(`python` or `py -3` where `python3` is missing). Exit 0 — say it is done, give the user the printed undo command, and say that tabs which still prompt need a restart. Exit 4 — nothing changed: it refused or rolled back and printed why (target exists, another disk, the link leads to `.claude` as a whole, Windows); relay that and offer `--to <dir>` on the same disk where it fits. Exit 5 — the folder was moved but is not linked yet (a running session recreated it, or the link failed and moving back failed too); relay the printed recovery steps word for word and do not retry blindly. Any other exit — show the output and stop.

## 4. Check `.gitguards.conf`

The installer detected the stack itself. Read the file and compare it with the project:
- `GG_TEST_CMD` — the command to which `git-safe-commit.sh` **appends the list of committed files** and waits for the run of the tests related to them (`npx vitest related --run`, `npx jest --findRelatedTests`). If the project has no such command — leave it empty: the `vibe-flow:test-runner` agent then runs the tests. Do not put `npm test` or `pytest` here: with paths as arguments they would run the wrong thing
- `GG_TYPECHECK_CMD`, `GG_DEV_CMD` — do they really exist in the project (scripts in package.json etc.)?
- `GG_WT_DIR` — the worktrees directory; empty = `<project folder>-wt` next to the project, which is right for a new project. 🔴 If the project already has worktrees somewhere else (`git worktree list`) — set their directory explicitly, otherwise `wt-done.sh` will not see them and will not remove them normally
- `GG_PROTECTED` — the branch prod is deployed from (`main`/`master`)

Fix anything wrong in the file and tell the user what was fixed.

## 5. Fill in the "Project" section in CLAUDE.md

vibe-flow agents take the facts about the project from here. Study the project (manifest files, structure, deploy configs, DB, i18n) and write the section **OUTSIDE** the `vibe-flow:begin/end` block — right before it — between its own markers:

```markdown
<!-- vibe-flow:project:begin -->
## 🧩 Project
- **What it is:** <one phrase>
- **Stack:** <language, framework, version>
- **DB:** <none / Postgres (Supabase) with RLS / SQLite / …>
- **Deploy:** <none / Vercel / Docker / …> · prod branch `<GG_PROTECTED>`
- **Commands:** tests `<…>` · types `<…>` · dev `<…>` · build `<…>`
- **Where things live:** <3–6 items: entry points, API, UI, shared logic, migrations>
- **i18n:** <none / locales …>
- **Access control:** <none / roles … / tenants …>
<!-- vibe-flow:project:end -->
```

Only facts verified against files. If you don't know — "not determined", and tell the user. If the section already exists → update what is stale, do not rewrite it whole.

🔴 **Older installs:** if the existing section is titled `## 🧩 Проект` (the previous Russian-language version), rename the heading to `## 🧩 Project` and keep the content (translate the field labels to the English ones above only if you are updating them anyway; do not discard the user's data).

## 6. Code map

Has `node` → `node "${CLAUDE_PLUGIN_ROOT}/skills/architecture-map/gen-codemap.mjs"`, then per the `/vibe-flow:architecture-map` skill write a short `docs/codemap/ARCHITECTURE.md`. No `node` → only `ARCHITECTURE.md`, written from reading the project.

## 7. Suggest packages and tools

- `vercel.json`, a `.vercel/` directory or a `vercel` dependency → the `vibe-flow-vercel` package (deploy monitor, logs): `/plugin install vibe-flow-vercel@vibe-school`
- a `supabase/` directory or a `@supabase/supabase-js` dependency → the `vibe-flow-supabase` package (DB agent, migrations): `/plugin install vibe-flow-supabase@vibe-school`
- no `gh` (GitHub CLI) → Claude cannot make PRs and merges, and will give links instead. Install: https://cli.github.com → `gh auth login`
- `codex` in PATH → the external plan critic works; warn: **the plan and code fragments go to a second provider (OpenAI)**. Not there → "The external plan critic is not installed — plans are checked only by Claude reviewers. Install: `npm i -g @openai/codex` and `codex login`"

## 8. Commit the installation — MANDATORY, before restart

🔴 Without this commit, worktrees (`scripts/wt-new.sh`) are created from HEAD **without** the scripts, hooks and rules — the flow does not work in them. Tell the user this and ask for a "yes" for the commit:

```bash
git status --short     # show to the user
scripts/git-safe-commit.sh --message-file <file> -- scripts githooks .claude/hooks .claude/settings.json .gitguards.conf CLAUDE.md docs/codemap .gitignore
```

(paths — only those actually created/changed by the installation; do not touch the user's other uncommitted files). Message: `[chore]: vibe-flow — git protection, gate and rules`.

If refused → do not commit, but warn plainly: "worktrees will not work until these files are in a commit".

**Then — push the installation to the prod branch.** These are tools, not product code: there is nothing for the gate to review, and after the session restarts this commit would become "someone else's". So the push is done by a human, without hooks:
- `origin` already has the prod branch (`git ls-remote --heads origin <GG_PROTECTED>` prints a line): give the ready command `! git push -u origin <GG_PROTECTED> --no-verify`
- no `origin`, or `origin` has no prod branch yet: go to step 8b — this is the first push, and 8b gives the command only after its checks. Until then the gate and the barriers have nothing to compare push against

## 8b. GitHub repository — private, checked before the first push

Every project works through GitHub: the deploy agent pushes the branch, merges a PR and then syncs the project's main folder. Runs on install and on update. 🔴 8b is the only place that gives the first-push command: other agents and rules send the user here. 🔴 Never print the `origin` address — an HTTPS remote can carry an access token; print only the host and `<owner>/<repo>`.

```bash
cd "<project root>" && { git remote get-url origin >/dev/null 2>&1 && echo origin=yes || echo origin=no; } \
  && { git ls-remote --heads origin <GG_PROTECTED> 2>/dev/null | grep -q . && echo base=yes || echo base=no; }
```
- `origin=yes base=yes` → the first push is done: skip 8b.
- `origin=no` → part A, then part B.
- `origin=yes base=no` (a new repository, or init run again after a failure) → part B.

### A. Create a private repository
1. `command -v gh && gh auth status` — no `gh` or not logged in → tell the user how to install it (https://cli.github.com) and run `gh auth login`, and that without GitHub the deploy agent cannot work; stop 8b.
2. **Owner** = the active `gh` account: `gh api user --jq .login`. Show it in the question and pass it explicitly — a student may have several accounts.
3. **Name** = the project folder name, normalized; empty → ask the user. Pass it only in single quotes:
   ```bash
   printf '%s' '<folder name>' | LC_ALL=C sed -E 's/[^A-Za-z0-9._-]+/-/g; s/-+/-/g; s/^[-.]+//; s/[-.]+$//'
   ```
4. 🔴 **An existing repository is never connected.** `gh repo view '<login>/<name>' --json visibility` exits 0 → it exists (maybe public, maybe with someone else's history): ask the user for another name. Connecting an existing repository is the user's own action, outside init. A non-zero exit whose error does not contain `Could not resolve to a Repository` (network, auth) → stop with the error, create nothing.
5. `AskUserQuestion`: "Create a private GitHub repository `<login>/<name>`?" — "Create (Recommended)" / "Not now". 🔴 An external write: only after this "yes". "Not now" → warn that deploys stay manual until there is a repository; stop 8b.
6. `gh repo create '<login>/<name>' --private --source "<project root>" --remote origin` — an empty private repository and the `origin` remote; nothing is pushed. Then part B.

### B. Before the first push — every check must pass, otherwise stop without the push command
1. **The host is GitHub** — print only the host and `<owner>/<repo>`:
   ```bash
   cd "<project root>" && u=$(git remote get-url origin 2>/dev/null) \
     && printf 'host=%s repo=%s\n' \
        "$(printf '%s' "$u" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://([^/@]*@)?([^/:]+).*#\2#; s#^[^@/:]+@([^:/]+):.*#\1#')" \
        "$(printf '%s' "$u" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://[^/]*/##; s#^[^@/]+@[^:/]+:##; s#/+$##; s#\.git$##')"
   ```
   Host (compared case-insensitively) ≠ `github.com` → stop: "`origin` is not on GitHub — its visibility cannot be checked and the deploy agent does not work with it". An SSH host alias (`git@github.com-work:…`) also stops here: say so, and that the user can check visibility and run the first push themselves.
2. 🔴 **Private:** `gh repo view '<owner>/<repo>' --json visibility --jq .visibility` prints exactly `PRIVATE`. Anything else, or an error → stop.
3. 🔴 **The push goes there too:** `git remote get-url --push --all origin` gives exactly one address, and parsed the same way it is the same host and `<owner>/<repo>` (case-insensitive). Do not print it. Otherwise stop: a separate push URL could lead to a public mirror.
4. **Secret files in the history** — every path that ever existed in the prod branch, including merge commits and both names of a rename (`--diff-filter=A` and `rev-list --objects` both miss some), plus the tracked files:
   ```bash
   cd "<project root>" && . scripts/git-guards/pyenv.sh && gg_python && set -o pipefail && { git -c core.quotePath=false log refs/heads/<GG_PROTECTED> -m --no-renames --name-only --format= -z && git ls-files -z; } | "$GG_PY" -I -c '
   import re, sys
   names = {p for p in sys.stdin.buffer.read().decode("utf-8", "replace").split("\0") if p}
   bad = re.compile(r"^(\.env(\..*)?|access\.md|.*credentials.*|.*secret.*|id_.*|kubeconfig|.*\.(pem|p12|key|keystore)|service[-_]account.*\.json)$")
   fine = re.compile(r"^(\.env\.(example|sample)|id_.*\.pub)$")
   for p in sorted(names):
       b = p.rsplit("/", 1)[-1].lower()
       if bad.match(b) and not fine.match(b):
           print(p)
   '
   ```
   Python comes from the kit's resolver (`gg_python`: `python3`, `python`, `py -3`, skipping the Microsoft Store alias), never a bare `python3`. A non-zero exit → stop (no Python, or the history could not be listed) and say which. Files found → show the list and warn: after the push they stay in the GitHub history even if deleted later — rotate those keys or clean the history first. Then `AskUserQuestion`: "Clean up first (Recommended)" / "Push anyway". The decision is the user's.
5. Only now — the first-push command for the human (tools, not product code; see step 8): `! git push -u origin <GG_PROTECTED> --no-verify`.

## 9. Report

Release-note format: ✅ what was deployed · 🎯 what changed in the way of working · 🧪 what to try. Must include:
- 🔴 **Restart the Claude Code session** — the hook that forbids `git add`/`commit` in the main tree is picked up at startup
- How to start a task: describe it to Claude — it will create a worktree (`scripts/wt-new.sh <name>`) and offer to open a new session in it (`cd <path> && claude`)
- Where the rules are: the vibe-flow block in `CLAUDE.md`; your own rules — outside its markers

## Update

"Update vibe-flow":
```
/plugin marketplace update vibe-school
/plugin update vibe-flow@vibe-school          (and the stack packages, if installed)
```
then restart the session and run this skill from step 3: the installer will update the scripts and the rules block, and will not touch `.gitguards.conf` or the "Project" section. Commit the updated files (step 8), then step 8b: a project without GitHub, or without its first push, gets it there.

**All projects on this machine at once** (the vibe-flow repository is cloned locally): `tools/rollout-projects.sh plugins` updates the plugins in every install; then `list` (show the user the changes and the rules-block diff, ask "Apply this rules text?") → `GG_ROLLOUT_SHA=<sha> … prepare` → `vibe-flow:release-gate` on each worktree → ask "Merge into every project? This is a production deploy for: <projects with auto-deploy>" → `GG_ROLLOUT_SHA=<sha> … ship`.
