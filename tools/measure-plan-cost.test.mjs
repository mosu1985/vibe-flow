// node --test tools/measure-plan-cost.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  percentile, median, priceOf, costOf, normalizeUsage, lightRecord, collect, procedureWindows,
  analyzeSession, summarize, run, fileHasMarkers, readRecords, formatReport, classifyAgent,
} from "./measure-plan-cost.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const FIX = join(here, "fixtures", "project-basic");
const rec = (id, out, ts = 1, tools = [], extra = {}) => ({ id, ts, model: "claude-opus-5-5", usage: { input: 0, cache5m: 0, cache1h: 0, cacheRead: 0, output: out, ...extra }, tools });

test("dedup: one usage per message.id, the line with the most output wins, tools from all lines kept", () => {
  const c = collect([rec("a", 10, 1, [{ name: "EnterPlanMode" }]), rec("a", 40, 2, [{ name: "ExitPlanMode" }]), rec("b", 5)]);
  assert.equal(c.messages.length, 2);
  assert.equal(c.messages.find((m) => m.ts <= 2 && m.usage.output === 40) !== undefined, true);
  assert.deepEqual(c.events.map((e) => e.name), ["EnterPlanMode", "ExitPlanMode"]);
});

test("cache: 5m and 1h are separate; no split → counted as 5m", () => {
  assert.deepEqual(normalizeUsage({ input_tokens: 1, output_tokens: 2, cache_read_input_tokens: 3, cache_creation_input_tokens: 70, cache_creation: { ephemeral_5m_input_tokens: 20, ephemeral_1h_input_tokens: 50 } }),
    { input: 1, cache5m: 20, cache1h: 50, cacheRead: 3, output: 2 });
  assert.deepEqual(normalizeUsage({ cache_creation_input_tokens: 9 }), { input: 0, cache5m: 9, cache1h: 0, cacheRead: 0, output: 0 });
  // 1M tokens of each on Sonnet 5.5 (in $2, out $10, cache read $0.2): 1h write costs 2x input, 5m 1.25x
  const u = { input: 1e6, cache5m: 1e6, cache1h: 1e6, cacheRead: 1e6, output: 1e6 };
  assert.ok(Math.abs(costOf("claude-sonnet-5-5", u) - (2 + 2.5 + 4 + 0.2 + 10)) < 1e-9);
});

test("unknown model: no price → null (shown as —), but zero-token entries cost 0", () => {
  assert.equal(priceOf("some-future-model"), null);
  assert.equal(costOf("some-future-model", { input: 1, cache5m: 0, cache1h: 0, cacheRead: 0, output: 0 }), null);
  assert.equal(costOf("<synthetic>", { input: 0, cache5m: 0, cache1h: 0, cacheRead: 0, output: 0 }), 0);
  assert.ok(priceOf("claude-haiku-4-5-20251001"), "a date suffix is stripped");
});

test("percentiles: 1, 2 and an even number of sessions", () => {
  assert.equal(median([7]), 7);
  assert.equal(percentile([7], 0.9), 7);
  assert.equal(median([10, 20]), 15);
  assert.ok(Math.abs(percentile([10, 20], 0.9) - 19) < 1e-9);
  assert.equal(median([4, 1, 3, 2]), 2.5);
  assert.ok(Math.abs(percentile([1, 2, 3, 4], 0.9) - 3.7) < 1e-9);
  assert.equal(median([]), null);
});

test("a session without ExitPlanMode (or without the Skill call) has no procedure", () => {
  const skill = { name: "Skill", skill: "plan-mode-review" };
  assert.equal(procedureWindows(collect([rec("a", 1, 1, [skill])]).events), null);
  assert.equal(procedureWindows(collect([rec("a", 1, 1, [{ name: "ExitPlanMode" }])]).events), null);
  assert.equal(analyzeSession({ main: [rec("a", 1, 1, [skill])], subagents: [] }), null);
});

test("window starts at EnterPlanMode, or at the Skill call when there was none", () => {
  const skill = { name: "Skill", skill: "plan-mode-review" };
  const w1 = procedureWindows(collect([rec("a", 1, 5, [{ name: "EnterPlanMode" }]), rec("b", 1, 9, [skill]), rec("c", 1, 20, [{ name: "ExitPlanMode" }])]).events);
  assert.deepEqual(w1, [[5, 20]]);
  const w2 = procedureWindows(collect([rec("b", 1, 9, [skill]), rec("c", 1, 20, [{ name: "ExitPlanMode" }])]).events);
  assert.deepEqual(w2, [[9, 20]]);
});

