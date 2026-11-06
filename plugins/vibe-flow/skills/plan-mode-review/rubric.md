# Plan scoring rubric (0–10)

A single scale for **both sides** — the Claude reviewers and the external Codex
critic (if installed). Everyone reads the same document; otherwise the scores
are not comparable and the gate is meaningless.

## 🔴 The score is a metric, the gate goes by defect class

Read this before you start counting. **The score by itself does not block the plan.**

The plan goes to implementation when **no open findings of class `critical` and
`high` remain** (the "Blocks" column in the weight table). The score is always
computed and shown — it says how good the plan is — but the decision is made by
severity, not by the number.

**Why.** The gate used to be numeric: "≥ 9.0 on both sides". With a weight of
−2.0 for an ordinary logic defect, that meant "no more than one finding of
weight 1.0". For a plan of non-trivial size such a threshold is impassable in
principle: a critic that found anything substantial could mathematically not
give 9.0. On a real plan the external critic gave 0.0 → 2.0 → 1.5 over several
rounds; the plan kept getting better while the number barely moved — and it went
to implementation by the user's decision around the gate. A mechanism meant to
decide became decorative. Now the gate measures what matters: whether an
**unfixed dangerous thing** remains.

🔴 **Deflating severity to make a plan pass is the same as fitting the score.**
Both sides know the rule, and the temptation is exactly the same. `critical`/`high`
is assigned by defect class from the table, not by the desired outcome.

🔴 **`critical`/`high` requires a failure scenario.** A blocking-class finding
must name **under which inputs or state what exactly breaks** ("a user with
access disabled reads a cache warmed by another user and gets someone else's
data"). A finding without a scenario is an observation, not a defect: it is
automatically downgraded to `medium` and does not hold the gate. This is a
guard against severity inflation, which the numeric gate lacked.

## How the score is computed

Start at **10.0**. For each defect found, subtract the weight from the table
below. The result is rounded to one decimal place, minimum 0.0.

🔴 **A score without a list of deductions is invalid.** A rating of "9.0" with
no enumeration of what exactly cost 1.0 point is a self-assessment, not a
measurement. A reviewer that does not attach the deductions counts as not having run.

🔴 **The score is fitted to nothing.** It opens and closes nothing — the gate
goes by severity — so its only job is to honestly show the quality of the plan.
First list the defects, then count.

## Deduction weights

The "Severity" column is common to both sides: a Claude reviewer names the defect
class by weight, the external critic by word, and it is the same thing. The
mapping is hard and cannot be reassigned.

| Weight | Severity | Blocks | Defect class | Examples |
|---|---|---|---|---|
| **−4.0** | `critical` | 🔴 yes | Breaks production or loses data | An irreversible migration without a backup; deploying code before the data migration it depends on; dropping a column or field that live code reads |
| **−3.0** | `critical` | 🔴 yes | Hole in isolation or permissions | A query without a filter by owner/tenant (`user_id`, `tenant_id`, `organization_id`…); a new table without RLS or an endpoint without a permission check; a new section visible to all users instead of those entitled to it |
| **−2.5** | `high` | 🔴 yes | A critical project rule is violated (from `CLAUDE.md`) | A temporary solution or a mock in production code; a write to a live external system without an explicit "yes"; a deploy without the user's permission |
| **−2.0** | `high` | 🔴 yes | Plan logic defect | A step depends on the result of a later step; an existing shared module is ignored → duplication; wrong rollout order |
| **−2.0** | `high` | 🔴 yes | **Unverified assumption about an external system on which access control or the data source rests** | "The `status` field in the API response will show the order is paid"; "this endpoint will return only the current user's records" — if what data leaks or where it comes from depends on the answer |
| **−1.5** | `medium` | no | Load without an estimate | A query without an index on a large table; a change subscription without a server-side filter; a scheduled background job with a risk of overlapping runs; N+1 |
| **−1.0** | `medium` | no | Coverage gap | Test-covered logic changes and tests are not mentioned; no verification step for a risky change |
| **−1.0** | `medium` | no | Other unverified assumption about an external system | Field format, unit of measure, time zone, type name — where an error gives wrong numbers but does not expose data |
| **−0.5** | `low` | no | Incomplete description | No file path given; a vague step wording; one of the UI languages forgotten in a multilingual project |
| **−0.3** | `low` | no | Cosmetics | The plan template is not followed; no "Risks" section even though there are risks |

🔴 **The two assumption classes did not come from theory.** In one real plan the
predicate "the record belongs to the needed category" read the wrong field of an
external API — a field with a similar name but a different meaning, under which
the needed record was indistinguishable from an unrelated one. It survived
**nine review passes**: six Claude reviewers and three rounds of the external
critic. Checking required one live API request, and reviewers read text. The
defect reached production and was caught only by a browser smoke test. Hence the
`## 🔬 Verify live` section in the mandatory plan template and these two rows in
the rubric.

## What is NOT grounds for a deduction

- **Stylistic preferences** — "I would name the function differently", "another
  pattern would be better" without concrete harm
- **Questions the user has already decided explicitly** — if the plan records an
  answer to an `AskUserQuestion`, you may not deduct for it again
- **Tasks outside the plan's scope** — "while we're at it, X should be refactored"
- **The absence of something the project does not use** — for example a demand for
  e2e tests where there are none at all, or RLS in a project with no database

A deduction for such things is itself a review defect: it raises the threshold and
forces extra rounds.

## Score output format

Each reviewer ends their section with the line:

```
**Score: 8.5 / 10** · blocking (critical/high): 0
Deductions: −1.0 covered logic calculateTotal changes, tests not mentioned; −0.5 no file path in step 3
```

If there are no defects:

```
**Score: 10.0 / 10** · blocking (critical/high): 0
Deductions: none
```

If there are blocking findings, they must be listed separately, with a failure
scenario for each:

```
**Score: 6.0 / 10** · blocking (critical/high): 2
Deductions: −3.0 no owner filter in step 4; −2.0 step 2 uses a table that step 5 creates; −1.0 no test for the new predicate
🔴 Blocks:
- critical (−3.0) — step 4 reads the orders table without a filter by `tenant_id`.
  Failure: a user of customer A opens the list and sees customer B's orders.
- high (−2.0) — step 2 writes to the `invoices_archive` table, which only appears
  in step 5. Failure: when implemented in order, the very first write fails
  with "relation does not exist".
```

🔴 The "blocking: N" line is mandatory even at zero — the main session counts the
gate from it. A section without it counts as not having run, exactly like a
score without deductions.
