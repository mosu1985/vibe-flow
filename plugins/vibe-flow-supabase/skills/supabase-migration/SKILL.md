---
name: supabase-migration
description: Apply a SQL migration to a Supabase database safely — file, trial run with ROLLBACK, applying after confirmation, RLS check
disable-model-invocation: true
---

Apply a SQL migration to the Supabase database. This changes live data/schema — go step by step and do not skip ahead.

## 🔴 Rules

- **Applying DDL — only after the user's confirmation.** Show what will be run (the file + a short summary) and wait for a "yes". Consent is needed for the fact of applying; **get DB access** yourself, do not ask the user about it
- **A trial run with a rollback first**, then the real application
- Secrets — only from the environment (`node --env-file=.env.local`), no tokens in argv, `curl`, `-e` code or output
- Do not trust the wording "dry-run" in someone else's runner: check that it really executes nothing, or do the trial run yourself (below)

## Steps

### 1. Preparation

- Find out how the project does it: the directory (`supabase/migrations/`), the naming/numbering scheme, whether there is a standard runner (`scripts/*migrat*`, `package.json` → scripts, the `supabase` CLI). No clear data — look at the existing files and say what you determined
- A descriptive name, `snake_case`; idempotent SQL where possible (`IF NOT EXISTS`, `IF EXISTS`)
- Wrap the body in `BEGIN; … COMMIT;` unless there is `CONCURRENTLY`/`ALTER TYPE … ADD VALUE` (these cannot go in a transaction — move them to a separate file)
- **Do not hardcode generated ids** (uuid, serial) in migrations with data
- Save the migration file in the project directory — for history and re-application

### 2. Trial run with a rollback

Copy the migration into a temporary file (outside the repository or `_tmp-*`), replace the final `COMMIT;` with `SELECT 1 AS ok; ROLLBACK;` and run it the same way you will apply it. Make sure that:
- the run completed without errors;
- afterwards there are **no** new columns/tables (the rollback worked) — check with a query or the OpenAPI schema (`42703`/`PGRST205` = no such object).

Delete the temporary file.

### 3. Applying (after the user's "yes")

In order of preference:
1. The project's standard runner (it takes the token from `.env.local` itself).
2. The Management API: `POST https://api.supabase.com/v1/projects/<ref>/database/query` with the token from `process.env` inside a temporary script; `ref` from the project URL.
3. The Supabase CLI (`supabase db push`) — the password only via the `SUPABASE_DB_PASSWORD` environment, not in `--db-url`.

Does not work and do not try: a DB password found in old notes (usually long expired), and putting a token on the command line.
No token/access — "unavailable: <what is needed> — <how to get it>", not a silent refusal.

### 4. Verification after applying

- Structure: columns/tables are visible (service_role + the OpenAPI description `/rest/v1/`)
- Data (DML): a `SELECT` confirms the result **by value**, not by "rows affected: N" — the backfill might have written the wrong thing
- 🔴 **RLS of a new table — with the anon key**, not service_role: expect `401`/`42501`; `200 []` proves nothing. If the project has a check like `check:rls` — run it
- For `SECURITY DEFINER` functions — permissions: `REVOKE ALL ON FUNCTION … FROM PUBLIC, anon, authenticated` (all three targets!) and `GRANT EXECUTE … TO service_role`; compare `proacl` in `pg_proc`. `REVOKE … FROM PUBLIC` alone is not enough: roles get EXECUTE through their own grants. `DROP FUNCTION` takes the ACL with it — after recreating, check the permissions again
- For Storage policies: the denying ones are `AS RESTRICTIVE` (a PERMISSIVE "Deny" opens access through OR); check the bucket's privacy with the anon key (`list('')`, upload)
- If Supabase advisors (`get_advisors`, security) are available via MCP — run them and go through the findings for the new tables

## SQL/PostgREST gotchas that break migrations and their verification

- A migration rejected midway without a transaction leaves a partial state — hence `BEGIN/COMMIT` and the trial run
- A long `ALTER TABLE` takes `ACCESS EXCLUSIVE` and queues behind any long query, blocking all the following ones — `SET lock_timeout`, on a timeout **retry**, do not increase
- An index on a big table — `CREATE INDEX CONCURRENTLY` outside a transaction (the session pooler, port `5432`)
- Editing one JSONB key — only `jsonb_set(value,'{key}',…)` with a narrow `WHERE`; `UPDATE … SET value = <whole object>` or a PATCH on the column wipes the other keys
- Verify a backfill **by value**, on live rows, not by the response code
- Look at the column type in the schema before writing a function: a `uuid` parameter instead of `text` fails `CREATE FUNCTION` / breaks the comparison
- Functions with `SET search_path`/`SECURITY DEFINER` are not inlined by the planner — conditional predicates become post-filters; for functions called only by `service_role`, `SECURITY INVOKER` + `SET search_path = public, pg_temp` is often enough
- The "tenant = parameter" predicate in an RPC is unconditional (`organization_id = p_org AND p_org IS NOT NULL`), not `(p_org IS NULL OR …)`: otherwise the parameter stops being an isolation boundary
- `ORDER BY id LIMIT N` when a composite index exists may choose a primary-key scan (a cache lottery); for pagination sorting use the index fields (`created_at DESC, id DESC`)

## Response format

```
✅ Migration applied: <name>
📋 Changes: <what was created/changed>
🧪 Trial run: ROLLBACK without errors
🔒 RLS: <status by the anon key>
```
