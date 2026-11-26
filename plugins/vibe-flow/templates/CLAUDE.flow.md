# ⚙️ vibe-flow — working rules

> This block is installed and updated by `/vibe-flow:init`. Edits inside the
> `vibe-flow:begin/end` markers are overwritten on update — write your own rules
> below or above the block.

## 🌍 Language
- Talk to the user in their language. A confirmation ("yes", "deploy", "+") counts in any language. "Push" alone means a push, not a deploy.

## 🚨 Critical rules

### 🚫 Deploy — only with the user's knowledge
- **NEVER** deploy or push to the protected branch without the user's explicit "yes" in the current conversation
- **ALWAYS** report that the work is ready and ask one question: **"Deploy `<short-sha>`? (push `<branch>` + merge into `<prod-branch>`)"**. One "yes" covers the push, the PR and the merge of THAT commit; a reply that names only the push ("push it", "push only") is a push without a merge
- **BEFORE** asking — get a ✅ verdict from `vibe-flow:release-gate` (see "Final gate")
- 🔴 **Consent is the user's own reply after the report**, to a question that names the merge and the prod branch. An option picked earlier in a menu ("smoke test, then deploy") is the order of work, not consent. A new commit after the "yes" → ask again: the "yes" is bound to the commit
- Irreversible actions (DB migrations, deleting data, mass mailings, writing to external services) also need the user's explicit "yes"

### 🔥 See it through
- Do not stop halfway: iterate until the problem is solved
- Do not report "done" without verifying the result (a test, a query, the browser)

### 🚨 Architecture is the user's decision
- Do not change or disable agreed decisions (security, deploy, CI, permissions) without approval
- If there are several approaches → propose the **TOP-3 options** (Essence, ✅ pros, ❌ cons, implementation) and **wait for the choice**. Start nothing until the user has chosen
- The task is simple and the solution is obvious → just do it

### 🚨 No temporary solutions
- No stubs, mocks or hardcoded values in production code. No data or table → a proper schema and a real data flow
- Not sure about the approach → ask, don't settle for "for now"

### 📄 No extra files
- Do not create reports, instructions or audits in the repository unless the user asks

### 🔐 Secrets
- Secrets live only in environment variables (`.env*` is in `.gitignore`)
- **Never** expose tokens in the command line, code, logs or commits: read them from the environment (`node --env-file=.env.local …`, `python -m dotenv …`)

## 💬 Communication
- Short and to the point; details when asked
- Task summary in release-note format: ✅ what was done · 🎯 what changed · 🧪 what to try
- Commits: `[type]: description`, types `feat`, `fix`, `docs`, `refactor`, `style`, `test`

## 🗺️ Code navigation
At the start of planning any task — use the `/vibe-flow:architecture-map` skill: refresh the code index, grep it, and only then read specific files. Blindly walking a large repository is expensive. No `node` → skip the index and read `docs/codemap/ARCHITECTURE.md`.

## 🌳 Work in your own worktree — CRITICAL
A task that changes anything is done in a separate git worktree, not in the project's main folder: that way parallel sessions and agents do not mix their edits.
1. **Start of the task:** first `scripts/wt-status.sh` — check whether it has already been started (then `scripts/wt-new.sh --resume <branch>`). Otherwise `scripts/wt-new.sh <task-name>` → branch `wt/<name>`, directory `<project>-wt/<name>`, its own dev port. It may install packages for minutes — run it with an extended Bash timeout (up to 600000 ms)
   - Task tracked as a GitHub Issue → `scripts/wt-new.sh --issue N` claims it (the claim is local, on one machine only)
2. **Where to work — pick one way and tell the user:**
   - 💡 **A new session in the worktree (simplest):** ask the user to open a new terminal and run `cd <path-to-worktree> && claude` — everything there works like in a normal project
   - **In the current session:** the worktree directory lies outside the project, and `cd` does not persist between commands. So EVERY command is `cd "<worktree>" && …`, files are addressed by absolute paths inside the worktree, and **every agent** gets the line `Worktree: <absolute path>` in its prompt. An agent without that line will stop and ask when there are several worktrees
3. **End of the task:** after the merge — `scripts/wt-done.sh <name>` (stops dev, frees the port, releases the issue claim, will not delete unsaved work)

## 🟢 Task size: S or the full procedure
Two levels only.
- 🟢 **S — the fast path, no Plan Mode and no plan reviewers.** Only when ALL of these hold:
  - the commit type is `fix`/`style`/`docs`/`refactor`/`test`/`chore` — **not `feat`**;
  - at most 2 code files;
  - no new migrations or schema changes, no new API routes, cron jobs, webhooks or integrations, no new sections or modules;
  - does not touch permissions, auth, RLS, tenant isolation, money or calculations.
