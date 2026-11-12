# vibe-flow

A Claude Code development environment, battle-tested on a live production project.
Installs into any project in a couple of minutes.

## What you get

```
Task
  └─ 📋 Plan ── reviewers: security · performance · access · tests
               └─ external critic on a different model (Codex, if installed)
               └─ gate: no open critical/high issues → you approve the plan
  └─ 🔀 Implementation ── Claude itself or a crew of agents,
                          each with its own model and effort (Opus / Sonnet / Haiku)
  └─ 🧪 Tests → commit in its own worktree
  └─ 🚦 release-gate ── Opus reads the ENTIRE branch diff; without its ✅ git won't allow the push
  └─ 🚀 "Push?" ── only after your "yes" → deploy → deploy monitor
```

- **The plan is checked by several reviewers**, and it doesn't go into work while they still have serious concerns
- **Code from any model is checked before push**: enforced by a git hook, not by a promise
- **Parallel Claude sessions don't get in each other's way**: each has its own worktree, commits go through an isolated index, other sessions' files never end up in your commit
- **The model can't bypass the checks on its own**: `--no-verify`, self-approval and bypass marks are blocked by a hook; bypasses are for humans only

## Installation

**Vibe Coding School students** (with the knowledge base MCP connected): one phrase in Claude Code, in your project folder:

> Install vibe-flow from the school knowledge base

Claude will read the article, show you the plan and install everything. Manually, in Claude Code, in your project folder:

```
/plugin marketplace add mosu1985/vibe-flow
/plugin install vibe-flow@vibe-school
/vibe-flow:init
```

`init` sets up git protection, writes the rules into `CLAUDE.md`, studies the project and describes its stack, and at the end asks permission to commit the installation. **Say yes**: without that commit, worktrees won't get the scripts. After it, **restart your Claude Code session**.

Stack packages (optional; `init` will tell you whether you need them):

```
/plugin install vibe-flow-vercel@vibe-school     # project on Vercel
/plugin install vibe-flow-supabase@vibe-school   # project on Supabase
```

**Required:** Claude Code, `git`, `bash`, `python3`. Tested on macOS; Linux and Windows via WSL use the same mechanism but haven't been tested. No git repository? `init` will offer to create one.
**Optional:**
- GitHub CLI `gh` (`gh auth login`): lets Claude create and merge PRs itself
- Codex CLI (`npm i -g @openai/codex` → `codex login`): a second, independent plan critic. The plan and code fragments are sent to OpenAI
- Claude in Chrome extension: checks in the browser

## How to work

1. Describe the task. Claude creates a separate worktree for it (`scripts/wt-new.sh <name>` → folder `<project>-wt/<name>`) and suggests opening a new session there: `cd <path> && claude`. This way tasks and parallel sessions don't interfere with each other
2. Complex task: Claude switches to plan mode, runs the plan through the reviewers and shows you a simplified version. Approve it, and Claude implements it alone or assembles a crew of agents
3. Tests, commit and the final `release-gate` check happen automatically
4. "Push the branch?" → "yes" → push. Separately: "Merge into main? This is a deploy" → "yes" → PR and merge

See started tasks: `scripts/wt-status.sh`. Close a finished one: `scripts/wt-done.sh <name>`.

**The first push to a new GitHub repository** is done by you: `! git push -u origin main --no-verify`. While GitHub is empty, the checks have nothing to compare against.

## Only a human can

Commands are typed in the Claude Code prompt with `!`, from the folder of the worktree being pushed (`! cd <path> && …`):

| What | Command |
|---|---|
| Skip the final check | `scripts/release-gate.sh override --yes` |
| Skip the plan gate for one `[feat]` push (15 minutes) | `scripts/git-confirm.sh feat --yes` |
| Push without any checks | `git push --no-verify` |
| Allow pushing commits from a previous session or ones you made in the terminal | `scripts/git-allow-push.sh add <sha> --yes` |

