#!/usr/bin/env node
// Ожидание деплоя Vercel до финального статуса — ОДНИМ блокирующим вызовом.
//
// ЗАЧЕМ: агент, ждавший деплой через `sleep`, молчал — харнесс Claude Code блокирует
// `sleep` на переднем плане, агент уходил в фоновый мониторинг, фон умирал вместе с ним,
// и отчёт READY/ERROR не приходил никогда. Здесь ожидание — `setTimeout` внутри node,
// то есть обычная команда, которая сама завершается с кодом возврата.
//
// 🔴 Деплой ищется по SHA коммита и target, а НЕ «последний»: параллельные сессии и
// соседи по команде пушат свои ветки каждые несколько минут, и `limit=1` вернёт чужой preview.
//
// 🔴 Токен — env VERCEL_TOKEN или VERCEL_TOKEN из .env.local проекта; в argv не попадает
// и нигде не печатается. Проект — из .vercel/project.json (`vercel link`) или
// VERCEL_ORG_ID / VERCEL_PROJECT_ID.
//
// Использование (из корня проекта):
//   node wait-vercel-deploy.mjs --sha <sha|префикс> [--target production|preview]
//        [--max-seconds 540] [--interval 15]
//   Без --sha берётся `git rev-parse origin/<защищённая ветка>` (по умолчанию origin/main,
//   иначе origin/master).
//
// Коды возврата: 0 READY · 1 ERROR/CANCELED/BLOCKED · 2 не дождались финала
//                · 3 деплой не найден · 4 нет доступа/токена/привязки · 5 неверные аргументы

import { execSync } from "node:child_process";
import {
  api, readProjectLink, readToken, teamQuery, LINK_HELP, TOKEN_HELP,
} from "./_vercel-common.mjs";

// BLOCKED — сборка не стартовала вовсе (например, Vercel не опознал автора коммита).
const FINAL_STATES = new Set(["READY", "ERROR", "CANCELED", "BLOCKED"]);

function defaultSha() {
  for (const ref of ["origin/main", "origin/master"]) {
    try {
      return execSync(`git rev-parse ${ref}`, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    } catch { /* пробуем следующую */ }
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
    else { return { error: `неизвестный аргумент ${key}` }; }
  }
  if (!["production", "preview"].includes(args.target)) return { error: "--target: production | preview" };
  // Потолок 570 с: вызов Bash у агента ограничен 600 с, ответ обязан успеть вернуться.
  if (!(args.maxSeconds > 0 && args.maxSeconds <= 570)) return { error: "--max-seconds: 1…570" };
  if (!(args.interval >= 5 && args.interval <= 60)) return { error: "--interval: 5…60" };
  if (!args.sha) {
    args.sha = defaultSha();
    if (!args.sha) return { error: "--sha не задан, а `git rev-parse origin/main` не сработал — передай --sha явно" };
  }
  if (!/^[0-9a-f]{7,40}$/i.test(args.sha)) return { error: "--sha: 7–40 hex-символов" };
  args.sha = args.sha.toLowerCase();
  return args;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function findDeployment(ctx, sha, target) {
  // Полный SHA — фильтр на стороне Vercel (находит и старый деплой); префикс — окно из
  // последних 100, где сравнение идёт по началу строки.
  const filter = sha.length === 40 ? `&meta-githubCommitSha=${sha}&limit=20` : "&limit=100";
  const data = await api(ctx.token, `/v6/deployments?projectId=${ctx.projectId}${ctx.team}${filter}`);
  const matches = (data.deployments ?? []).filter((d) => {
    const commit = String(d.meta?.githubCommitSha ?? "").toLowerCase();
    const isProd = d.target === "production";
    return commit.startsWith(sha) && (target === "production" ? isProd : !isProd);
  });
  // Самый свежий из подходящих: повторный редеплой того же SHA перекрывает прежний.
  matches.sort((a, b) => (b.created ?? 0) - (a.created ?? 0));
  return matches[0] ?? null;
}

async function buildErrors(ctx, deploymentId) {
  try {
    const events = await api(ctx.token, `/v3/deployments/${deploymentId}/events?limit=-1${ctx.team}`);
    const lines = (Array.isArray(events) ? events : [])
      .map((e) => String(e.payload?.text ?? e.text ?? "").trimEnd())
      .filter(Boolean);
    // Строки с признаком ошибки ловят Type error / Module not found; хвост лога даёт
    // контекст, когда причина сформулирована без слова «error» (OOM, SIGKILL, таймаут).
    return {
      errorLines: lines.filter((t) => /error|failed|✗|cannot|not found|killed|out of memory/i.test(t)).slice(-30),
      tail: lines.slice(-25),
    };
  } catch {
    return { errorLines: ["(build-лог получить не удалось)"], tail: [] };
  }
}

// Для BLOCKED причина лежит не в логах (их нет), а в readyStateReason / seatBlock.
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
      if (e.auth) report({ status: "AUTH_ERROR", error: `${e.message}: токен недействителен или не имеет доступа к проекту — выпусти новый токен и обнови VERCEL_TOKEN` }, 4);
      // Сетевой сбой одной итерации — не повод сдаваться, пробуем на следующей.
      console.error(`[wait-vercel-deploy] ошибка запроса: ${e.message}`);
    }

    if (deployment) {
      if (deployment.state !== lastState) {
        lastState = deployment.state;
        console.error(`[wait-vercel-deploy] ${Math.round((Date.now() - startedAt) / 1000)} с: ${lastState}`);
      }
      if (FINAL_STATES.has(deployment.state)) break;
      // 🔴 API может залипнуть на BUILDING, хотя сборка давно завершена. Пока сборка идёт,
      // `ready` РАВЕН `buildingAt`; как только `ready` стал больше — сборка закончена.
      if (deployment.state === "BUILDING" && deployment.ready && deployment.buildingAt && deployment.ready > deployment.buildingAt) {
        deployment.state = "READY";
        deployment.stuckStateOverridden = true;
        break;
      }
    } else {
      console.error(`[wait-vercel-deploy] ${Math.round((Date.now() - startedAt) / 1000)} с: деплой ${args.sha.slice(0, 8)} (${args.target}) ещё не появился`);
    }
    await sleep(args.interval * 1000);
  }

  const waited = Math.round((Date.now() - startedAt) / 1000);

  if (!deployment) {
    report({
      status: "NOT_FOUND", sha: args.sha, target: args.target, waitedSeconds: waited,
      hint: "проверь, что push/merge прошёл и SHA верный; деплой из CLI (`vercel deploy`) не имеет githubCommitSha и по SHA не находится; вебхук GitHub→Vercel может доехать с задержкой в десятки минут",
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
    summary.note = "API держал state=BUILDING, но метка ready уже проставлена — сборка завершена";
  }

  const id = deployment.uid ?? deployment.id;
  if (deployment.state === "READY") report(summary, 0);
  if (deployment.state === "BLOCKED") report({ ...summary, blocked: await blockReason(ctx, id) }, 1);
  if (deployment.state === "ERROR" || deployment.state === "CANCELED") {
    report({ ...summary, buildErrors: await buildErrors(ctx, id) }, 1);
  }
  report({ ...summary, note: "финальный статус не достигнут за отведённое время — запустить повторно" }, 2);
}

main();
