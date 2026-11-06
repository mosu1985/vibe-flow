#!/usr/bin/env node
// Vercel runtime logs (Request Logs API) — error summary for a period.
//
// 🔴 API limitations (verified): the request window is AT MOST 60 000 ms, more gives
// ExceedsBillingLimitError; retention depth is ~3 days (deeper — the same error code!);
// the parameters are exactly startDate/endDate in milliseconds; ownerId is required;
// `limit` may be ignored (~50 lines are returned) — completeness comes from the
// `requestMethod`/`route` filter, not the cursor.
//
// Token and project — as in wait-vercel-deploy.mjs: env or .env.local / .vercel/project.json.
//
// Usage (from the project root):
//   node vercel-request-logs.mjs [--minutes 30] [--step 1] [--status 400] [--method POST]
//        [--route /api/x] [--samples]
//   --minutes  how far back (1…4320, default 30)
//   --step     step between windows in minutes: 1 = no gaps; >1 = sampling (estimate ≈ count × step)
//   --status   minimum code for grouping errors (default 400)
//   --method / --route  server-side API filters
//   --samples  show one message from logs[] for each group
//
// Exit codes: 0 ok · 4 no access/token/link · 5 invalid arguments

import {
  api, readProjectLink, readToken, teamQuery, LINK_HELP, TOKEN_HELP,
} from "./_vercel-common.mjs";

function parseArgs(argv) {
  const a = { minutes: 30, step: 1, status: 400, method: null, route: null, samples: false };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = argv[i + 1];
    if (k === "--minutes") { a.minutes = Number(v); i++; }
    else if (k === "--step") { a.step = Number(v); i++; }
    else if (k === "--status") { a.status = Number(v); i++; }
    else if (k === "--method") { a.method = v; i++; }
    else if (k === "--route") { a.route = v; i++; }
    else if (k === "--samples") { a.samples = true; }
    else return { error: `unknown argument ${k}` };
  }
  if (!(a.minutes >= 1 && a.minutes <= 4320)) return { error: "--minutes: 1…4320 (retention ~3 days)" };
  if (!(a.step >= 1 && a.step <= 60)) return { error: "--step: 1…60" };
  if (!(a.status >= 100 && a.status <= 599)) return { error: "--status: 100…599" };
  if (a.method && !/^[A-Z]{3,7}$/.test(a.method)) return { error: "--method: GET|POST|PATCH…" };
  return a;
}

function out(obj, code) {
  console.log(JSON.stringify(obj, null, 2));
  process.exit(code);
}

async function main() {
  const a = parseArgs(process.argv.slice(2));
  if (a.error) out({ status: "BAD_ARGS", error: a.error }, 5);
  const { orgId, projectId } = readProjectLink();
  if (!projectId || !orgId) out({ status: "NO_LINK", error: LINK_HELP }, 4);
  const token = readToken();
  if (!token) out({ status: "NO_TOKEN", error: TOKEN_HELP }, 4);

  const tq = teamQuery(orgId);
  const now = Date.now();
  const start = now - a.minutes * 60_000;
  const groups = new Map();
  let windows = 0, failedWindows = 0, totalRows = 0, errorRows = 0, lastApiError = null;

  for (let s = start; s < now; s += a.step * 60_000) {
    const e = Math.min(s + 60_000, now); // window ≤ 60 s
    let q = `/v1/projects/${projectId}/request-logs?startDate=${s}&endDate=${e}&ownerId=${orgId}&limit=200`;
    if (tq) q += `&${tq}`;
    if (a.method) q += `&requestMethod=${a.method}`;
    if (a.route) q += `&route=${encodeURIComponent(a.route)}`;
    windows++;
    let data;
    try {
      data = await api(token, q);
    } catch (err) {
      if (err.auth) out({ status: "AUTH_ERROR", error: "the token is invalid or has no access to the project — issue a new VERCEL_TOKEN" }, 4);
      failedWindows++;
      lastApiError = `${err.message}${err.body ? " " + err.body : ""}`;
      continue;
    }
    for (const r of data.rows ?? []) {
      totalRows++;
      const code = r.statusCode ?? 0;
      if (code < a.status) continue;
      errorRows++;
      const key = `${code} ${r.requestMethod ?? "?"} ${r.route ?? r.requestPath ?? "?"}`;
      const g = groups.get(key) ?? { count: 0, sample: null, lastSeen: 0, maxDurationMs: 0 };
      g.count++;
      g.lastSeen = Math.max(g.lastSeen, r.timestamp ?? 0);
      g.maxDurationMs = Math.max(g.maxDurationMs, r.functionEvents?.[0]?.durationMs ?? 0);
      if (a.samples && !g.sample) {
        const msg = (r.logs ?? []).find((l) => /error|fail|exception/i.test(l.message ?? "")) ?? r.logs?.[0];
        if (msg) g.sample = String(msg.message).slice(0, 300);
      }
      groups.set(key, g);
    }
  }

  const list = [...groups.entries()]
    .sort((x, y) => y[1].count - x[1].count)
    .slice(0, 25)
    .map(([key, g]) => ({
      group: key,
      count: g.count,
      estimated: a.step > 1 ? g.count * a.step : undefined,
      lastSeen: g.lastSeen ? new Date(g.lastSeen).toISOString() : null,
      maxDurationMs: g.maxDurationMs || undefined,
      sample: g.sample ?? undefined,
    }));

  out({
    status: failedWindows === windows && windows > 0 ? "API_FAILED" : "OK",
    periodMinutes: a.minutes, step: a.step, windows, failedWindows, lastApiError,
    totalRows, errorRows, groups: list,
    note: a.step > 1 ? "sampling: the real number ≈ count × step" : undefined,
    hint: failedWindows > 0 ? "ExceedsBillingLimitError on old windows = went past the retention depth (~3 days)" : undefined,
  }, 0);
}

main();