- **S order:** worktree → code → tests (`test-runner`) → commit → **`release-gate`** → "Deploy `<sha>`?". The final gate and the user's yes before push apply to S too.
- 🔴 **Everything else — the full procedure** (Plan Mode below). In doubt — full. Size only grows: if an S task touches any item above — stop, go to Plan Mode.
- **The kit holds the line:** the plan gate in `pre-push` requires an approved plan for every `[feat]` and every new migration. Renaming the commit type to get into S is a bypass; `release-gate` catches it.

## 📋 Plan Mode — CRITICAL
**Right after the plan is written to a file, and BEFORE `ExitPlanMode`** — load the `/vibe-flow:plan-mode-review` skill and run it in full: live check of assumptions about external systems → the batch of reviewers in parallel → questions to the user → external critic (Codex, if installed) → gate.

🔴 Prohibitions that always apply:
- **DO NOT call `ExitPlanMode`** until the reviewers have finished and the user has read the simplified plan from `vibe-flow:plan-reviewer`
- **Reviewer questions** (`🔴 USER QUESTION REQUIRED`, `❓ DECISION NEEDED`) — ask via `AskUserQuestion` BEFORE `ExitPlanMode` and do not decide for the user. A test recommendation without the marker is applied as is, without a question
- **Verify assumptions about external systems live** (a query, a script) and write the fact into the plan, not "we'll check during implementation"
- **Gate by defect class:** the plan goes to implementation when no `critical`/`high` findings remain open. A finding without a failure scenario is `medium`; so is a rare coincidence with recoverable harm, unless it is a dangerous class (another user's or customer's data or actions, a bypass of auth, signature or permissions incl. fail-open, secrets, money, irreversible data loss, a deploy or an external write without a "yes"). At most 3 rounds; the external critic re-checks in rounds 2–3. After round 3, findings all folded or rejected with a fact → go on without a question; ask the user only when a finding needs their decision
- 🔴 **Plan gate on push:** a `[feat]` commit (and any commit that adds a new migration) carries the trailer line `Plan: <file>.md`. The installed `pre-push` checks it. A plan counts as approved when the user approved it in `ExitPlanMode` (the approval mark is written by a Claude Code harness hook, not by the model) and the plan contains the gate line plus the Codex critic section — or, **without Codex**, the gate-table row `| Codex … | ⚪️ not installed |` (Codex is not required: without it the gate goes by the Claude reviewers). It catches forgetfulness, not deception. Bypass — only by a human: `! scripts/git-confirm.sh feat --yes` (one-off, 15 minutes)
- 🔴 **A plan approved before its gate was finished gets no mark** (the hook says so right after `ExitPlanMode`), and repository files are closed to the session until it does. Finish the gate at once: the critic's section and the gate line into the plan, then `EnterPlanMode` → `ExitPlanMode`. Do not write the code first and ask for the bypass at commit time; a bypass request always quotes the gate's reason

## 🔀 Implementation — by the verdict of `vibe-flow:orchestration-router`
- ▶️ **Direct execution** → the main session does it itself
- 🔀 **Agent crew** → `vibe-flow:team-planner` lays it out in the `## 👥 Agent crew` section: for each agent a **model and effort**. Access control, money, external integrations, migrations — **always Opus**; Sonnet — work from a ready pattern. Launch: each group in one message with parallel Agent calls (`model` and `effort` parameters from the section, `Worktree: <path>` in the prompt), the next group after the results of the previous one. If the `TeamCreate` tool is available, you may use it
- ⚙️ **Workflow** → only on the user's explicit "yes"; no `Workflow` tool → use a crew or do it directly

## 🤖 Agents — launch without separate permission
The user grants in advance automatic launch of vibe-flow agents under these rules. Exceptions: `Workflow` — only on a "yes" in the current message; push/deploy — only on a "yes".

## 🔁 After implementation — the order
1. `vibe-flow:test-runner` — if code changed
2. Commit — only via `scripts/git-safe-commit.sh` (see "Git")
3. **`vibe-flow:release-gate`** — final review of the whole branch diff
4. `vibe-flow:dev-server-restart` — if the project has a dev server and code changed
5. Report to the user + one question: **"Deploy `<short-sha>`? (push `<branch>` + merge into `<prod-branch>`)"**
6. After a "yes": the deploy **only through `vibe-flow:push-to-production`** (quote the answer and the question): it pushes exactly that commit, then the plugin's `deploy-merge.sh` finds or creates the PR into the prod branch, waits for CI and merges pinned to the commit (`--match-head-commit`); under a `main-admin-only` ruleset it hands over to `admin-only-merge.sh`. "Push only" → the agent pushes without a merge. CI still running when the agent returns → re-run it with the same quote, unless the user has changed or cancelled the deploy since. No agent → do not push or merge yourself: give the user the commands `git push origin <full sha>:refs/heads/<branch>`, `gh pr create --fill --base <prod-branch> --head <branch>`, `gh pr merge <N> --merge --match-head-commit <full sha>`. Never `--admin` by hand (a git-guards hook denies it)
7. After the merge — the deploy monitor, if there is one (for example `vibe-flow-vercel:vercel-deploy-monitor`), then `scripts/wt-done.sh <name>`

