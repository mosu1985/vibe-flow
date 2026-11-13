# git-guards

Parallel-session protection for any project: a worktree per session,
commits through an isolated index, barriers on commit and on push.

Extracted from a production project's set (September 2026), where
it grew out of real incidents: on 06.08 seven staged files ended up in someone
else's commit, on 02.09 a push carried off a neighbouring session's commit, and
on 08.09 a shared branch had piled up 18 foreign commits and 311 uncommitted
files from five different tasks.

## New machine

The source of truth is this directory of the vibe-flow repository. The `git-guards-deploy` agent looks for it at `~/dev/vibe-flow/plugins/vibe-flow/git-guards`, so that's where to clone it:

```bash
git clone https://github.com/mosu1985/vibe-flow.git ~/dev/vibe-flow
mkdir -p ~/.claude/agents
cp ~/dev/vibe-flow/plugins/vibe-flow/git-guards/files/claude/agents/git-guards-deploy.md ~/.claude/agents/
```

The second step installs the **`git-guards-deploy`** subagent — the entry point.
After that, in any project it is enough to tell the session "deploy git-guards",
and it does the rest: checks prerequisites, runs `install.sh`, reviews the
acceptance run and adds a section to `CLAUDE.md`. The agent ships with the set
on purpose: without it there is nobody to call on a new machine, and its
instructions are part of the mechanism, not a note.

🔴 **Pull the canonical copy before deploying** (`git -C ~/dev/vibe-flow pull
--ff-only`). Otherwise a stale version ends up in the project. Make changes to
the mechanism here and only here: the copy inside a project is overwritten by
the next `install.sh`, and the work is lost.

## What gets installed

| File | What it does |
|---|---|
| `githooks/pre-commit` | Rejects `git commit` in the **main** working tree: the index there is shared |
| `githooks/pre-push` | Fast-forward required, the protected branch cannot be deleted, foreign commits don't get pushed, types are checked, the plan gate runs. Security policy is read from `origin/<protected>:.gitguards.conf` line by line — never `source`d from the tree |
| `githooks/plan-gate.sh` | Plan gate: a `[feat]` commit, or one adding a file matching `GG_PLAN_REQUIRED_NEW` that the protected branch does not have yet, needs `Plan: <name>.md` with an approval mark. Installed next to `pre-push`, so a branch cannot weaken it; `git-safe-commit.sh` calls it early (non-authoritative) |
| `githooks/prepare-commit-msg` | Stamps `Session-Id: <actor>` on commits git itself creates (`git merge`, `git commit --no-edit` under `MERGE_HEAD`, a plain commit in a worktree), so updating a lagging branch from the protected one does not look like foreign work to `pre-push`. An existing `Session-Id` is never replaced; rewrites (amend, cherry-pick, rebase, `merge --squash`) are not stamped |
| `scripts/git-safe-commit.sh` | Commit in an isolated `GIT_INDEX_FILE` + branch move via atomic compare-and-swap |
| `scripts/wt-new.sh` | Session workspace: its own directory, branch, dev server on a free port |
| `scripts/wt-done.sh` | Cleanup. Won't delete a worktree holding work that exists neither on a remote nor in the protected branch. Closes Orca tabs if Orca is on the machine |
| `scripts/wt-status.sh` | What's unfinished: branches with work outside the main branch, and separately — work that exists nowhere else. Run by the `SessionStart` hook, so every session sees the list before its first action |
| `scripts/git-lock.sh` · `git-recovery.sh` | Locks and recovery of commits that didn't land on the branch |
| `scripts/git-confirm.sh` · `git-allow-push.sh` · `git-allow-delete.sh` | Deliberate bypasses: a commit in the main working tree, foreign commits, intentional file deletion from the protected branch |
| `scripts/git-guards/` | 🔴 A dependency, not "utilities": `verify_staged.py` and `consumer-warn.sh` are called by safe-commit, `shell_segments.py` is imported by the harness hook |
| `.claude/hooks/monitorex-git-guard.sh` | PreToolUse: forbids Claude Code from running `git add` (git has no hook of its own for `add`), any write into `.git/` (Write/Edit/NotebookEdit, redirections, `rm`/`cp`/`mv` into `monitorex-locks/` and `monitorex-hooks/`), `git -c url.*/remote.*`, moving `refs/remotes/*`, and `git push` while the installed hooks differ from origin |
| `.claude/hooks/plan-approved.sh` + `plan-approved.py` | PostToolUse on an approved `ExitPlanMode`: writes the plan approval mark. Trusts only `tool_response` (file inside the plans directory, `isAgent: false`, a `Gate: ✅ passed` line in the approved text). The external critic is settled by a `## … Codex` section, or — **without Codex** — by the `\| Codex …` gate-table row saying `⚪️ not installed` (and codex is really absent: PATH and the standard locations) or `❌ unavailable — user's decision`; then the user also gets a notice. Without Codex the gate goes by the Claude reviewers. The mark goes to the session's repository and to every repository the plan names in its header (`Репозиторий: ~/dev/x` / `Repository: …`, one per line, above the first `## `) — main working trees inside `$HOME` with the kit installed, at most 5; the user is told where (1.2.5) |
| `.claude/hooks/post-edit-tests.{sh,py}` | PostToolUse on Edit/Write: runs the tests related to the edited file and hands a red result back to the model at once. Fail-open; one run per repository, pauses, a time ceiling that kills the whole process group, secrets masked in the output |
| `files/claude/agents/git-guards-deploy.md` | Installer subagent. Installed into `~/.claude/agents/` by hand (see "New machine"); `install.sh` doesn't touch it — it is global, not per-project |

