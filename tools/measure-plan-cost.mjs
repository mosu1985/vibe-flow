#!/usr/bin/env node
// Measures what the Plan Mode procedure costs, from Claude Code transcripts.
//
// Usage: node tools/measure-plan-cost.mjs <project dir in ~/.claude/projects> [--days 30] [--json]
//
// A session "has the procedure" when its main jsonl holds a Skill call for plan-mode-review AND an
// ExitPlanMode call. The procedure window is EnterPlanMode (or the plan-mode-review Skill call when there
// was none) → the next ExitPlanMode. Groups:
//   reviewers  — plan reviewers' subagents inside the window
//   critic     — codex-plan-critic subagents inside the window (Codex's own tokens are NOT visible here)
//   main       — the main session's own assistant turns inside the window
//   other      — subagents of any other / unknown agentType (whole session, not windowed)
//   session    — everything in the session
// procedure = reviewers + critic + main; share = procedure / session.
//
// Token counts are the primary metric. Money is shown only for models with a known price (table below),
// otherwise "—". Only numbers are printed: no message text ever reaches the output.
//
// Reading is streaming (readline over createReadStream); files are pre-filtered by mtime and by a cheap Buffer
// search for both marker strings before any JSON is parsed; subagent files are read only for selected sessions.

import { createReadStream, readdirSync, statSync, readFileSync, existsSync } from "node:fs";
import { createInterface } from "node:readline";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

// ── Prices, USD per 1M tokens. Source: the claude-api skill model table, cached 2026-10-06. ──
// cacheRead is listed where the skill states it explicitly, otherwise 0.1x input. Cache writes: 1.25x input
// (5 min TTL), 2x input (1 h TTL). Haiku 5.5 is priced for prompts up to 100K tokens.
export const PRICES_AS_OF = "2026-10-06";
export const PRICES = {
  "claude-fable-5-1": { in: 10, out: 50, cacheRead: 0.25 },
  "claude-mythos-5-1": { in: 10, out: 50, cacheRead: 0.25 },
  "claude-fable-5": { in: 10, out: 50, cacheRead: 0.25 },
  "claude-opus-5-5": { in: 4, out: 20, cacheRead: 0.2 },
  "claude-opus-5": { in: 5, out: 25, cacheRead: 0.5 },
  "claude-opus-4-8": { in: 5, out: 25, cacheRead: 0.5 },
  "claude-opus-4-7": { in: 5, out: 25, cacheRead: 0.5 },
  "claude-opus-4-6": { in: 5, out: 25, cacheRead: 0.5 },
  "claude-sonnet-5-5": { in: 2, out: 10, cacheRead: 0.2 },
  "claude-sonnet-5": { in: 2, out: 10, cacheRead: 0.2 },
  "claude-sonnet-4-6": { in: 3, out: 15, cacheRead: 0.3 },
  "claude-haiku-5-5": { in: 0.1, out: 0.5, cacheRead: 0.01 },
  "claude-haiku-4-5": { in: 1, out: 5, cacheRead: 0.1 },
};

export const REVIEWERS = new Set([
  "plan-reviewer", "module-governance-reviewer", "access-control-reviewer", "test-impact-reviewer",
  "security-reviewer", "performance-reviewer", "orchestration-router", "elevenlabs-agent",
]);
export const CRITICS = new Set(["codex-plan-critic"]);

export const classifyAgent = (agentType) => (REVIEWERS.has(agentType) ? "reviewers" : CRITICS.has(agentType) ? "critic" : "other");

// ── Pure helpers ──

export function priceOf(model) {
  const key = String(model ?? "").replace(/\[.*\]$/, "").replace(/-\d{8}$/, "");
  return PRICES[key] ?? null;
}

const zeroUsage = () => ({ input: 0, cache5m: 0, cache1h: 0, cacheRead: 0, output: 0 });
export const totalTokens = (u) => u.input + u.cache5m + u.cache1h + u.cacheRead + u.output;

export function addUsage(a, b) {
  return { input: a.input + b.input, cache5m: a.cache5m + b.cache5m, cache1h: a.cache1h + b.cache1h, cacheRead: a.cacheRead + b.cacheRead, output: a.output + b.output };
}

// USD for one usage block on one model, or null when the price is unknown.
export function costOf(model, u) {
  if (totalTokens(u) === 0) return 0; // e.g. "<synthetic>" entries: nothing to bill, price irrelevant
  const p = priceOf(model);
  if (!p) return null;
  return (u.input * p.in + u.cache5m * p.in * 1.25 + u.cache1h * p.in * 2 + u.cacheRead * p.cacheRead + u.output * p.out) / 1e6;
}

