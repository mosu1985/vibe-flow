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

- `bash`, `git` and `python3` are required. Windows without WSL/Git Bash is not supported — say so plainly. Verified on macOS; on Linux/WSL the mechanism works but has not been run — if something fails, report it to the package author.
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

**Then — push the installation to the prod branch (if there is a remote).** These are tools, not product code: there is nothing for the gate to review, and after the session restarts this commit would become "someone else's". So the push is done by a human, without hooks — give the ready command:
- there is a remote: `! git push -u origin <GG_PROTECTED> --no-verify`
- no remote: say the first push (once they connect GitHub) is the same command; until then the gate and the barriers have nothing to compare push against

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
then restart the session and run this skill from step 3: the installer will update the scripts and the rules block, and will not touch `.gitguards.conf` or the "Project" section. Commit the updated files (step 8).

**All projects on this machine at once** (the vibe-flow repository is cloned locally): `tools/rollout-projects.sh plugins` updates the plugins in every install; then `list` (show the user the changes and the rules-block diff, ask "Apply this rules text?") → `GG_ROLLOUT_SHA=<sha> … prepare` → `vibe-flow:release-gate` on each worktree → ask "Merge into every project? This is a production deploy for: <projects with auto-deploy>" → `GG_ROLLOUT_SHA=<sha> … ship`.
