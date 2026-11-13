---
name: plan-mode-review
description: Mandatory Plan Mode procedure — live verification of assumptions about external systems, a batch of plan reviewers (plan-reviewer, access-control-reviewer, test-impact-reviewer, security-reviewer, performance-reviewer, project domain reviewers; after the batch, in a separate message, orchestration-router), scores against a single rubric, an external critic on a different model (codex-plan-critic, if Codex CLI is installed), and a defect-class gate (open critical/high findings block the plan; the score is a metric), up to 3 rounds of auto-fixing, mandatory user questions and the plan format. Load IMMEDIATELY after the plan is written to a file and BEFORE calling ExitPlanMode.
---

# Plan Mode procedure

Copy the prohibitions ("do NOT call `ExitPlanMode` until…") into the project's `CLAUDE.md` as well, so they stay in force even if the skill fails to load.

**Order:** write the plan to a file → **verify assumptions about external systems live** (LIVE FACTS RULE) → launch the reviewer batch (in one message, in parallel), **each reviewer gives a score and a count of blocking findings per the rubric** → when the batch is back, run `vibe-flow:orchestration-router` **in a separate message** → ask the user the mandatory questions → `vibe-flow:codex-plan-critic` (external review on a different model, if Codex is installed) → **defect-class gate** → show the simplified plan + reviewer sections + the breakdown of the critic's findings + the orchestration verdict → `ExitPlanMode` only after approval.

🔴 **Two-model gate:** if Codex CLI is installed, the plan goes to implementation only when **neither the Claude reviewers nor the external critic have any open `critical`/`high` findings**. One model cannot wave a plan through alone. If Codex is not installed, the Claude reviewers hold the gate (see CODEX CRITIC RULE). The score is computed and shown but is not the gate; for why, see PLAN GATE RULE.

**Language:** talk to the user in the user's language (questions, the gate table, summaries). The plan file and the reviewer sections may stay in English; the user-facing simplified plan from `plan-reviewer` goes in the user's language.

---

## LIVE FACTS RULE

**Every plan must list its assumptions about external systems and verify them live — BEFORE the reviewers and BEFORE `ExitPlanMode`.**

**Where the rule comes from.** In one real plan, the predicate "the record belongs to the needed category" read the wrong field of an external API: one with a similar name but a different meaning, under which the needed record was indistinguishable from an unrelated one. This survived **nine review passes**: six Claude reviewers and three rounds of the external critic. Nobody could catch it, because checking required a live API request and reviewers read text. The plan honestly wrote "which field is right: check first thing during implementation", and everyone relaxed. The defect reached production and was caught by a browser smoke test. **Nine passes over the text did not replace one live request.**

**What counts as an assumption about an external system** is any claim about something that is not in our code and cannot be derived by reading the repository:

- the name, type or semantics of a field in an external API (payments, CRM, accounting system, telephony, mail, maps, LLM provider);
- what exactly an endpoint or report returns: the set of values, units, sign, time zone, whether taxes are included, whether there is pagination;
- what an entity is called in someone else's reference data (account, payment type, status, role);
- the actual state of production: whether a table has rows, how many users have a flag on, which values really occur.

**The `## 🔬 Verify live` section is mandatory in the plan** if such assumptions exist. The format is a table where every row is closed by a **fact**, not an intention:

```markdown
## 🔬 Verify live

| Assumption | How verified | Fact | What it affects |
|---|---|---|---|
| The "order paid" flag is the `status` field in the payments API response | `GET /orders/{id}` on a test order, key from the environment | ❌ wrong: `status` is the delivery status. Payment is carried by `payment.state = "captured"` | The "issue receipt" predicate: on the wrong field, an unpaid order would also get a receipt |
| The `beta_reports` flag is on for only two customers | DB query: select customers with the flag on | ✅ 2 rows | Feature reach, whether a data migration is needed |
```

- **"We'll check during implementation" does not fill a row.** That wording is exactly the defect: it moves the check to a place where nobody will demand it anymore
- **Checking is cheap:** an API request, a one-off script or a DB query. Minutes, versus a review round of tens of minutes. Examples:
  - API: `printf 'header = "Authorization: Bearer %s"\n' "$API_TOKEN" | curl -sS -K - https://api.example.com/v1/orders/123` — the token comes from the environment and lands neither in argv nor in shell history
  - DB: a one-off script that reads keys from the environment (`node --env-file=.env …`, `python` with `dotenv`, `psql` with `PG*` variables)
  - **Delete the temporary script** as soon as the fact is written into the plan
