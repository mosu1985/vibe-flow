// Shared helpers for the vibe-flow-vercel scripts: project link and token.
// 🔴 The token value is never printed and never reaches argv.

import { readFileSync } from "node:fs";
import { join } from "node:path";

export const API = "https://api.vercel.com";

// Reads one variable from the project's .env.local (without printing the value).
function readEnvLocal(name, cwd) {
  try {
    const text = readFileSync(join(cwd, ".env.local"), "utf8");
    for (const raw of text.split(/\r?\n/)) {
      const line = raw.trim();
      if (!line || line.startsWith("#")) continue;
      const m = line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
      if (!m || m[1] !== name) continue;
      return m[2].replace(/^["']|["']$/g, "").trim() || null;
    }
  } catch {
    /* no file — not a problem */
  }
  return null;
}

// Project link: env → .vercel/project.json (created by `vercel link`).
export function readProjectLink(cwd = process.cwd()) {
  let orgId = process.env.VERCEL_ORG_ID || null;
  let projectId = process.env.VERCEL_PROJECT_ID || null;
  if (!orgId || !projectId) {
    try {
      const link = JSON.parse(readFileSync(join(cwd, ".vercel", "project.json"), "utf8"));
      orgId = orgId || link.orgId || null;
      projectId = projectId || link.projectId || null;
    } catch {
      /* no link */
    }
  }
  return { orgId, projectId };
}

// Token: env VERCEL_TOKEN → VERCEL_TOKEN from the project's .env.local.
export function readToken(cwd = process.cwd()) {
  return process.env.VERCEL_TOKEN || readEnvLocal("VERCEL_TOKEN", cwd) || null;
}

// team_… — a team account (teamId is needed); otherwise personal, the teamId parameter is not passed.
export function teamQuery(orgId) {
  return orgId && orgId.startsWith("team_") ? `teamId=${orgId}` : "";
}

export const LINK_HELP =
  "no Vercel project link. Run `vercel link` in the project root (creates .vercel/project.json) " +
  "or set the VERCEL_ORG_ID and VERCEL_PROJECT_ID environment variables.";

export const TOKEN_HELP =
  "no Vercel token. Create a token at vercel.com/account/tokens and put the line " +
  "VERCEL_TOKEN=... into .env.local (the file must be in .gitignore), or export VERCEL_TOKEN into the environment.";

export async function api(token, path, timeoutMs = 20_000) {
  const res = await fetch(`${API}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (res.status === 401 || res.status === 403) {
    const err = new Error(`auth ${res.status}`);
    err.auth = true;
    throw err;
  }
  if (!res.ok) {
    const err = new Error(`HTTP ${res.status}`);
    err.status = res.status;
    // The Vercel response body contains the error code (for example ExceedsBillingLimitError).
    try { err.body = (await res.text()).slice(0, 300); } catch { /* ignore */ }
    throw err;
  }
  // Vercel sometimes returns raw control characters in strings (multi-line messages
  // of commits) — the standard JSON.parse does not always accept them, so we clean them.
  const text = await res.text();
  return JSON.parse(text.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, " "));
}

// ── Production domains check (a READY build is not necessarily the one serving the domains) ──
// 🔴 Only GET requests. Everything that goes into a request path is validated and encoded.

// Host with an optional leading `*.`; anything else (slashes, dots-only, `..`, query) is rejected.
const HOST_RE = /^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;

const REQUEST_TIMEOUT_MS = 20_000;
const SAFETY_MS = 10_000; // never start a request that cannot finish before deadline − 10 s
const MIN_BUDGET_MS = 30_000; // less is left for domains → one check, a miss means "run again"

// "a.com,b.com" → { domains: [...] } | { error }
export function parseDomains(value) {
  const list = String(value ?? "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
  if (!list.length) return { error: "--domain: empty list" };
  for (const d of list) if (!HOST_RE.test(d)) return { error: `--domain: invalid host "${d.slice(0, 80)}"` };
  return { domains: [...new Set(list)] };
}

const defaultSleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Pure core. `get(path, timeoutMs)` returns parsed JSON or throws (`.auth` — 401/403, `.status` — HTTP code).
// Returns { outcome: "live"|"SUPERSEDED"|"NOT_LIVE"|"RETRY"|"NO_DOMAINS", prodAliases, error? }.
// prodAliases = { checked, live, missing, heldBy }: counts of checked / live domains, hosts not on this
// deployment, and { host: { deploymentId, createdAt } } for the deploy that holds a missing host.
export async function evaluateProdAliases(o) {
  const { get, teamQ, projectId, deploymentId, deadline } = o;
  const interval = o.interval ?? 15_000;
  const now = o.now ?? Date.now;
  const sleep = o.sleep ?? defaultSleep;
  const enc = encodeURIComponent;
  const url = (p) => (teamQ ? `${p}${p.includes("?") ? "&" : "?"}${teamQ}` : p);
  const call = (p) => {
    // The request timeout comes from what is left of the shared budget, not a fixed 20 s.
    const t = Math.min(REQUEST_TIMEOUT_MS, deadline - now() - SAFETY_MS);
    if (t < 1000) { const e = new Error("budget exhausted"); e.budget = true; throw e; }
    attempted = true;
    return get(url(p), t);
  };

  let domains = o.domains ? [...o.domains] : null;
  const singleShot = deadline - now() < MIN_BUDGET_MS;
  const holders = new Map(); // deploymentId → createdAt (ms) | null; a deploy never changes its createdAt
  let prodAliases = { checked: domains?.length ?? 0, live: 0, missing: [], heldBy: {} };
  let lastError = null;
  let attempted = false; // at least one request really went out
  let cleanPasses = 0;
  const result = (outcome, extra = {}) => ({ outcome, prodAliases, ...(lastError ? { error: lastError } : {}), ...extra });

  for (;;) {
    try {
      if (!domains) { // once per call, not per iteration
        const data = await call(`/v9/projects/${enc(projectId)}/domains?production=true&limit=100`);
        domains = (data.domains ?? []).filter((d) => d.name && !d.redirect).map((d) => String(d.name).toLowerCase());
        prodAliases.checked = domains.length;
      }
      if (!domains.length) return result("NO_DOMAINS");

      const al = await call(`/v2/deployments/${enc(deploymentId)}/aliases`);
      const have = new Set((al.aliases ?? []).map((a) => String(a.alias).toLowerCase()));
      const missing = domains.filter((d) => !have.has(d));
      prodAliases = { checked: domains.length, live: domains.length - missing.length, missing, heldBy: {} };
      lastError = null;
      cleanPasses++;
      if (!missing.length) return result("live");

      // Who holds the missing domains — in parallel.
      const held = await Promise.all(missing.map(async (d) => {
        try {
          const a = await call(`/v4/aliases/${enc(d)}`);
          return { d, id: a.deploymentId ?? null };
        } catch (e) {
          if (e.auth || e.budget) throw e;
          if (e.status === 404) return { d, id: null };
          throw e;
        }
      }));
      const foreign = held.filter((h) => h.id && h.id !== deploymentId);
      const ids = [...new Set(foreign.map((h) => h.id))].filter((id) => !holders.has(id));
      await Promise.all(ids.map(async (id) => {
        const dep = await call(`/v13/deployments/${enc(id)}`);
        holders.set(id, Number(dep.createdAt ?? dep.created) || null);
      }));
      let newer = false;
      for (const h of foreign) {
        const at = holders.get(h.id);
        prodAliases.heldBy[h.d] = { deploymentId: h.id, createdAt: at ? new Date(at).toISOString() : null };
        // Newer/older — by createdAt, never by id.
        if (at && o.createdAt && at > o.createdAt) newer = true;
      }
      if (newer) return result("SUPERSEDED");
    } catch (e) {
      if (e.auth) throw e;
      if (e.budget && !attempted) return result("RETRY", { error: "not enough time left to confirm the aliases" });
      if (!e.budget) lastError = e.message; // API/network failure: wait and try again, never "live"
    }

    if (singleShot) return result("RETRY");
    const wait = Math.min(interval, deadline - SAFETY_MS - now());
    if (wait <= 0) return result("NOT_LIVE");
    await sleep(wait);
  }
}
