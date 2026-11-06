---
name: architecture-map
description: A map of the project code for fast navigation while planning. Use at the START of planning any task and whenever you need to understand "where does X live", "where do I add a feature", the architecture, domains, entry points (API routes, pages, migrations), hub files. Replaces blindly walking the repository with "refresh the index → grep docs/codemap → targeted Explore".
user-invocable: true
---

# Code map — navigating the project while planning

Blindly walking a large repository is expensive in time and tokens. This skill provides two layers:

1. **Auto-index** `docs/codemap/*.md` — exact and never stale: a script regenerates it.
2. **Narrative** `docs/codemap/ARCHITECTURE.md` — domains, hubs and entry points in words. Written and maintained by Claude (see below).

> The index answers "which exact file/route/export", the narrative answers "how is it built and where does new code go". Always take exact paths from the index: the narrative may lag behind.

## 🧭 Workflow

0. **Where to write the index.** By default — `docs/codemap/` in the project root. Write to a temporary directory if:
   - you are in **Plan Mode** — the harness may block writes to the repository;
   - you are in the **main tree** while the work is going on in a separate worktree, or `docs/codemap/` is tracked by git — generating into the repository dirties the tree with changes unrelated to the task.

   Then:
   ```bash
   node "${CLAUDE_SKILL_DIR}/gen-codemap.mjs" --root "<project or worktree root>" --out "${TMPDIR:-/tmp}/codemap-<project-name>"
   ```
   and grep there. Still read the `ARCHITECTURE.md` narrative from the project's `docs/codemap/` — the generator does not write it.
1. **Refresh the index** from the project root:
   ```bash
   node "${CLAUDE_SKILL_DIR}/gen-codemap.mjs"
   ```
   Fast (fs + regex, no dependencies, Node ≥ 18). Writes to `docs/codemap/`. Flags: `--root <dir>` (project root), `--out <dir>` (where to write). The output is deterministic — no timestamps: regenerating without code changes produces no diff.

   **No `node`** (`command -v node` is empty) → skip the index: read `docs/codemap/ARCHITECTURE.md` (if present), then do a targeted Explore based on it and on `CLAUDE.md`. Say in one line that the index was not built.
2. **Grep the exact file** in the index directory (`docs/codemap/` or the temporary one):
   - route/endpoint → `routes.md` (URL, HTTP methods, kind, file)
   - page → `pages.md`
   - function/class/type → `exports.md`
   - migration/table → `migrations.md`
   - overview, directory sizes → `INDEX.md`
   - "how it's built", domains, hubs → `ARCHITECTURE.md` (always from the project's `docs/codemap/`)
3. **Targeted Explore** — only on the paths you found, not over the whole repository.

The generated index is a working reference, not a task result: **do not commit it** and do not suggest committing it. Whether to keep `docs/codemap/*.md` (except `ARCHITECTURE.md`) in git is the user's call; if they don't, add them to `.gitignore`. `ARCHITECTURE.md` is hand-written text and is usually kept in git (committed under the project's general rules).

## 🔎 What the generator finds

| What | How |
|---|---|
| Next.js app router | `app/**/route.*` (methods from `export GET/POST…`), `app/**/page.*`; `(x)` groups and `@x` slots are removed from the URL |
| Next.js pages router | `pages/**`, `pages/api/**` |
| Express / Fastify / Hono | rough regex `router.get('/path'`, `app.post(…`, `fastify.…` |
| Python | FastAPI/Flask decorators `@app.get("/x")`, `@bp.route("/x", methods=[…])`, Django `urls.py` (`path(...)`) |
| Migrations | any files in `migrations/` directories (`supabase/migrations`, `prisma/migrations`, alembic, …) + the first `--` line of the SQL |
| TS/JS exports | `export function/const/class/type/interface/enum`, `export { … }`, `module.exports` |
| Python exports | top-level `def` / `class` (excluding `_private` names) |

It skips: `node_modules`, `.git`, `dist`, `build`, `.next`, `venv`, `.venv`, `__pycache__`, `coverage`, `target`, hidden directories and files larger than 512 KB.

🔴 **Limitations — these are regexes, not a parser.** The index will not see dynamically built routes, routes registered through config or wrapper decorators, or exports via `export *`. If you find a discrepancy with the code, trust the code and note the blind spot in the narrative. An unfamiliar framework → the index yields 0 routes; that does not mean there are none.

## 🗺️ Domain map (`docs/codemap/ARCHITECTURE.md`)

The narrative is written by **Claude**, not the generator — the generator knows no business meaning.

**First use** (the file `docs/codemap/ARCHITECTURE.md` does not exist). In Plan Mode the write may be blocked — then write the file after `ExitPlanMode`, in the task's worktree:
1. Generate the index (step 1; no `node` — skip) and read `INDEX.md`.
2. Read the project's `CLAUDE.md` (the `## 🧩 Project` section, between the `<!-- vibe-flow:project:begin -->` / `<!-- vibe-flow:project:end -->` markers; older installs title it `## 🧩 Проект`), the README, the manifest (`package.json`/`pyproject.toml`/`go.mod`), root configs.
3. Look through the index and then targeted (2–5 files, not the whole repository): entry points, the most crowded directories, the most frequently imported modules (hubs — find them via `grep -r "from '.*<name>'"`).
4. Write a **short** (one or two pages) `docs/codemap/ARCHITECTURE.md`:
   - **What the project is** — one sentence, the stack
   - **Top-level structure** — what is in each directory
   - **Domains** — a table: domain → where the logic / where the API / where the UI
   - **Entry points** — where work comes from: HTTP routes, cron/jobs, webhooks, CLI, queues (and where they are registered)
   - **Hub files** — modules that are read and edited most often, and what they are responsible for
   - **Cross-cutting patterns** — authorization, error handling, DB access, configuration, i18n — how it is done in the project
   - **"Where to add" recipes** — a new endpoint, a new page, a new migration, a new test: which files to create and where to register them
5. Tell the user the file was created, and in one line what is in it.

**After that — maintain it.** While working on a task you read the map alongside the code. If you find something stale (a file moved, a domain is gone, a hub changed, a recipe doesn't work) — fix `ARCHITECTURE.md` surgically in the same session and report it in one line. Don't rewrite it whole, don't bloat it: the map must stay short.

🔴 **Don't invent.** Only what you saw in the code or the index goes into the narrative. Not sure what a module is for — mark it "(purpose not confirmed)" or leave it out.

## 💡 When to use

- The start of planning any non-trivial task (Plan Mode)
- "Where does X live?", "where do I add a feature?", "how is authorization built here?"
- Onboarding to someone else's project
- Before mass edits — find all the places from the index, not from memory

## Related

- Smoke run of the found pages — the `/vibe-flow:smoke-ui` skill (takes the list of sections from `pages.md`)
