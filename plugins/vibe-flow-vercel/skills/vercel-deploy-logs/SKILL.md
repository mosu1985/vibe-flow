---
name: vercel-deploy-logs
description: Check Vercel deploy logs via the Vercel MCP tools (if connected) — status and build errors
disable-model-invocation: false
---

Check the Vercel deploy logs using the Vercel MCP tools.

## The external tool is optional

The Vercel MCP may not be connected. Check whether the tools `list_deployments` / `get_deployment` / `get_deployment_build_logs` are visible (depending on the MCP build the names may have a `mcp__…Vercel__` prefix). If not — honestly say "unavailable: the Vercel MCP is not connected" and suggest the API route: the `vibe-flow-vercel:vercel-deploy-monitor` agent (deploy by SHA) or the `/vibe-flow-vercel:vercel-logs` skill.

## Project data

Do not guess identifiers. Take `projectId` and `orgId` (teamId) from `.vercel/project.json` in the project root (created by `vercel link`). No file — ask the user or ask them to run `vercel link`.

## Steps

### 1. List the deploys
- `list_deployments` with projectId and teamId
- Show the last 5: date, status, commit, URL

### 2. Status of the deploy you need
- **ERROR or BUILDING:** `get_deployment_build_logs` (limit ~200)
- **READY:** confirm the successful deploy
- 🔴 Compare `meta.githubCommitSha` with the commit you need: the "latest" in the list may be someone else's preview
- 🔴 `state=BUILDING` can be stuck after the build has finished: look at `ready` against `buildingAt` (if `ready` > `buildingAt` — the build is finished). The build logs may lag too
- `BLOCKED` — the build did not start; look for the cause in the deploy's `readyStateReason`/`seatBlock` (a common one: the commit author's email was not recognized). The MCP tool `get_deployment` may fail on such deploys with "Response validation failed" — then fetch `GET /v13/deployments/{id}` directly

### 3. Error analysis
- Find lines with `error`, `Error`, `failed`, `Failed`
- Identify the file and line, propose a fix
- A `SIGKILL` + "Out of Memory" failure is the build container's memory, not the code: lower the `--max-old-space-size` ceiling, don't raise it; move the heavy step (the type check) out of the build

## Output format

```
Deploy status
- ID: {deployment_id}
- Status: ✅ READY / ❌ ERROR / 🚫 BLOCKED / 🔄 BUILDING
- URL: {url}
- Commit: {sha} — {message}
- Time: {created_at}

Errors (if any):
{error_logs}

Recommendations:
- {what to fix}
```