## Installation

```bash
bash ~/dev/vibe-flow/plugins/vibe-flow/git-guards/install.sh /path/to/project
```

The installer copies the files, detects the stack, writes `.gitguards.conf`,
**merges** the harness hook into the existing `.claude/settings.json`, installs
git hooks into `$GIT_COMMON_DIR/monitorex-hooks` (outside the checkout) and runs
the acceptance tests.
🔴 **Red acceptance = the deployment did not happen**, not "a minor issue".

Hooks are installed from `origin/<protected>`, not from the working tree: a hook
edited in a branch reaches the installed set only after it is merged. A project
whose protected branch has no `githooks/pre-push` yet gets a bootstrap install from
the tree, said out loud (`monitorex-hooks/.source` = `origin@<sha>` or `bootstrap@<sha>`).

## Acceptance

```bash
bash files/scripts/test-git-guards.sh     # from this directory: 438 checks
bash scripts/test-git-guards.sh           # in a project: fewer (settings-merge, detect, install.sh are not copied there)
```

Everything runs in temporary repositories; the plans directories (`~/.claude/plans`,
the project's `plansDirectory`) are replaced by a temporary `GG_PLANS_DIR` and a swapped `HOME`, `gh` and the test runner by stubs. The PreToolUse guard's
224 unit cases (`scripts/git-guards/test_pretooluse_guard.py`) count as one check.

Idempotent: re-running updates the code and leaves `.gitguards.conf` alone.

## Configuration — `.gitguards.conf`

An empty value everywhere means "the project has no such thing", and the check
says out loud that it is skipped. A made-up value is more dangerous than an
empty one: a nonexistent command in `GG_TYPECHECK_CMD` makes push impossible,
and it will look like a broken hook.

**How it is read.** The file is data, never code: no script or hook `source`s it.
The text comes from the protected branch — `origin/<protected>:.gitguards.conf`
(the branch is `origin/HEAD` → `main` → `master`; for another name run
`git remote set-head origin -a`), without an origin ref from the committed config
of local `main`/`master`. The main working tree's file is read only while the
branch has no config yet (a project adopting the kit). So an edit takes effect
**after it is merged** into the protected branch, and a branch's own copy changes
nothing. Each value is the last `KEY=` line; quotes work as in the shell
(`'…'` literal, `"…"` with `\$ \" \\ \`` un-escaped), nothing is evaluated —
`$PORT` in a command stays text and is expanded when the command runs. Only a
leading `$HOME/` or `~/` in `GG_WT_DIR` is expanded. A value of the wrong shape is
ignored with a warning, and the default is used. The reader for the scripts is
`scripts/git-guards/conf.sh`.

| Key | Meaning |
|---|---|
| `GG_WT_DIR` | Where to put worktrees. Empty → `<repo parent>/<repo name>-wt`. A leading `$HOME/` or `~/` is expanded |
| `GG_PROTECTED` | Branch that cannot be deleted or rewound. Read only without an origin ref: with origin the branch is `origin/HEAD` → `main` → `master` |
| `GG_TEST_CMD` | Test runner on commit. Paths are passed positionally |
| `GG_TYPECHECK_CMD` | Typecheck on push. 🔴 Empty — nobody checks types |
| `GG_DEV_CMD` · `GG_DEV_PORT_BASE` · `GG_DEV_PORT_ENV` | Dev server of a new worktree |
| `GG_DEV_READY_GLOBS` · `GG_REQUIRE_DEV_READY` | "Build is warmed up" marker. For Next it is `.next/types` — without them `tsc` silently checks less and still says "ok" |
| `GG_DEV_PROC_MATCH` | Part of the dev process name — so cleanup can kill an orphan |
| `GG_RELEASE_GATE` · `GG_RELEASE_GATE_SKIP` | The final gate before push (`1` = on); masks of files that need no review, default `*.md`. An empty value means the default. To skip nothing — `GG_RELEASE_GATE_SKIP=" "` |
| `GG_FETCH_TIMEOUT` | Seconds `wt-new.sh` waits for `git fetch` before falling back to local refs. Default 20 |
| `GG_PLAN_REQUIRED_TYPES` · `GG_PLAN_REQUIRED_NEW` · `GG_PLAN_GATE` | Plan gate: commit types that need a plan (default `feat`), masks of new files that need one (e.g. `supabase/migrations/*.sql`), the early check for `git-safe-commit.sh`. Any of these keys on origin turns the gate on |
| `GG_PLAN_APPROVAL_TTL_DAYS` · `GG_PLAN_GATE_EXEMPT` | Age limit of an approval mark (30 days); full SHAs of old commits let through once at rollout (not a date — `GIT_COMMITTER_DATE` is easy to fake) |
| `GG_POST_EDIT_TESTS` · `GG_POST_EDIT_CMD` · `GG_POST_EDIT_GLOBS` | Tests right after an edit: on/off, command (default `GG_TEST_CMD`), path masks. Pauses `GG_POST_EDIT_DEBOUNCE` (20 s per tree), `GG_POST_EDIT_REPO_GAP` (10 s), ceiling `GG_POST_EDIT_MAX` (90 s). Read from origin |
| `GG_ISSUE_TIMEOUT` | Seconds `wt-new.sh --issue` waits for `gh`. Default 15 |
| `GG_DEPS_INSTALL_CMD` | Package install for a new worktree when cloning `node_modules` is not safe. Empty → by lockfile (`npm ci`, `pnpm install --frozen-lockfile`, …) |

Autodetect: `vitest`/`jest` → test runner, `scripts.typecheck` or `typescript`
→ typecheck, `next` → readiness marker and `GG_REQUIRE_DEV_READY=1`,
`vite` → no marker. The branch is taken from `origin/HEAD`.

## Daily cycle

```bash
scripts/wt-status.sh                      # what's already started (the hook shows the same at session start)
scripts/wt-new.sh <task>                  # own worktree and branch from a FRESH origin/main, dev on its own port
scripts/wt-new.sh <task> <base>           # from a different base: branch, tag, commit
scripts/wt-new.sh --resume wt/<branch>    # return to work in progress (refused if the branch carries old guards; add --merge-main)
scripts/wt-new.sh --issue 42              # claim GitHub issue #42 locally, branch wt/42-<title-slug>; a second claim is refused
scripts/git-safe-commit.sh --message-file <file> -- <paths>
git push -u origin wt/<task>              # → preview build, production domain untouched
git push origin HEAD:main                 # → production
scripts/wt-done.sh <task>                 # cleanup; refuses if the work isn't saved anywhere
```

### The new branch's base is a fresh origin, not the main working tree

Until 06.11.2026 `wt-new.sh` forked the branch off `HEAD` of the main working
tree. But merging happens on GitHub (`gh pr merge`), and nobody pulls the local
main branch after a merge. The main working tree quietly fell several PRs
behind, and every new task started from old code, missing the changes of
neighbouring branches that had already been merged. The result: re-fixing
things that were already fixed, and merge conflicts.

Now the script runs `git fetch origin <GG_PROTECTED>` itself and picks the base:

| Situation | Base |
|---|---|
| local branch is behind (the usual case) | `origin/<GG_PROTECTED>` + a `pull --ff-only` hint for the main working tree |
| local is ahead (unpushed commits) | local — commits are not lost |
| diverged | `origin/<GG_PROTECTED>` + a warning about how many local commits won't be included |
| no network or access | whatever is available locally, + a warning |
| no `origin` | local branch |

The branch is created with `--no-track`: otherwise its upstream would become `origin/main`.

Two consequences, fixed on 07.11.2026:

- **Dependencies.** `node_modules` used to be cloned from the main folder whenever
  the lockfiles matched. With the tree based on fresh origin, the main folder's
  packages can be stale: the lockfile changed on GitHub (the tree got no
  `node_modules` and the dev server started for nothing), or the main folder was
  pulled without reinstalling (a current lockfile over old packages). Now a clone
  happens only if the lockfiles match **and** the main folder's packages are newer
  than its lockfile (`node_modules/.package-lock.json`, `.modules.yaml`,
  `.yarn-integrity`); otherwise packages are installed in the tree. If the install
  fails, the dev server is not started and the script says how to install by hand.
- **Fetch runs first.** It now happens before the "already started" check, which
  compares branches with `origin/main`: against a stale ref, branches already
  merged on GitHub looked unfinished. Fetch has its own watchdog
  (`GG_FETCH_TIMEOUT`): macOS has no `timeout`, and on a dead route git waited for
  the system TCP timeout (~75 s).

## Rolling an update out to projects

Projects keep their own copy of the kit, so a fix here reaches nobody by itself.
`tools/rollout-projects.sh` finds every project on this machine that has the kit
(`GG_ROLLOUT_ROOTS`, default `~/dev ~/orca/projects`):

```bash
tools/rollout-projects.sh list      # what would change in each project
tools/rollout-projects.sh prepare   # worktree wt/gg-update + commit in each project
# vibe-flow:release-gate on each worktree — pre-push requires its verdict
tools/rollout-projects.sh ship      # push, PR, merge, pull the main folder, reinstall hooks
```

These commands run from the vibe-flow repository root. A project file is replaced
only if it equals some historical version of the canonical file: one from this
repository's git history or from `tools/git-guards-known-blobs.txt`, which keeps the
versions from before the kit moved here. A file the project edited itself is
reported and left alone.
`GG_ROLLOUT_SESSION_URL` adds a session link to commits and PR descriptions.
`ship` merges into the protected branch — a production deploy wherever it is
automatic. Bumping `version` in `plugins/*/.claude-plugin/plugin.json` delivers the
same change to plugin users.

## About the `monitorex` name

The lock directory (`$GIT_COMMON_DIR/monitorex-locks`), the ref namespace
(`refs/monitorex/recovery/*`), the `MONITOREX_*` variables and the harness hook
name are deliberately left as they are: renaming would touch all 17 files and
the live state of already deployed projects, just for cosmetics.

## Why every barrier has a bypass

A barrier without a deliberate bypass doesn't make the system stricter — it
makes it impassable, and a human reaches for `--no-verify`, which removes
**all** checks at once. That's what happened with the deletion guard before
10.09.2026: the advice "rebase" doesn't help when the base is fresh and the
deletion is intentional. So every barrier has its own narrow bypass, confirmed
by a human and single-use:

| Barrier | Bypass |
|---|---|
| commit in the main working tree | `scripts/git-confirm.sh commit` |
| foreign commits in a push | `scripts/git-allow-push.sh add <sha…>` |
| push deletes files from main | `scripts/git-allow-delete.sh add <path…>` |
| tests on commit | `MONITOREX_SKIP_TESTS=1` |
| plan gate (`[feat]` / new migration without an approved plan) | `scripts/git-confirm.sh feat` — one push within 15 minutes |

Matching is by name: a mark for two paths won't allow deleting a third one that
accidentally landed in the same commit.

**Only a human sets a bypass mark.** A yes/no prompt doesn't stop an agent:
`echo yes | …` passes silently. That's why the PreToolUse hook rejects setting
a mark from the model's Bash tool (`add`, `commit`; `list`/`status`/`clear` are
allowed). The human runs the command themselves:

