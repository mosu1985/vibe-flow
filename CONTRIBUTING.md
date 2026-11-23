# How vibe-flow works and how to modify it

vibe-flow is a Claude Code development environment extracted from a live
project and stripped of its specifics. It must deploy into ANY project:
any language, framework, database, hosting (or none of them).

## Repository layout

```
.claude-plugin/marketplace.json     the "vibe-school" marketplace (three plugins)
plugins/vibe-flow/                  core, for any stack
  agents/*.md                       agents (invoked as vibe-flow:<name>)
  skills/<name>/SKILL.md            skills (invoked as /vibe-flow:<name>)
  skills/init/                      /vibe-flow:init, deploys the flow into a project
  scripts/                          scripts referenced by agents/skills
  templates/CLAUDE.flow.md          rules block that init writes into CLAUDE.md
  git-guards/                       parallel-session protection, the source of truth
plugins/vibe-flow-vercel/           package for projects on Vercel
plugins/vibe-flow-supabase/         package for projects on Supabase
tools/rollout-projects.sh           roll the current git-guards out to projects on this machine
tools/git-guards-known-blobs.txt    git-guards file versions from before it moved here
```

## Rules for agents and skills

1. **Language: English**, with the same tone and structure as the sources
   (emoji markers on headings, 🔴 for hard rules, short bullet points).
   Agents talk to the user in the user's language, and a confirmation
   ("yes", "push", "deploy") counts in any language. Section headings that
   other agents look for (`## 🧩 Project`, `## 🔬 Verify live`,
   `## 🧪 Test impact`…) are a contract: rename them only in every file at once.
2. **No specifics of any particular project.** Forbidden: names of projects,
   clients and their integrations; names of the author's machines and
   personal tools; cloud project ids, team names, tokens; paths and functions
   of a specific codebase, migration numbers; phrases like "user decision
   from <date>". A rule is stated as a rule, without a date or author.
3. **Keep the "why it's like this" stories, anonymized.** "A predicate on the
   wrong <system> field passed nine reviews" → "a predicate on the wrong
   field of an external API passed nine rounds of plan review and reached
   production". These are the main value: they explain to the student why
   the rule exists.
4. **Don't assume a stack.** Not "Next.js + Supabase", but "if the project
   has a database with RLS…", "API routes (in Next.js `app/api/**/route.ts`,
   in Express routers…)". Where project specifics are needed, take them from:
   - the `## 🧩 Project` block in `CLAUDE.md` (stack, commands, where things
     live), written by `/vibe-flow:init` (older installs title it
     `## 🧩 Проект`);
   - `.gitguards.conf` in the root: `GG_TEST_CMD`, `GG_TYPECHECK_CMD`,
     `GG_DEV_CMD`, `GG_PROTECTED` (protected branch), `GG_WT_DIR`.
   No data → the agent detects it from project files (package.json,
   pyproject.toml, go.mod, Gemfile…) and says what it detected.
5. **Agent names carry the plugin prefix** when one agent/skill/rule tells
   you to launch another: `vibe-flow:release-gate`,
   `vibe-flow:security-reviewer`, `vibe-flow-vercel:vercel-deploy-monitor`.
   In the frontmatter `name:` field, WITHOUT the prefix (Claude Code adds it).
6. **Agent frontmatter:** `name`, `description` (with `<example>` examples;
   Claude uses them to decide when to call the agent), `model`, `effort`,
   `tools`, `color`. The `hooks`, `mcpServers` and `permissionMode` fields
   are ignored for plugin agents; don't use them.
7. **Plugin files** (scripts, templates, rubrics) are referenced via
   `${CLAUDE_PLUGIN_ROOT}` (substituted into the agent/skill text on load):
   `node "${CLAUDE_PLUGIN_ROOT}/scripts/wait-vercel-deploy.mjs" …`. Files next
   to SKILL.md via `${CLAUDE_SKILL_DIR}`. These variables do NOT exist in the
   Bash environment, only as substitutions in the text.
8. **Secrets come only from the environment**, never in argv, in `-e` code,
   or in output. Keep this rule in the agents.
9. **External tools are optional.** Codex CLI, Vercel CLI, the Claude in
   Chrome browser extension: the agent checks whether the tool is present
   and, if not, honestly returns "unavailable: <why> — <what to do>" instead
   of making up a result.
10. **Deploys and anything irreversible only after an explicit "yes" from
    the user.** Keep this rule in every agent that pushes, merges or
    migrates.

## Updating git-guards

