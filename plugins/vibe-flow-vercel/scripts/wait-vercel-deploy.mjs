#!/usr/bin/env node
// Wait for a Vercel deploy to reach a final status — in ONE blocking call.
//
// WHY: an agent that waited for a deploy via `sleep` stayed silent — the Claude Code harness blocks
// `sleep` in the foreground, the agent went into background monitoring, the background died with it,
// and the READY/ERROR report never arrived. Here the wait is a `setTimeout` inside node,
// i.e. an ordinary command that exits on its own with a return code.
//
// 🔴 The deploy is looked up by commit SHA and target, NOT "the latest": parallel sessions and
// teammates push their branches every few minutes, and `limit=1` would return someone else's preview.
//
// 🔴 The token is env VERCEL_TOKEN or VERCEL_TOKEN from the project's .env.local; it does not reach argv
// and is never printed. The project comes from .vercel/project.json (`vercel link`) or
// VERCEL_ORG_ID / VERCEL_PROJECT_ID.
//
// Usage (from the project root):
//   node wait-vercel-deploy.mjs --sha <sha|prefix> [--target production|preview]
//        [--max-seconds 540] [--interval 15]
//   Without --sha it takes `git rev-parse origin/<protected branch>` (default origin/main,
//   otherwise origin/master).
//
// Exit codes: 0 READY · 1 ERROR/CANCELED/BLOCKED · 2 final state not reached
//                · 3 deploy not found · 4 no access/token/link · 5 invalid arguments

import { execSync } from "node:child_process";
import {
  api, readProjectLink, readToken, teamQuery, LINK_HELP, TOKEN_HELP,
} from "./_vercel-common.mjs";

// BLOCKED — the build did not start at all (for example, Vercel did not recognize the commit author).
const FINAL_STATES = new Set(["READY", "ERROR", "CANCELED", "BLOCKED"]);

function defaultSha() {
  for (const ref of ["origin/main", "origin/master"]) {
    try {
      return execSync(`git rev-parse ${ref}`, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    } catch { /* try the next one */ }
  }
  return null;
}

function parseArgs(argv) {
  const args = { target: "production", maxSeconds: 540, interval: 15, sha: null };
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i];
    const val = argv[i + 1];
    if (key === "--sha") { args.sha = val; i++; }
    else if (key === "--target") { args.target = val; i++; }
    else if (key === "--max-seconds") { args.maxSeconds = Number(val); i++; }
    else if (key === "--interval") { args.interval = Number(val); i++; }
    else { return { error: `unknown argument ${key}` }; }
  }
  if (!["production", "preview"].includes(args.target)) return { error: "--target: production | preview" };
  // Ceiling of 570 s: the agent's Bash call is limited to 600 s, the answer must have time to return.
  if (!(args.maxSeconds > 0 && args.maxSeconds <= 570)) return { error: "--max-seconds: 1…570" };
  if (!(args.interval >= 5 && args.interval <= 60)) return { error: "--interval: 5…60" };
  if (!args.sha) {
    args.sha = defaultSha();
    if (!args.sha) return { error: "--sha is not set and `git rev-parse origin/main` failed — pass --sha explicitly" };
  }
  if (!/^[0-9a-f]{7,40}$/i.test(args.sha)) return { error: "--sha: 7–40 hex characters" };
  args.sha = args.sha.toLowerCase();
  return args;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function findDeployment(ctx, sha, target) {
  // A full SHA is a filter on the Vercel side (finds an old deploy too); a prefix — a window of
  // the last 100, where the comparison is by the start of the string.
  const filter = sha.length === 40 ? `&meta-githubCommitSha=${sha}&limit=20` : "&limit=100";
  const data = await api(ctx.token, `/v6/deployments?projectId=${ctx.projectId}${ctx.team}${filter}`);
  const matches = (data.deployments ?? []).filter((d) => {
    const commit = String(d.meta?.githubCommitSha ?? "").toLowerCase();
    const isProd = d.target === "production";
    return commit.startsWith(sha) && (target === "production" ? isProd : !isProd);
  });
  // The newest of the matches: a repeated redeploy of the same SHA overrides the previous one.
  matches.sort((a, b) => (b.created ?? 0) - (a.created ?? 0));
  return matches[0] ?? null;
}

async function buildErrors(ctx, deploymentId) {
  try {
    const events = await api(ctx.token, `/v3/deployments/${deploymentId}/events?limit=-1${ctx.team}`);
    const lines = (Array.isArray(events) ? events : [])
      .map((e) => String(e.payload?.text ?? e.text ?? "").trimEnd())
      .filter(Boolean);
    // Lines with an error marker catch Type error / Module not found; the log tail gives
    // context when the cause is worded without the word "error" (OOM, SIGKILL, timeout).
    return {
      errorLines: lines.filter((t) => /error|failed|✗|cannot|not found|killed|out of memory/i.test(t)).slice(-30),
      tail: lines.slice(-25),
    };
  } catch {
    return { errorLines: ["(could not fetch the build log)"], tail: [] };
  }
}