- 🔴 **Secrets only from the environment:** no literal tokens in `curl`, in `-e`/`-c` code or in arguments — they stay in shell history and in the session log
- 🔴 **A live check is read-only.** Writing to a live external system to verify an assumption requires the user's explicit "yes"
- 🔴 **The live check happens BEFORE the reviewer batch**, not after: reviewers must read the plan with the facts already filled in. Otherwise they will again just check the text for self-consistency
- **What cannot be verified** (no access, no test account, the effect is visible only after a write) — the row stays with an explicit `⚠️ not verified` and a **mandatory fallback** in the plan: what the code does if the assumption turns out to be wrong. An unverified assumption without a fallback is a blocking finding (`high` per the rubric)
- **Reviewers check completeness, not correctness:** their job is to notice an assumption that is missing from the table. Correctness has already been established by the fact
- **Self-exclusion:** a plan with no calls to external systems (pure refactoring, markup, translations) does not add the section

## REVIEW BATCH RULE

**AUTOMATICALLY** launch the reviewer batch after the plan is written to a file and the live facts are filled in, but **BEFORE `ExitPlanMode`** — **in one message, in parallel** (several Agent calls in one response), not sequentially. Give each one the path to the plan file and the rubric block (see PLAN SCORING RULE). `vibe-flow:orchestration-router` is **not part of** the batch — it runs **in a separate message after the whole batch has returned** (see below).

| Reviewer | What it checks | What it appends to the plan |
|---|---|---|
| `vibe-flow:plan-reviewer` | A plain-language retelling of the plan + TOP-3 options; completeness of the `## 🔬 Verify live` section | A short section with the score; the simplified plan goes in the reply |
| `vibe-flow:access-control-reviewer` | Who will see the new feature/section/data: roles, permissions, isolation between users/customers, RLS, enablement flags | `## 🔒 Access control` + a user question if needed |
| `vibe-flow:test-impact-reviewer` | Which tests to update, which to add, or that no tests are needed | `## 🧪 Test impact` |
| `vibe-flow:security-reviewer` | Vulnerabilities, authorization/authentication, injections, XSS, unsafe endpoints and webhooks, secrets | `## 🛡️ Security` |
| `vibe-flow:performance-reviewer` | Load: heavy queries, indexes, N+1, unfiltered subscriptions, background jobs with overlapping runs, caching, memory/CPU | `## ⚡ Performance` |
| Project domain reviewers | See below | Their own sections |
| `vibe-flow:orchestration-router` | **In a separate message after the batch** — what to implement the plan with | `## 🚀 Implementation orchestration` |

- 🔴 **Extension rule:** if the project's `.claude/agents/` has its own domain plan reviewers (their `description` says they review the plan in Plan Mode / before `ExitPlanMode`), launch them **in the same batch**, with the same rubric block. Self-excluding when the plan does not concern them is their own business
- `security-reviewer` and `performance-reviewer` **do not duplicate** each other: security is safety and permissions, performance is load
- 🔴 **Reviewers change the plan file ONLY via `Edit`** — append or replace their own section. `Write` on the plan file is forbidden: batch agents write to one file at the same time, and a whole-file overwrite wipes out the sections neighbors appended after the read. For a project domain reviewer that has `Write` in its `tools`, add this rule to its prompt
- 🔴 **No temporary files in the plans directory.** The plans directory is the project's `plansDirectory` (the kit sets `.plans`, git-ignored) or, in older installs, the Claude config directory (`~/.claude/plans`, sometimes reached through a symlink), where Claude Code asks for manual confirmation on every write — even in bypass-permissions mode. Either way it is not a scratch space. Copies, slices (`sed -n … >`), round snapshots and drafts go only to the session scratchpad (or `mktemp -d` if there is none); in the plans directory only the plan file itself changes, and only via `Edit`. If a reviewer wrote its section into its own agent plan file (`<plan>-agent-<id>.md`) instead of the main one, the main session moves the section with `Read` + `Edit` of the main plan — not with `cp`, `>` or `Write`. Give each reviewer the absolute path of the main plan file and tell it to edit that file, not its own
- A reviewer with nothing to check in the plan **self-excludes** ("✅ not required") — that is a normal outcome, not a failure
- **Report the results of all reviewers** to the user **BEFORE** `ExitPlanMode`, so the findings enter the plan before approval
- **Do NOT call `ExitPlanMode`** until every reviewer in the batch has finished