test("agent groups: reviewers, critic, anything else is 'other'", () => {
  assert.equal(classifyAgent("security-reviewer"), "reviewers");
  assert.equal(classifyAgent("access-control-reviewer"), "reviewers");
  assert.equal(classifyAgent("codex-plan-critic"), "critic");
  assert.equal(classifyAgent("Explore"), "other");
  assert.equal(classifyAgent("unknown"), "other");
});

test("fixture session: exact numbers per group, windowing, dedup, unknown model", async () => {
  const res = await run(FIX, { days: 36500 });
  assert.equal(res.sessions.length, 1, "B (no Skill) and C (no Exit) are excluded");
  const s = res.sessions[0];
  assert.equal(s.groups.main.tokens, 1679);      // m1 + m2 (once, output 60) + m3; m0 and m4 are outside the window
  assert.equal(s.groups.reviewers.tokens, 325);  // r1 inside; r2 after the window is session-only
  assert.equal(s.groups.critic.tokens, 433);
  assert.equal(s.groups.other.tokens, 35);
  assert.equal(s.groups.other.usd, null, "unknown model → no money");
  assert.equal(s.groups.session.usd, null);
  assert.equal(s.groups.session.tokens, 3630);
  assert.equal(s.procedureTokens, 2437);
  assert.notEqual(s.procedureUsd, null, "procedure groups only use priced models");
  assert.equal(s.windowMs, 25 * 60_000);
  assert.equal(s.groups.main.byModel["claude-opus-5-5"].cache1h, 700);
  assert.equal(s.groups.main.byModel["claude-opus-5-5"].cache5m, 300);
});

test("report shows numbers only and — for unknown prices", async () => {
  const res = await run(FIX, { days: 36500 });
  const text = formatReport(res, 36500);
  assert.match(text, /whole session \| 3,630 \| 3,630 \| 3,630 \| —/);
  assert.match(text, /share of session tokens: 67\.1%/);
  assert.doesNotMatch(text, /mentions plan-mode-review in text only/);
});

test("summarize: median and p90 over several sessions", () => {
  const mk = (t) => ({ windowMs: 60000, procedureTokens: t, procedureUsd: 1, groups: Object.fromEntries(["reviewers", "critic", "main", "other", "session"].map((g) => [g, { tokens: t, usd: 1, byModel: {} }])) });
  const s = summarize([mk(10), mk(20), mk(30), mk(40)]);
  assert.equal(s.procedure.median, 25);
  assert.ok(Math.abs(s.procedure.p90 - 37) < 1e-9);
  assert.equal(s.sessions, 4);
});

test("empty directory → a clear message, not a crash", async () => {
  const dir = mkdtempSync(join(tmpdir(), "mpc-"));
  assert.match((await run(dir)).message, /no transcripts newer than 30 days/);
  assert.match((await run(join(dir, "nope"))).message, /directory not found/);
});

test("old files are skipped by mtime; files without both markers never reach JSON parsing", async () => {
  const dir = mkdtempSync(join(tmpdir(), "mpc-"));
  const f = join(dir, "old.jsonl");
  writeFileSync(f, "not json at all plan-mode-review ExitPlanMode\n");
  const old = new Date(Date.now() - 90 * 86_400_000);
  utimesSync(f, old, old);
  assert.match((await run(dir, { days: 30 })).message, /no transcripts newer/);
  const g = join(dir, "fresh.jsonl");
  writeFileSync(g, "garbage without markers\n{broken\n");
  assert.match((await run(dir, { days: 30 })).message, /no sessions with the plan-mode-review procedure/);
  assert.equal(await fileHasMarkers(g), false);
  assert.equal(await fileHasMarkers(f), true);
});

test("the Buffer pre-filter finds a marker split across stream chunks", async () => {
  const dir = mkdtempSync(join(tmpdir(), "mpc-"));
  const f = join(dir, "big.jsonl");
  // 64 KiB chunks: put the first marker so that it straddles the first chunk boundary.
  const pad = "x".repeat(65536 - 5);
  writeFileSync(f, pad + "plan-mode-review" + "y".repeat(100) + "ExitPlanMode");
  assert.equal(await fileHasMarkers(f), true);
});

test("a broken line in a selected transcript is skipped, the rest is read", async () => {
  const dir = mkdtempSync(join(tmpdir(), "mpc-"));
  const f = join(dir, "s.jsonl");
  writeFileSync(f, '{"type":"assistant", broken\n' + JSON.stringify({ type: "assistant", timestamp: "2026-10-20T10:00:00Z", message: { id: "z", model: "claude-opus-5-5", usage: { output_tokens: 3 }, content: [] } }) + "\n");
  const r = await readRecords(f);
  assert.equal(r.length, 1);
  assert.equal(r[0].usage.output, 3);
  assert.equal(lightRecord({ type: "user" }), null);
});