// For BLOCKED the cause is not in the logs (there are none) but in readyStateReason / seatBlock.
async function blockReason(ctx, deploymentId) {
  try {
    const d = await api(ctx.token, `/v13/deployments/${deploymentId}?${ctx.team.replace(/^&/, "")}`);
    return { readyStateReason: d.readyStateReason ?? null, seatBlock: d.seatBlock ?? null };
  } catch {
    return null;
  }
}

function report(obj, code) {
  console.log(JSON.stringify(obj, null, 2));
  process.exit(code);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.error) report({ status: "BAD_ARGS", error: args.error }, 5);

  const { orgId, projectId } = readProjectLink();
  if (!projectId) report({ status: "NO_LINK", error: LINK_HELP }, 4);
  const token = readToken();
  if (!token) report({ status: "NO_TOKEN", error: TOKEN_HELP }, 4);
  const tq = teamQuery(orgId);
  const ctx = { token, projectId, team: tq ? `&${tq}` : "" };

  const startedAt = Date.now();
  const deadline = startedAt + args.maxSeconds * 1000;
  let lastState = null;
  let deployment = null;

  while (Date.now() < deadline) {
    try {
      deployment = await findDeployment(ctx, args.sha, args.target);
    } catch (e) {
      if (e.auth) report({ status: "AUTH_ERROR", error: `${e.message}: the token is invalid or has no access to the project — issue a new token and update VERCEL_TOKEN` }, 4);
      // A network failure on one iteration is no reason to give up, try again on the next.
      console.error(`[wait-vercel-deploy] request error: ${e.message}`);
    }

    if (deployment) {
      if (deployment.state !== lastState) {
        lastState = deployment.state;
        console.error(`[wait-vercel-deploy] ${Math.round((Date.now() - startedAt) / 1000)} s: ${lastState}`);
      }
      if (FINAL_STATES.has(deployment.state)) break;
      // 🔴 The API may stick on BUILDING although the build finished long ago. While the build runs,
      // `ready` EQUALS `buildingAt`; as soon as `ready` is greater — the build is finished.
      if (deployment.state === "BUILDING" && deployment.ready && deployment.buildingAt && deployment.ready > deployment.buildingAt) {
        deployment.state = "READY";
        deployment.stuckStateOverridden = true;
        break;
      }
    } else {
      console.error(`[wait-vercel-deploy] ${Math.round((Date.now() - startedAt) / 1000)} s: deploy ${args.sha.slice(0, 8)} (${args.target}) has not appeared yet`);
    }
    await sleep(args.interval * 1000);
  }

  const waited = Math.round((Date.now() - startedAt) / 1000);

  if (!deployment) {
    report({
      status: "NOT_FOUND", sha: args.sha, target: args.target, waitedSeconds: waited,
      hint: "check that the push/merge went through and the SHA is correct; a CLI deploy (`vercel deploy`) has no githubCommitSha and cannot be found by SHA; the GitHub→Vercel webhook may arrive with a delay of tens of minutes",
    }, 3);
  }

  const summary = {
    status: deployment.state,
    sha: deployment.meta?.githubCommitSha,
    branch: deployment.meta?.githubCommitRef,
    target: deployment.target ?? "preview",
    url: `https://${deployment.url}`,
    inspectorUrl: deployment.inspectorUrl,
    createdAt: deployment.created ? new Date(deployment.created).toISOString() : null,
    buildSeconds:
      deployment.ready && deployment.buildingAt && deployment.ready > deployment.buildingAt
        ? Math.round((deployment.ready - deployment.buildingAt) / 1000)
        : null,
    waitedSeconds: waited,
  };
  if (deployment.stuckStateOverridden) {
    summary.note = "the API kept state=BUILDING, but the ready timestamp is already set — the build is finished";
  }

  const id = deployment.uid ?? deployment.id;
  if (deployment.state === "READY") report(summary, 0);
  if (deployment.state === "BLOCKED") report({ ...summary, blocked: await blockReason(ctx, id) }, 1);
  if (deployment.state === "ERROR" || deployment.state === "CANCELED") {
    report({ ...summary, buildErrors: await buildErrors(ctx, id) }, 1);
  }
  report({ ...summary, note: "final status not reached in the allotted time — run again" }, 2);
}

main();