### 🧭 plan-reviewer

- **Goal:** rephrase the technical plan in plain language so the user can make changes BEFORE approving
- **Do NOT call `ExitPlanMode`** until the user has read the simplified plan from `plan-reviewer`
- **Add to the `plan-reviewer` prompt:**
  ```
  Check the "## 🔬 Verify live" section: did all of the plan's assumptions about
  external systems make it in, and is each closed by a fact rather than an
  intention? An assumption that stayed in the plan text and did not reach the
  table is a rubric deduction (−2.0 if access control or the data source depends
  on it, otherwise −1.0).
  ```

### 🔒 access-control-reviewer

- **Goal:** a new feature must not silently become visible to everyone — and must not silently end up visible to no one. The decision "who gets it enabled" is made **explicitly**
- 🔴 **ASK THE USER:** if the subagent returned the line `🔴 USER QUESTION REQUIRED`, the main session **MUST** ask the question via `AskUserQuestion`, taking `header`, `question` and all answer options (`options`) **verbatim** from the `### ❓ Question for the user` block in the plan file, and write the answer into the plan — **BEFORE** `ExitPlanMode`, so the decision makes it into implementation
- **Why the main session asks, not the agent:** `AskUserQuestion` is unavailable in subagents — the subagent only prepares the question
- **Do NOT decide for the user:** "enable for everyone" / "only for me" / "we'll sort it out later" without an explicit answer is forbidden
- 🔴 **Rollout order:** if access to the feature is switched on by data (a flag or a setting in the DB), the data migration is applied **first**, the code deploy **after**. The reverse order opens a window in which the feature is visible to the wrong people or switched off for everyone
- **Do NOT call `ExitPlanMode`** until `access-control-reviewer` has finished **and** (if it raised the marker) the user's answer is written into the plan

### 🧪 test-impact-reviewer

- **Goal:** at the plan stage (before code), determine the impact on tests — which to **update** (the plan changes the behavior of a covered function), which **new** ones to add (new pure logic / a regression test for a bug), or that tests are **not required**. If the project has no tests at all, say so honestly and propose a minimal start
- The subagent **does NOT write or change tests itself** — it only recommends
- 🔴 **Red first:** for a bug fix in logic or a new pure function the subagent must add `### 🔴 Red first` (test file, case, why it fails now); without it — `high`. The plan's `## 📌 Steps` then contains the step "test → red run → code". This is not checked automatically — it holds on this review and on the `test-runner` report
- 🔴 **ASK THE USER:** if the verdict is not "✅ not required", you **MUST** use `AskUserQuestion` to ask what to do (update existing / add new / both / skip) — **BEFORE** `ExitPlanMode`, and write the answer into the plan
- **Do NOT call `ExitPlanMode`** until `test-impact-reviewer` has finished and the user has decided what to do about tests

### 🚀 orchestration-router

- 🔴 Launch **IN A SEPARATE MESSAGE, after the whole reviewer batch has returned** — not in the same batch. Two reasons: it must see the sections the other reviewers have already appended (their edits change the scale of the work), and its write to the plan file must not coincide in time with theirs
- **Goal:** consciously choose the implementation mechanism — **Workflow** (a deterministic JS script), an **agent crew** (parallel groups of `Agent` calls) or **direct execution**
- It launches nothing and writes no scripts — it only recommends
- **GOTCHA:** Workflow **requires the user's explicit "yes"** — the router only advises

## PLAN SCORING RULE

**Every plan reviewer must give a score of 0–10 against a single rubric** — `${CLAUDE_SKILL_DIR}/rubric.md`.

