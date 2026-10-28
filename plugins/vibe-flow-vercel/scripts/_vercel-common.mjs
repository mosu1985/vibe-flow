// Общие помощники скриптов vibe-flow-vercel: привязка к проекту и токен.
// 🔴 Значение токена никогда не печатается и не попадает в argv.

import { readFileSync } from "node:fs";
import { join } from "node:path";

export const API = "https://api.vercel.com";

// Читает одну переменную из .env.local проекта (без вывода значения).
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
    /* файла нет — не страшно */
  }
  return null;
}

// Привязка к проекту: env → .vercel/project.json (его создаёт `vercel link`).
export function readProjectLink(cwd = process.cwd()) {
  let orgId = process.env.VERCEL_ORG_ID || null;
  let projectId = process.env.VERCEL_PROJECT_ID || null;
  if (!orgId || !projectId) {
    try {
      const link = JSON.parse(readFileSync(join(cwd, ".vercel", "project.json"), "utf8"));
      orgId = orgId || link.orgId || null;
      projectId = projectId || link.projectId || null;
    } catch {
      /* нет привязки */
    }
  }
  return { orgId, projectId };
}

// Токен: env VERCEL_TOKEN → VERCEL_TOKEN из .env.local проекта.
export function readToken(cwd = process.cwd()) {
  return process.env.VERCEL_TOKEN || readEnvLocal("VERCEL_TOKEN", cwd) || null;
}

// team_… — командный аккаунт (нужен teamId); иначе личный, параметр teamId не передаётся.
export function teamQuery(orgId) {
  return orgId && orgId.startsWith("team_") ? `teamId=${orgId}` : "";
}

export const LINK_HELP =
  "нет привязки к проекту Vercel. Выполни в корне проекта `vercel link` (создаст .vercel/project.json) " +
  "или задай переменные окружения VERCEL_ORG_ID и VERCEL_PROJECT_ID.";

export const TOKEN_HELP =
  "нет токена Vercel. Создай токен на vercel.com/account/tokens и положи в .env.local строку " +
  "VERCEL_TOKEN=... (файл должен быть в .gitignore) либо экспортируй VERCEL_TOKEN в окружение.";

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
    // Тело ответа Vercel содержит код ошибки (например ExceedsBillingLimitError).
    try { err.body = (await res.text()).slice(0, 300); } catch { /* ignore */ }
    throw err;
  }
  // Vercel иногда отдаёт сырые управляющие символы в строках (многострочные сообщения
  // коммитов) — стандартный JSON.parse их принимает не всегда, поэтому чистим.
  const text = await res.text();
  return JSON.parse(text.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, " "));
}