// Linear interpolation between ranks (the "type 7" percentile). One value → itself.
export function percentile(values, q) {
  if (!values.length) return null;
  const s = [...values].sort((a, b) => a - b);
  const pos = (s.length - 1) * q;
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
}
export const median = (values) => percentile(values, 0.5);

// usage object of a transcript line → normalized fields. cache_creation without the 5m/1h split counts as 5m.
export function normalizeUsage(u) {
  if (!u) return zeroUsage();
  const split = u.cache_creation;
  const c5 = split ? split.ephemeral_5m_input_tokens ?? 0 : u.cache_creation_input_tokens ?? 0;
  const c1 = split ? split.ephemeral_1h_input_tokens ?? 0 : 0;
  return { input: u.input_tokens ?? 0, cache5m: c5, cache1h: c1, cacheRead: u.cache_read_input_tokens ?? 0, output: u.output_tokens ?? 0 };
}

// Light record of one transcript line (or null): { id, ts, model, usage, tools:[{name, skill}] }.
export function lightRecord(obj) {
  if (obj?.type !== "assistant" || !obj.message) return null;
  const tools = [];
  for (const c of Array.isArray(obj.message.content) ? obj.message.content : []) {
    if (c?.type === "tool_use") tools.push({ name: c.name, skill: c.name === "Skill" ? String(c.input?.skill ?? "") : undefined });
  }
  return { id: obj.message.id ?? null, ts: Date.parse(obj.timestamp) || 0, model: obj.message.model ?? null, usage: normalizeUsage(obj.message.usage), tools };
}

// One API response is spread over several lines with the same message.id: one usage per id (the line with the
// most output wins — earlier lines of a streamed answer carry partial output), tool calls from all its lines.
export function collect(records) {
  const byId = new Map();
  const events = [];
  let anon = 0;
  for (const r of records) {
    for (const t of r.tools) events.push({ ts: r.ts, name: t.name, skill: t.skill });
    const key = r.id ?? `anon-${anon++}`;
    const prev = byId.get(key);
    if (!prev) byId.set(key, { ts: r.ts, model: r.model, usage: r.usage });
    else {
      if (r.usage.output > prev.usage.output) prev.usage = r.usage;
      prev.ts = Math.min(prev.ts, r.ts) || prev.ts;
      prev.model = prev.model ?? r.model;
    }
  }
  return { messages: [...byId.values()], events };
}

// Procedure windows from main-session tool events: [Enter (or the plan-mode-review Skill call), next Exit].
export function procedureWindows(events) {
  const ev = [...events].sort((a, b) => a.ts - b.ts);
  const hasSkill = ev.some((e) => e.name === "Skill" && e.skill.includes("plan-mode-review"));
  const hasExit = ev.some((e) => e.name === "ExitPlanMode");
  if (!hasSkill || !hasExit) return null; // no procedure in this session
  const skillTs = ev.find((e) => e.name === "Skill" && e.skill.includes("plan-mode-review")).ts;
  const windows = [];
  let start = null;
  for (const e of ev) {
    if (e.name === "EnterPlanMode" && start === null) start = e.ts;
    if (e.name === "ExitPlanMode") {
      windows.push([start ?? Math.min(skillTs, e.ts), e.ts]);
      start = null;
    }
  }
  return windows;
}

const inWindows = (ts, windows) => windows.some(([a, b]) => ts >= a && ts <= b);

function sumByModel(messages) {
  const m = {};
  for (const x of messages) m[x.model ?? "unknown"] = addUsage(m[x.model ?? "unknown"] ?? zeroUsage(), x.usage);
  return m;
}