- The package's reviewers know the rubric themselves, but **the main session appends the block below to the prompt of EVERY reviewer** — including the project's domain reviewers, who know nothing about the rubric:
  ```
  Read the rubric ${CLAUDE_SKILL_DIR}/rubric.md and finish your section with the
  line "**Score: X.X / 10** · blocking (critical/high): N" plus a "Deductions:"
  line listing every deduction and its weight. The score is derived from the
  deductions, not assigned.

  The gate goes NOT by score but by blocking findings: only critical
  (weight −4.0/−3.0) and high (weight −2.5/−2.0) findings hold the plan. Each
  such finding must name a failure scenario: under which inputs or state what
  breaks. A finding without a scenario is downgraded to medium and does not
  hold the gate. Do not inflate severity "just in case" and do not deflate it
  to make the plan pass.
  ```
- **Claude score = MINIMUM across all reviewers that ran.** Averaging is forbidden: one hole in data isolation must not be compensated by high scores for orchestration and tests
- **Self-excluded reviewers** ("✅ not required") are **not included** in the minimum — they have nothing to score
- 🔴 **A score without a list of deductions is invalid.** A reviewer that returns "9.5" with no breakdown or without the "blocking: N" line counts as not having run — ask them again for the deductions

## CODEX CRITIC RULE

