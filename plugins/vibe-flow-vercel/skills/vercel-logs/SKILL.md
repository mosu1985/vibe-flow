---
name: vercel-logs
description: Check the logs of the latest Vercel deploy (status and build errors) via the API
disable-model-invocation: false
---

Check the logs of the latest Vercel deploy for the current project.

## 🔴 Secrets

The token comes only from the environment (`VERCEL_TOKEN` in the environment or `.env.local`), the project from `.vercel/project.json` (`vercel link`). Do not put the token on the command line and do not print it.

## Steps

### 1. Find the deploy
- You need the deploy of a specific commit — launch the `vibe-flow-vercel:vercel-deploy-monitor` agent with the SHA and target: it waits for the final state and returns the build errors in one call
- You just need "the latest" — via the Vercel MCP (`list_deployments`, if connected) or the API `GET /v6/deployments?projectId=…&limit=5&target=production`; remember that "the latest" may be someone else's preview — compare `meta.githubCommitSha` with the commit you need

### 2. Check the status
- `ERROR` → deploy events `GET /v3/deployments/{id}/events`, look for stderr and lines with `error`/`failed`/`killed`/`out of memory`
- `BLOCKED` → the build did not start; the cause is in `GET /v13/deployments/{id}` → `readyStateReason`, `seatBlock` (a common one: Vercel did not recognize the commit author's email)
- 🔴 `BUILDING` can be stuck: if `ready` is greater than `buildingAt` — the build is finished, whatever `state` says

### 3. Show the result

```
Deploy: {id}
Status: ✅ READY / ❌ ERROR / 🚫 BLOCKED / 🔄 BUILDING
Commit: {sha} — {message}
Time: {created_at}

Errors (if any):
- {file}:{line} — {error text}

Recommendations:
- {what to fix}
```

## Known causes of build failure

- `Next.js build worker exited with signal: SIGKILL` + "Out of Memory" → the process asks for more memory than the build container has; the V8 ceiling (`--max-old-space-size`) should be **lowered**, not raised (V8 does not collect garbage until it hits the ceiling). Better to remove the heavy step (for example, the type check) from the build
- `JavaScript heap out of memory` / "Ineffective mark-compacts" → V8 hit its own ceiling, raise it
- A failure in `npm install` because of a `prepare`/`postinstall` script that assumes `.git` exists (a CLI deploy has no `.git` directory)