// Pure core: { main: records[], subagents: [{agentType, records[]}] } → null (no procedure) or per-group numbers.
export function analyzeSession({ main, subagents }) {
  const mainC = collect(main);
  const windows = procedureWindows(mainC.events);
  if (!windows) return null;
  const groups = { reviewers: [], critic: [], main: [], other: [], session: [] };
  groups.main = mainC.messages.filter((m) => inWindows(m.ts, windows));
  groups.session.push(...mainC.messages);
  for (const s of subagents) {
    const msgs = collect(s.records).messages;
    groups.session.push(...msgs);
    const g = classifyAgent(s.agentType);
    if (g === "other") groups.other.push(...msgs);
    else groups[g].push(...msgs.filter((m) => inWindows(m.ts, windows)));
  }
  const out = { windowMs: windows.reduce((a, [s, e]) => a + (e - s), 0), groups: {} };
  for (const [name, msgs] of Object.entries(groups)) {
    const byModel = sumByModel(msgs);
    let usd = 0, known = true;
    for (const [model, u] of Object.entries(byModel)) {
      const c = costOf(model, u);
      if (c === null) known = false; else usd += c;
    }
    out.groups[name] = { tokens: msgs.reduce((a, m) => a + totalTokens(m.usage), 0), byModel, usd: known ? usd : null, calls: msgs.length };
  }
  const proc = ["reviewers", "critic", "main"].map((g) => out.groups[g]);
  out.procedureTokens = proc.reduce((a, g) => a + g.tokens, 0);
  out.procedureUsd = proc.every((g) => g.usd !== null) ? proc.reduce((a, g) => a + g.usd, 0) : null;
  return out;
}

// Aggregates per-session results: median / p90 / sum per group, share of the procedure in the session.
export function summarize(sessions) {
  const groups = {};
  for (const name of ["reviewers", "critic", "main", "other", "session"]) {
    const toks = sessions.map((s) => s.groups[name].tokens);
    const usds = sessions.map((s) => s.groups[name].usd);
    groups[name] = {
      median: median(toks), p90: percentile(toks, 0.9), sum: toks.reduce((a, b) => a + b, 0),
      usdSum: usds.every((x) => x !== null) ? usds.reduce((a, b) => a + b, 0) : null,
    };
  }
  const procTokens = sessions.map((s) => s.procedureTokens);
  const sessTokens = sessions.reduce((a, s) => a + s.groups.session.tokens, 0);
  const times = sessions.map((s) => s.windowMs / 60000);
  const models = {};
  for (const s of sessions) for (const g of ["reviewers", "critic", "main"]) for (const [m, u] of Object.entries(s.groups[g].byModel)) models[m] = addUsage(models[m] ?? zeroUsage(), u);
  return {
    sessions: sessions.length,
    groups,
    procedure: { median: median(procTokens), p90: percentile(procTokens, 0.9), sum: procTokens.reduce((a, b) => a + b, 0) },
    shareOfSession: sessTokens ? procTokens.reduce((a, b) => a + b, 0) / sessTokens : null,
    minutes: { median: median(times), p90: percentile(times, 0.9), sum: times.reduce((a, b) => a + b, 0) },
    models,
  };
}

// ── I/O ──

// Cheap pre-filter: both markers present in the file, found on raw Buffers (chunk boundaries handled).
export async function fileHasMarkers(file, markers = ["plan-mode-review", "ExitPlanMode"]) {
  const needles = markers.map((m) => Buffer.from(m));
  const found = needles.map(() => false);
  const keep = Math.max(...needles.map((n) => n.length)) - 1;
  let tail = Buffer.alloc(0);
  for await (const chunk of createReadStream(file)) {
    const buf = Buffer.concat([tail, chunk]);
    needles.forEach((n, i) => { if (!found[i] && buf.includes(n)) found[i] = true; });
    if (found.every(Boolean)) return true;
    tail = buf.subarray(Math.max(0, buf.length - keep));
  }
  return false;
}

export async function readRecords(file) {
  const records = [];
  const rl = createInterface({ input: createReadStream(file), crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line.includes('"type":"assistant"')) continue; // skip user/system/snapshot lines without parsing
    try {
      const r = lightRecord(JSON.parse(line));
      if (r) records.push(r);
    } catch { /* a broken line is not a reason to fail the run */ }
  }
  return records;
}

async function readSubagents(sessionDir) {
  const dir = join(sessionDir, "subagents");
  if (!existsSync(dir)) return [];
  const out = [];
  for (const f of readdirSync(dir).filter((x) => x.endsWith(".jsonl"))) {
    let agentType = "unknown";
    try { agentType = JSON.parse(readFileSync(join(dir, f.replace(/\.jsonl$/, ".meta.json")), "utf8")).agentType ?? "unknown"; } catch { /* no meta */ }
    out.push({ agentType, records: await readRecords(join(dir, f)) });
  }
  return out;
}