- in a regular terminal — as is, and answers `yes`;
- in the Claude Code input line — via `!` and with the `--yes` flag:
  `! scripts/git-allow-delete.sh add --yes <path…>`. The hook doesn't see this
  (commands via `!` bypass PreToolUse), and stdin there is not interactive:
  without the flag `read` gets EOF, and before 17.09.2026 the script silently
  exited without allowing anything.

## Three defects found during acceptance on 10.09.2026

The first two lived in the original set, the third in the Orca integration. All are fixed here.

1. **`wt-new.sh` didn't release the terminal.** `( cd "$D" && nohup dev > log 2>&1 & echo $! > pid )`
   parses as "background the `cd &&` pair". Because of `&&` the subshell doesn't
   `exec`, but waits for the server while holding the calling command's stdout;
   the pid file got the wrapper's pid. The form is fixed to `( cd … && exec … ) < /dev/null > log 2>&1 &`.
2. **`wt-done.sh` deleted a branch with unpushed work.**
   `UNPUSHED=$(git log "@{upstream}..HEAD" 2>/dev/null | wc -l || echo "?")`
   returns the status of `wc`, not of `git`. A fresh branch has no upstream, git
   silently printed nothing, the counter gave `0`, the "`?`" branch was
   unreachable — and cleanup removed the branch along with its commits. Now it
   counts commits that exist on no remote **and** not in the protected branch,
   without pipes.

3. **A closed workspace kept hanging in the Orca sidebar.** `wt-done.sh` stopped
   dev and removed the directory, but the terminal tabs stayed open: their shell
   held the deleted directory as its cwd (on macOS a folder lives as long as
   someone keeps it open), and Orca considered the workspace active. One
   machine's registry accumulated seven dead paths this way, removable only by
   hand. Now, before removing the directory, the script asks Orca to close that
   workspace's terminals.

   🔴 **The order is mandatory — before `git worktree remove`.** Orca identifies
   the workspace by path; once the directory is deleted its selector answers
   `selector_not_found`, and there is nothing left to close the tabs with. For
   tabs that have lost their workspace in the registry there is a fallback kill
   by handles from `orca terminal list`.

   Orca's command schema is `orca agent-context --json` (234 commands). `orca --help`
   shows only a small part and gives the impression that such commands don't exist.

   The step is best-effort: without `orca` or `python3` in PATH it stays silent,
   and cleanup works as before — the set installs on any machine.
