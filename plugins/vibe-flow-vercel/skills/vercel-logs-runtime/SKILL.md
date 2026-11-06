---
name: vercel-logs-runtime
description: Check Vercel runtime logs (serverless/edge function errors)
disable-model-invocation: false
---

Check the Vercel runtime logs to diagnose errors in serverless and edge functions.

## Choosing a method

1. **Main — the Request Logs script** (works without MCP, needs `VERCEL_TOKEN` and `.vercel/project.json`):
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/scripts/vercel-request-logs.mjs" --minutes 60 --step 1 --status 500
   ```
   Or launch the `vibe-flow-vercel:vercel-logs-reader` agent — it picks the period and step itself.
2. **Fallback — the Vercel MCP** (`get_runtime_logs`, `get_runtime_errors`), if connected. Filter `level: ["error", "warning"]`, by default the last 24 hours, limit 100. Project and team identifiers come from `.vercel/project.json`, do not guess.
3. **No access at all** — honestly report "unavailable: no token / MCP" and what to do (`vercel link`, `VERCEL_TOKEN` in `.env.local`).

If the project has a Log Drain set up to its own endpoint, the logs can be taken from there (ask the user for the address or find it in `CLAUDE.md`).

## 🔴 Request Logs API limitations

- The request window is at most 60 seconds (more → `ExceedsBillingLimitError`); for a period the script splits into one-minute windows
- Retention is ~3 days; deeper gives the same error code, do not confuse it with the window limit
- `limit` may be ignored (~50 lines); completeness comes from the server-side method/route filter, not the cursor

## Analysis

- Group errors by type (API route, edge function, middleware)
- Count frequency; look for patterns (one error, one endpoint, one region)
- Distinguish the observed failure from the suspected cause

## Result

- A list of errors: time, source, message
- Which routes are affected
- Recommendations for fixing