// Whole run over a project directory → { files, selected, sessions: [...results], summary } | { message }.
export async function run(dir, { days = 30, now = Date.now() } = {}) {
  if (!existsSync(dir)) return { message: `directory not found: ${dir}` };
  const cutoff = now - days * 86_400_000;
  const files = readdirSync(dir).filter((f) => f.endsWith(".jsonl")).map((f) => join(dir, f))
    .filter((f) => statSync(f).mtimeMs >= cutoff);
  if (!files.length) return { message: `no transcripts newer than ${days} days in ${dir}` };
  const sessions = [];
  for (const f of files) {
    if (!(await fileHasMarkers(f))) continue;
    const main = await readRecords(f);
    const subagents = await readSubagents(f.replace(/\.jsonl$/, ""));
    const r = analyzeSession({ main, subagents });
    if (r) sessions.push(r);
  }
  if (!sessions.length) return { message: `no sessions with the plan-mode-review procedure (Skill + ExitPlanMode) among ${files.length} transcripts` };
  return { files: files.length, sessions, summary: summarize(sessions) };
}

// ── Output (numbers only) ──
const fmt = (n) => (n === null || n === undefined ? "—" : Math.round(n).toLocaleString("en-US"));
const usd = (n) => (n === null || n === undefined ? "—" : `$${n.toFixed(2)}`);

export function formatReport(res, days) {
  const s = res.summary;
  const L = [];
  L.push(`Plan Mode procedure cost — ${s.sessions} sessions with the procedure of ${res.files} transcripts (last ${days} days)`);
  L.push(`Tokens = input + cache writes (5m, 1h) + cache reads + output. Prices as of ${PRICES_AS_OF}; "—" = no price known.`);
  L.push("");
  L.push("group | median tok | p90 tok | sum tok | sum USD");
  L.push("--- | ---: | ---: | ---: | ---:");
  const names = { reviewers: "plan reviewers", critic: "critic (Codex's own tokens are not visible)", main: "main session in plan mode", other: "other subagents (whole session)", session: "whole session" };
  for (const g of ["reviewers", "critic", "main"]) L.push(`${names[g]} | ${fmt(s.groups[g].median)} | ${fmt(s.groups[g].p90)} | ${fmt(s.groups[g].sum)} | ${usd(s.groups[g].usdSum)}`);
  const procUsd = ["reviewers", "critic", "main"].every((g) => s.groups[g].usdSum !== null) ? ["reviewers", "critic", "main"].reduce((a, g) => a + s.groups[g].usdSum, 0) : null;
  L.push(`**procedure total** | ${fmt(s.procedure.median)} | ${fmt(s.procedure.p90)} | ${fmt(s.procedure.sum)} | ${usd(procUsd)}`);
  for (const g of ["other", "session"]) L.push(`${names[g]} | ${fmt(s.groups[g].median)} | ${fmt(s.groups[g].p90)} | ${fmt(s.groups[g].sum)} | ${usd(s.groups[g].usdSum)}`);
  L.push("");
  L.push(`procedure share of session tokens: ${s.shareOfSession === null ? "—" : (s.shareOfSession * 100).toFixed(1) + "%"}`);
  L.push(`procedure time (plan-mode windows), minutes: median ${s.minutes.median.toFixed(1)}, p90 ${s.minutes.p90.toFixed(1)}, sum ${s.minutes.sum.toFixed(0)}`);
  L.push("");
  L.push("procedure tokens by model | input | cache write 5m | cache write 1h | cache read | output | USD");
  L.push("--- | ---: | ---: | ---: | ---: | ---: | ---:");
  for (const [m, u] of Object.entries(s.models).sort((a, b) => totalTokens(b[1]) - totalTokens(a[1]))) {
    L.push(`${m}${priceOf(m) ? "" : " (no price)"} | ${fmt(u.input)} | ${fmt(u.cache5m)} | ${fmt(u.cache1h)} | ${fmt(u.cacheRead)} | ${fmt(u.output)} | ${usd(costOf(m, u))}`);
  }
  return L.join("\n");
}

async function cli(argv) {
  const dir = argv.find((a) => !a.startsWith("--") && argv[argv.indexOf(a) - 1] !== "--days");
  const di = argv.indexOf("--days");
  const days = di >= 0 ? Number(argv[di + 1]) : 30;
  if (!dir || !(days > 0)) { console.error("usage: measure-plan-cost.mjs <project dir> [--days 30] [--json]"); process.exit(2); }
  const res = await run(dir, { days });
  if (res.message) { console.log(res.message); process.exit(res.message.startsWith("directory") ? 2 : 0); }
  console.log(argv.includes("--json") ? JSON.stringify(res.summary, null, 2) : formatReport(res, days));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) cli(process.argv.slice(2));
