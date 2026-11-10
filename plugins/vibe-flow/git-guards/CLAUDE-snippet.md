Paste into the project's CLAUDE.md ("Git" section).

---

### 🔴 COMMIT RULE - CRITICAL

**A plain `git commit` in the main working tree is FORBIDDEN and rejected by a hook.**

- **Every session works in its own worktree.** The first action of a session
  that is going to change anything: `scripts/wt-new.sh <task-name>`
  (it may install packages for minutes — run it with an extended Bash timeout, up to 600000 ms)
- **Commit only like this:**
  `scripts/git-safe-commit.sh --message-file <file> -- <paths>`
  The git index is SHARED by the whole working tree, and there are several
  sessions; a careful `git add <paths>` doesn't save you from the race. The
  script builds the commit in an isolated `GIT_INDEX_FILE` and moves the branch
  with an atomic compare-and-swap
- **`git add` is rejected** by the PreToolUse hook: git has no hook of its own for `add`
- **Cleanup:** `scripts/wt-done.sh <name>` — stops dev, frees the port, closes
  this workspace's Orca tabs, removes the worktree. Refuses if the work is saved
  neither on a remote nor in the main branch. A bare `git worktree remove` leaves
  the dev server orphaned and the workspace hanging in the Orca sidebar
- **Bypasses — only out loud:** `scripts/git-confirm.sh <target>`, `MONITOREX_SKIP_TESTS=1`
- 🔴 **Bypass marks are set by a human, not an agent** (`git-confirm.sh`,
  `git-allow-push.sh add`, `git-allow-delete.sh add` — the hook rejects them from
  the model's Bash, `echo yes |` too). Show what will be allowed and ask the
  user to run it in the input line: `! scripts/<script> … --yes`
- **Merge / rebase / cherry-pick — only in your own worktree.** The hook looks
  at the tree where git actually runs (`git -C <wt>`, `cd <wt> && …`), so plain
  `git add`/`git commit` are allowed there. A commit with `MERGE_HEAD` requires
  the commit lock: `scripts/git-lock.sh take` → `git commit --no-edit` →
  `scripts/git-lock.sh drop` (hold the lock only for the duration of the commit)
- **Run the guard tests:** `bash scripts/test-git-guards.sh` (281 checks in a project)
- **Taking a GitHub issue:** `scripts/wt-new.sh --issue <N>` claims it locally
  (branch `wt/<N>-<slug>`); a second session with the same number is refused —
  continue the existing branch with `--resume`. `wt-done.sh` releases the claim
- **Old branch:** `scripts/wt-new.sh --resume <branch>` refuses a branch with old
  guards (its tree would reinstall old hooks); add `--merge-main`
- 🔴 **Don't abandon a branch.** Work lands in the main branch with a REWRITTEN
  SHA, so check membership **by content, not by hash**:
  `git log --format='%s' origin/main..<branch>` and search for the same lines in main
- 🔴 **`git push origin --delete <branch>` is blocked** by `pre-push`: a deletion
  sends a null ref, and the hook takes it for a foreign commit. Delete via
  `gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/<branch>`
- Settings for this project: `.gitguards.conf`. Mechanism: `plugins/vibe-flow/git-guards/` in the vibe-flow repository

### 📋 PLAN GATE (if the policy on origin has `GG_PLAN_*` keys)

- **A `[feat]` commit, or one adding a new file matching `GG_PLAN_REQUIRED_NEW`
  (e.g. a migration), needs a line `Plan: <plan-file>.md`** — a bare file name from
  `~/.claude/plans`. `pre-push` checks the approval mark written by the
  `plan-approved.sh` hook when the user approves `ExitPlanMode`; the plan must have
  a `Gate: ✅ passed` line and a `## … Codex` section — or, without Codex, the
  `| Codex …` gate-table row `⚪️ not installed` / `❌ unavailable — user's decision`. No mark → push refused
- **Work in another repository than the session's** (session in A, commits in B) — put
  `Репозиторий: ~/dev/B` (or `Repository: …`) in the plan **header**, above the first
  `## `, one repository per line; the hook writes the mark into B as well. Without it
  B's gate refuses the `[feat]` and only a human `git-confirm.sh feat` lets it through
- The model cannot write the mark (the guard forbids any write into `.git/`); the
  policy comes from `origin/<protected>`, so a branch cannot weaken it
- Bypass — by a human: `! scripts/git-confirm.sh feat --yes` (one push within 15 min)
- **Tests after an edit** (`GG_POST_EDIT_TESTS=1`): a red run of the related tests
  comes back as a `block` right after Edit/Write — fix it before going on

### 🚦 RELEASE GATE (if `.gitguards.conf` has `GG_RELEASE_GATE=1`)

- **Code is pushed only after a verdict from the `release-gate` agent** (global,
  Opus): after committing, run it on the worktree with the path to the plan.
  `pre-push` refuses without a verdict for the HEAD tree. Only `*.md` in the
  diff — no gate needed (masks are `GG_RELEASE_GATE_SKIP`; like the flag, they
  are read from the protected branch's `.gitguards.conf` on the remote — the
  working branch's config doesn't change them)
- The verdict is bound to **content**: any change means a fresh review. ❌ → fix,
  commit, run again; at most 3 rounds
- 🔴 **Only the agent itself sets the verdict:** the hook lets
  `scripts/release-gate.sh pass` through only with `agent_type=release-gate`.
  Bypass — by a human: `! scripts/release-gate.sh override --yes`
- `scripts/release-gate.sh status` — is there a verdict · `scope` — what gets reviewed
- 🔴 **`git push --no-verify` is forbidden to the model by a hook** (and so is
  `-c core.hooksPath=…`): it disables typecheck, barriers and the gate at once.
  A human can use it via `!`
