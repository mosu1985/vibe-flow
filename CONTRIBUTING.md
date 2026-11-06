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
  git-guards/                       VENDORED copy of ~/dev/git-guards (do not edit here!)
plugins/vibe-flow-vercel/           package for projects on Vercel
plugins/vibe-flow-supabase/         package for projects on Supabase
tools/sync-git-guards.sh            update the vendored git-guards copy
```

## Rules for agents and skills

1. **Language: Russian**, with the same tone and structure as the sources
   (emoji markers on headings, 🔴 for hard rules, short bullet points).
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
   - the `## 🧩 Проект` block in `CLAUDE.md` (stack, commands, where things
     live), written by `/vibe-flow:init`;
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

The git-guards mechanism lives in a separate repository (`~/dev/git-guards`).
Edit there → `tools/sync-git-guards.sh` → commit here. Direct edits in
`plugins/vibe-flow/git-guards/` are lost on the next sync.

## Versions

Bump `version` in `plugins/*/.claude-plugin/plugin.json` on EVERY release,
otherwise students keep a cached copy.
