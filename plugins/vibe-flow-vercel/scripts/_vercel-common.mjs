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

export async function api(token, path) {
  const res = await fetch(`${API}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(20_000),
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