The last one is common: after a Claude restart, push calls your own commits from yesterday "not created by this session". This protects your push from other people's work; review the list and allow it.

Other human-set marks follow the same rule (the hook rejects them from the model): `scripts/git-allow-delete.sh add … --yes` and `scripts/git-confirm.sh <target> --yes`. For a `[feat]` commit without an approved plan the bypass is `! scripts/git-confirm.sh feat --yes` (one-off, 15 minutes).

## Plan gate, red-first tests, issue claims

- **Plan gate.** A `[feat]` commit (and any commit that adds a new migration) must carry a `Plan: <file>.md` trailer; the installed `pre-push` checks it. A plan counts as approved when you approved it in `ExitPlanMode` and it contains the Codex critic section and the gate line. The approval mark is written by a Claude Code hook into the git common-dir of the project **where the session was started**: a plan about another repository (for example vibe-flow, planned from a session in your app) gets its mark in the wrong place. The gate catches forgetfulness, not deception: renaming the commit type bypasses it, and deception is what `release-gate` reads in the diff.
- **Red first.** For a bug fix in logic or a new pure function: test, run, see it red, then the code. This is not checked automatically; it holds on the plan reviewer (`### 🔴 Red first` in the plan) and on the `test-runner` report.
- **Tests after an edit.** With `GG_POST_EDIT_TESTS=1` a hook runs related tests after a file edit and can return `block` with the tail of the run. A run takes several seconds and delays the turn; with many parallel sessions some edits are only checked at commit.
- **Issue claims are local.** `scripts/wt-new.sh --issue N` claims GitHub Issue N on one machine only: two machines know nothing about each other's claims. `wt-done.sh` releases it.
- **Measuring the plan procedure.** `tools/measure-plan-cost.mjs` counts tokens, money and time of Plan Mode from session transcripts.

## Updating

```
/plugin marketplace update vibe-school
/plugin update vibe-flow@vibe-school
```
Then restart the session and run `/vibe-flow:init` again.

Re-running `init` updates the scripts and the rules block without touching your settings (`.gitguards.conf`) or your own text in `CLAUDE.md`.

### Update every project on this machine at once

From the vibe-flow repository, after the release is merged into `main`:

```
tools/rollout-projects.sh plugins        # the plugins in every install — no repo changes
tools/rollout-projects.sh list           # pins origin/main, shows changes and the rules-block diff
GG_ROLLOUT_SHA=<sha from list> tools/rollout-projects.sh prepare   # a worktree + commit per project
# vibe-flow:release-gate on every prepared worktree
GG_ROLLOUT_SHA=<sha from list> tools/rollout-projects.sh ship      # PR + merge = a production deploy
```

One run rolls out exactly the commit `list` showed — never the working tree and never a newer `main`. The rules block is markdown, which release-gate skips, so read the diff `list` prints before `prepare`. A `CLAUDE.md` kept outside git is written on `ship`, with a backup.

## Contents

**Core `vibe-flow`**: agents plan-reviewer, security-reviewer, performance-reviewer, access-control-reviewer, test-impact-reviewer, codex-plan-critic, orchestration-router, team-planner, orchestrator, release-gate, senior-backend-engineer, test-runner, dev-server-restart, commit-and-ask, push-to-production, browser-operator, discovery-interview. Skills: `init`, `plan-mode-review`, `architecture-map`, `smoke-ui`.

**`vibe-flow-vercel`**: vercel-deploy-monitor, vercel-logs-reader and log skills.
**`vibe-flow-supabase`**: supabase-admin and a safe migrations skill.

Everything is written in English; agents talk to you in your own language.

How it works inside and how to modify it: [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[CC BY-NC 4.0](LICENSE) © mosu1985 (Vibe Coding School).

- ✅ You may use vibe-flow as a working environment in your own projects, including commercial ones.
- ✅ You may fork and modify it, provided you credit the author and link to this repository.
- 🚫 You may not sell or commercially distribute vibe-flow or any of its parts (agents, skills, scripts, rules), including on skill marketplaces.