**Why:** Claude reviewers are a single model checking itself. An external critic on a different model (Codex CLI; the model comes from the user's `~/.codex/config.toml`, reasoning effort `high`) catches what Claude has a blind spot for: its own architectural habits and whatever already "looks right".

**The critic is optional to install but mandatory if installed.** `vibe-flow:codex-plan-critic` checks for its presence itself as the first step and returns one of three outcomes:

| Agent outcome | What it means | What the main session does |
|---|---|---|
| `⚪️ Critic not installed` | `codex` is not in `PATH` | The Claude reviewers hold the gate. **Once per session**, tell the user: "The external critic is not installed — the gate goes by the Claude reviewers. To install: `npm i -g @openai/codex` (or `brew install codex`), then `codex login`". Do not repeat in later rounds |
| `❌ Critic unavailable` | Codex is installed but not authorized, crashed, returned no JSON or hit the timeout | 🔴 **Gate NOT passed.** Show the user the exact error and ask: fix it and wait, or proceed without the external review at their own responsibility. Write the answer into the plan. Continuing silently is forbidden |
| Report `## 🧑‍⚖️ External Codex review` | The critic ran | Go through each finding (below) |

- 🔴 **Critic unavailable ≠ critic satisfied.** A Codex that is installed but crashed is neither "passed" nor "not installed". It is a stop with a question to the user
- **Order:** run **after** the whole Claude reviewer batch, when their sections and scores are already in the plan file — the critic is given the plan **together with** them. Otherwise it will deduct points for what has already been handled
- 🔴 **Codex writes NOTHING** — neither to the plan nor to the repository. The sandbox is `-s read-only`, the wrapper agent has no `Edit`/`Write`. The plan's owner is the main Claude session
- 🔴 **The decision on each finding is made by Claude, not by Codex and not by the user one by one.** Claude goes through each finding, accepts or rejects it **with a justification** and shows the user the final "accepted / rejected + why" table before `ExitPlanMode`
- **Rejecting is allowed** — the critic is not the boss. But rejecting without a justification is forbidden: the table must say why the finding is wrong or inapplicable
- **Data leaves the machine:** on the first critic run in a session, tell the user in one line that the plan and code fragments are sent to an external provider (OpenAI) — the agent returns this line in the round 1 report. Codex does not open secrets (`.env*`, keys, access files) per the prompt header
- **Codex picks up the project rules itself:** it is launched from the project root and reads `AGENTS.md`; if the rules live only in `CLAUDE.md`, the wrapper agent tells it to read that too
- ⚠️ **Plan Mode gotcha:** the harness may not let the wrapper agent write even to a temp folder — and the critic will not run before `ExitPlanMode`. In that case — with the user's explicit consent — run it **right after `ExitPlanMode` and BEFORE the first code edit**: the gate guards the start of implementation, not the exit from the plan
- **Do NOT call `ExitPlanMode`** until `codex-plan-critic` has finished (or returned "not installed") and its findings are processed

## PLAN GATE RULE

**The gate is by defect class, not by score.**

The plan goes to implementation when **no open `critical` and `high` findings remain** — neither from the Claude reviewers nor from the external critic (if installed). The score is always computed and shown, but on its own does not block the plan.

- **Open finding** — one that has been neither accepted nor rejected with a justification. An accepted finding that has been folded into the plan is closed; one rejected **with a fact** (`file:line` or a reference to an explicit user decision) is closed too
- **The "weight ↔ severity" mapping** is hard, in `${CLAUDE_SKILL_DIR}/rubric.md`: −4.0/−3.0 = `critical`, −2.5/−2.0 = `high`, −1.5/−1.0 = `medium`, −0.5/−0.3 = `low`
- 🔴 **`critical`/`high` without a failure scenario does not block.** A blocking-class finding must name under which inputs or state what breaks. Without a scenario it is downgraded to `medium` — a guard against severity inflation, which the numeric gate lacked
- 🔴 **Rejection is a legitimate way to close a finding, not a defeat.** With a numeric gate, arguing was unprofitable: over four rounds of one plan, out of eighteen critic findings **not one** was rejected — the critic de facto got a veto. Now a rejection with a fact closes the item on a par with a fix

**Why not "≥ 9.0 on both sides".** With a weight of −2.0 for an ordinary logic defect, a 9.0 threshold meant "no more than one finding of weight 1.0" and for a plan of non-trivial size it was impassable in principle. On a real plan the critic gave 0.0 → 2.0 → 1.5, even though the plan got better from round to round and every finding was being closed. It went to implementation by the user's decision around the gate — a mechanism meant to decide turned out to be decorative. The threshold was not "lowered": it was replaced by one that measures danger, not quantity.

**If the gate is not passed — auto-fix, up to 3 rounds:**

1. Claude fixes the plan per the **accepted** findings
2. Re-runs the reviewers whose area the fix touched — for a new score **and a new count of blocking findings**
3. Re-runs `vibe-flow:codex-plan-critic` (if installed) with the round number and the list of rejections **with justification**
4. The gate is recomputed

🔴 **The limit is 3 rounds, hard.** After the third failure — **stop**: show the user the scores, the round history, what was accepted and what was rejected, and exactly where the disagreement lies. After that the user decides: edit by hand, push the plan through as is, or abandon it. Running a fourth round is forbidden — it burns tokens on a non-converging argument.

🔴 **Do not soften severity to make it pass.** If a plan stubbornly keeps `critical`/`high` findings, that is a signal about the plan, not about an overly strict gate. Reassigning a defect class against the weight table is forbidden; only the user changes the rule, by explicit instruction. A downgrade is permissible on exactly one ground: the finding itself has no failure scenario.

**Show the user before `ExitPlanMode`:**

```
## 🚦 Plan gate

| Side | Score (metric) | Open critical/high |
|---|---|---|
| Claude (min across reviewers) | 8.5 | 0 ✅ |
| Codex (external critic) | 6.5 | 0 ✅ |

Gate: ✅ passed — no blocking findings left
Rounds used: 2 of 3

**Critic findings:**
| ID | Severity | Gist | Decision | Why |
|---|---|---|---|---|
| C1 | critical | ... | ✅ accepted | folded into step 3 |
| C2 | high | ... | ❌ rejected | the check is already there, `src/api/orders.ts:42` |
| C3 | medium | ... | ✅ accepted | folded into "Risks" |
```

If Codex is not installed — the critic row is `⚪️ not installed`, and the gate goes by the Claude reviewers. If it is unavailable and the user decided to proceed without it — the row is `❌ unavailable — user's decision`, and that decision is recorded in the plan:

```
| Codex (external critic) | — | ⚪️ not installed |
| Codex (external critic) | — | ❌ unavailable — user's decision |
```

🔴 **Write these markers literally, as the WHOLE content of the status cell of the `| Codex …` row** — no bold, no explanation after them (an explanation goes into the text below the table). The `plan-approved` hook reads them there (and only there — a marker quoted in prose does not count) to write the plan approval mark without a `## … Codex` section. Writing `⚪️ not installed` while Codex IS installed gets no mark: the hook checks — run the critic instead.

The score stays in the table: it shows how good the plan is, and a low number with a passed gate is a legitimate reason to tell the user "it passed, but here are the points where the plan is weak".

## TEAM CREATE RULE

**After `ExitPlanMode`, act on the `orchestration-router` verdict** (the `## 🚀 Implementation orchestration` section in the plan):

- **🔀 Agent crew** → automatically, without questions:
  1. launch `vibe-flow:team-planner` with the path to the plan file → it determines the parallel groups, agent types, models and effort, and appends `## 👥 Agent crew` with ready-made prompts
  2. 🔴 **Main path — parallel `Agent` calls:** each group from the section goes **in one message** (one `Agent` call per agent): `subagent_type`, `model`, `effort` — from the agent's row; the prompt — from the section verbatim (do not invent it anew) + the line `Worktree: <absolute path>`
  3. The next group — **only after the results of the previous one**: check that each agent did its part (files are in place, the "done" criterion is met); if one did not, refine the prompt and relaunch it
  4. Crew agents return their result as a **final reply**. There is no `SendMessage` chat — the prompts are self-contained
  5. Post-steps from the section, in order: `vibe-flow:test-runner` → [`vibe-flow:security-reviewer`, if the section requires it] → commit via `scripts/git-safe-commit.sh` → `vibe-flow:release-gate` → `vibe-flow:dev-server-restart` (each gets `Worktree: <path>`)
  - **`TeamCreate` only if available.** In Claude Code `TeamCreate`/`TaskCreate` are experimental and many people do not have them; the `team_name` parameter of `Agent` is **ignored** without them. If the tool exists, you may create a team (`TeamCreate` → `TaskCreate` with the same prompts → `Agent` with `team_name` → `TaskUpdate`); `SendMessage` is appropriate only for agents that are actually in such a team
  - **do not use a crew** when all steps are sequential or the task is trivial (1 file) — then direct execution
- **⚙️ Workflow** → 🔴 **only on the user's explicit "yes"** in the current message: propose Workflow and wait for consent; only after it, write the JS script and run `Workflow`. Do **not** launch `team-planner`. **No `Workflow` tool** → tell the user and offer a crew (`team-planner` + parallel `Agent`) or direct execution
- **▶️ Direct execution** → the main session implements it itself, without `team-planner`/a crew/`Workflow`

## PLAN FORMAT RULE

**Mandatory format for all plans in Plan Mode.**

**🔍 Stage 1 — choosing the approach (before the plan):**
Before the detailed plan, offer the user the **TOP-3 solution options** via `AskUserQuestion`:
```
Option 1: [Name]
✅ Pros: ...
❌ Cons: ...

Option 2: [Name]
✅ Pros: ...
❌ Cons: ...

Option 3: [Name]
✅ Pros: ...
❌ Cons: ...
```
- The user chooses → only then is the detailed plan written
- Record the choice in the plan with the line `**Chosen approach:** <option> — user's choice from TOP-3` in the "💡 Why" section: from it `plan-reviewer` will understand that the comparison already happened and will not build a TOP-3 again
- **Exception:** for trivial tasks (1 file, obvious solution) the selection stage may be skipped

**📋 Stage 2 — the detailed plan (template):**

```markdown
# 🎯 [Short task title]

Repository: ~/dev/<repo>   ← only if the work is in a repository other than the session's; one line per repository, above the first `## ` (the approval mark goes there too)

## 💡 Why
[1-2 sentences: what the problem is, why this is needed]
**Chosen approach:** [option — user's choice from TOP-3; remove the line if the selection stage was skipped]

## 🛠️ What we're doing
[In plain language: what exactly will be done]

## 🔬 Verify live
[MANDATORY if the plan relies on external systems. An "Assumption —
How verified — Fact — What it affects" table, every row closed by a fact.
See LIVE FACTS RULE. A plan without external systems does not need the section.]

## 📌 Steps
1. **Step description** — `path/to/file`
   - What exactly we change
2. **Step description** — `path/to/file`
   - What exactly we change
3. **(for a bug fix in logic or a new pure function) Test → red run → code** — `path/to/test`
   - Write the test, run it, see it red (the output goes into the report), only then the implementation. Not for integration tests that write to a shared database

## 📂 Files
- ✏️ Modify: `file1`, `file2`
- ➕ Create: `new-file`
- 🗑️ Delete: —

## ⚠️ Risks
- Risk 1 description → How to prevent it
- Risk 2 description → How to prevent it

## ✅ Verification
- [ ] What we check — description of the action
- [ ] What we check — description of the action
```

Below the template, the reviewers append their sections, and the main session appends the user's answers to the mandatory questions and the gate table.