**The first push to a new repository** (the remote has no prod branch yet) is done by a human: `! git push -u origin <prod-branch> --no-verify`. The gate and the barriers have nothing to compare against while the remote is empty — tell the user this plainly.

## 🚦 Final gate — CRITICAL
**Code goes to push only after the verdict of `vibe-flow:release-gate`** (Opus, effort `high`) — a review of the WHOLE branch diff against the protected branch, no matter who wrote the code.
- **When:** after the commit, BEFORE asking "Deploy `<sha>`?". In the prompt: the path to the worktree, the path to the plan file, who wrote the code, the round number
- 🔴 **Enforced by a hook:** `pre-push` refuses without a verdict for the HEAD tree (`GG_RELEASE_GATE=1` in `.gitguards.conf`). The verdict is bound to the **content**: after any edit — review again. If the diff has only `*.md`, no gate is needed
- **❌ fail** → fix, commit, run again. **At most 3 rounds**, then stop and sort it out with the user
- 🔴 **Only the agent itself sets the verdict.** The main session cannot approve its own code — the hook blocks it
- **Bypass — only by a human**, in the tree being pushed: `! cd "<worktree>" && scripts/release-gate.sh override --yes`. Offer it aloud and with a reason
- **No prod branch on the remote** (new repository) — the gate has nothing to compare against; first the human's first push (see "After implementation")
- Check: `scripts/release-gate.sh status` · what is reviewed: `scripts/release-gate.sh scope`

## 🌿 Git — parallel sessions — CRITICAL
**Plain `git add` / `git commit` in the main working tree are forbidden and rejected by a hook.** Several Claude sessions share one git index: files staged by one session end up in another's commit within seconds.
- 🔴 **Commit — EVERYWHERE only this way**, both in the main tree and in your own:
  `scripts/git-safe-commit.sh --message-file <file> -- <paths>` — isolated index, atomic branch move, run of related tests
- 🔴 **Why not a plain `git commit` even in your own tree:** `pre-push` treats as its own only commits carrying the current session's `Session-Id` mark, and only this script sets it. A bare commit will be rejected by push as "not created by this session"
- **Commits from a previous session, or ones you made in the terminal,** push will also call "not created by this session" — this is normal after restarting Claude. A human allows them after looking at the list: `! scripts/git-allow-push.sh add <sha…> --yes`
- **Worktree** — see "Work in your own worktree"; remove only with `scripts/wt-done.sh <name>`
- **Stuck lock:** `scripts/git-lock.sh release` · lost commits: `scripts/git-recovery.sh list`
- 🔴 **Bypass marks are set by a human, not an agent** (`git-confirm.sh`, `git-allow-push.sh add`, `git-allow-delete.sh add`, `release-gate.sh override`) — the hook rejects them from the model's Bash. Show what will be allowed and give the user a ready command: `! cd "<worktree>" && scripts/<script> … --yes`
- 🔴 **`git push --no-verify` is forbidden to the model by a hook** — it switches off the type check, the barriers and the gate all at once. For a human — via `!`
- 🔴 **Do not hide other people's work:** `git stash` of someone else's work is forbidden. A neighbor's dirty tree blocks the push → push from your own worktree
- **Delete a branch on the remote:** `gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/<branch>` (the hook refuses `git push --delete`)
- **Settings** (test/type/dev commands, protected branch, worktrees directory) — in `.gitguards.conf`
- Run the protection tests: `bash scripts/test-git-guards.sh`

## 🧪 Type check and tests
- If the project has a type check (`GG_TYPECHECK_CMD`), it runs on `pre-push`. A green deploy does not mean the types are fine if the build does not check them
- `vibe-flow:test-runner` — after every code implementation; it reports failures, the main session fixes them
- 🔴 **Red first** — for a bug fix in logic and for a new pure function: write the test → run it → **see it red** (put the output in the report) → only then the code. Not for integration tests that write to a shared database. This is not checked automatically: it rests on the plan reviewer (`### 🔴 Red first` in the plan) and on the `vibe-flow:test-runner` report
- 🔴 **Tests after an edit:** if an edit to a file returned `block` with the tail of a test run (the post-edit tests hook, `GG_POST_EDIT_TESTS=1`) — fix the cause before going on. Do not work around it: no skipping the test, no loosening the assertion to make it pass

## 🌐 Browser
- UI checks and work in web consoles — the `vibe-flow:browser-operator` agent (Claude in Chrome extension)
- Several browsers connected → ask the user which one, and pass the agent the `deviceId`
- App smoke test — the `/vibe-flow:smoke-ui` skill
- The agent does not type passwords; if the form is already filled in by the password manager, it may click "Sign in"