The mechanism lives in `plugins/vibe-flow/git-guards/`: edit it there and bump
`version`. Projects keep their own copies, so a fix reaches an installed project
only through `tools/rollout-projects.sh` or the next `/vibe-flow:init`.

The rollout replaces a project file only if it equals a known version of the
canonical file. Never delete `tools/git-guards-known-blobs.txt`: without it, every
older project file looks edited by the project and stops getting updates.
Run `bash tools/test-rollout-projects.sh` after changing the rollout, and
`bash tools/test-admin-only-merge.sh` after changing `plugins/vibe-flow/scripts/admin-only-merge.sh`
(the only `gh pr merge --admin`, used by `push-to-production` and the rollout).

## CI and portability

Every push runs `.github/workflows/test.yml`: the git-guards suite and the Node
tests on Ubuntu and macOS (`posix`), the guard cases under the Python 3.9 floor on
Ubuntu and macOS (`floor`), the suite on native Windows in Git Bash (`windows`), and
the rollout and admin-only-merge tests on Ubuntu (`rollout`, its own job because the
rollout test runs the suite inside every prepared project). Merge only when `posix`,
`floor`, `windows` and `rollout` are green.

The scripts must run with both GNU tools (Linux, WSL, Git Bash) and BSD tools (macOS):

- **No BSD-only or GNU-only flags.** mtime: `stat -c %Y f 2>/dev/null || stat -f %m f`,
  GNU first, because GNU `stat -f %m` prints filesystem info instead of failing;
  treat a non-numeric result as unknown. Temp files: `mktemp "${TMPDIR:-/tmp}/name.XXXXXX"`,
  never `mktemp -t name` (GNU requires the X's). In-place edits: `sed … > tmp && mv`,
  never `sed -i ''`.
- **A temp file that replaces a shared file with `mv`** is created next to it
  (same filesystem), so the rename stays atomic.
- **Test fixtures name their branch** (`git symbolic-ref HEAD refs/heads/main`):
  git's own default is still `master`, and macOS only looks like `main` because of
  Apple's system gitconfig.
- To reproduce the other platform locally, the suite has PATH shims (`mkshim`);
  on a Mac, `brew install coreutils` and the `gnubin` directory first in `PATH`
  give real GNU tools.

## Windows rules

Native Windows runs the scripts in Git Bash (MSYS), where one directory has three
spellings (`C:/…`, `/c/…`, `C:\…`) and git prints `C:/…`. Rules for any change to
git-guards:

- **Paths** in shell: `gg_path` and `gg_is_abs` (`scripts/git-guards/paths.sh`);
  never compare or test raw path strings. In Python: `gg_paths.py` (`to_native`,
  `is_abs`, `same_path`, `posix_rel`, `cmd_name`).
- **A file at a revision** (the policy `.gitguards.conf` on the protected branch,
  any other blob): only through `gg_blob REV PATH`. Return codes: 0 found, 1 absent,
  2 error. Fall back to the tree's `.gitguards.conf` only on 1, never on 2.
- 🔴 **Never pass a `<rev>:<path>` argument to git.** Git Bash rewrites
  `origin/main:.gitguards.conf` as if it were a path list, and the read fails as a
  false "no such path".
- **Python** is found only through `scripts/git-guards/pyenv.sh` (`gg_python`
  exports `GG_PY`; hook wrappers use `gg_hook_exec`). Floor: Python 3.9. It sets
  `PYTHONUTF8`. The Microsoft Store alias (exit 9009, seen by Git Bash as 49) is
  not a Python and is skipped.
- **Hook output is ASCII JSON** (`ensure_ascii=True`). A deny that cannot be
  printed still exits 2, so a deny never turns into an allow.
- **Never `os.kill(pid, 0)`** to test that a process lives: on Windows it
  terminates the process. Use the platform check the hooks already carry.
- **Inlined blocks stay byte-identical.** Hooks and wrappers that cannot source
  `pyenv.sh` or `paths.sh` (the Claude hook wrappers, `pre-push`, `plan-gate.sh`) carry a marked copy (`gg-inline:pyenv`, `gg-inline:paths`).
  Edit the source in `scripts/git-guards/`, then update every copy: the suite's
  drift check compares them.
- **The `na` test helper** (a case that cannot run here) is allowed only on
  Windows and only for three reasons: `ln -s made a copy` (no symlink rights), `no shasum`,
  `noexec`. Anywhere else an N/A is a failure, so macOS and Linux run every case.

## Versions

Bump `version` in `plugins/*/.claude-plugin/plugin.json` on EVERY release,
otherwise students keep a cached copy.
