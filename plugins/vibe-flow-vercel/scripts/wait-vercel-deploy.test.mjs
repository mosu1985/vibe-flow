// node --test plugins/vibe-flow-vercel/scripts/wait-vercel-deploy.test.mjs
// Tests the domain check with `fetch` replaced: no network, no token, no real waiting.
import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { evaluateProdAliases, parseDomains, api } from "./_vercel-common.mjs";

const realFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = realFetch; });

const OURS = "dpl_ours";
const OLD_AT = 1_000, NEW_AT = 2_000;
const clock = (start = 0) => {
  const c = { t: start, calls: [], now: () => c.t, sleep: async (ms) => { c.t += ms; } };
  return c;
};

// routes: [{ match: RegExp, reply: fn(url) → { status?, body? } | throws }]
function mockFetch(routes, log) {
  globalThis.fetch = async (input, init) => {
    const url = String(input);
    log?.push({ url, method: init?.method ?? "GET", timeout: init?.signal ? true : false });
    for (const r of routes) {
      if (r.match.test(url)) {
        const out = typeof r.reply === "function" ? r.reply(url) : r.reply;
        return new Response(JSON.stringify(out.body ?? {}), { status: out.status ?? 200 });
      }
    }
    return new Response("{}", { status: 404 });
  };
}

const call = (c, over = {}) => evaluateProdAliases({
  get: (p, t) => api("TEST", p, t),
  teamQ: "teamId=team_x", projectId: "prj_1", deploymentId: OURS, createdAt: OLD_AT,
  domains: null, deadline: c.t + 300_000, interval: 15_000, now: c.now, sleep: c.sleep, ...over,
});

const projectDomains = (list) => ({ match: /\/v9\/projects\/prj_1\/domains/, reply: { body: { domains: list } } });
const aliasesOf = (list) => ({ match: /\/v2\/deployments\/dpl_ours\/aliases/, reply: { body: { aliases: list.map((alias) => ({ alias })) } } });

test("live: every production domain is on this deployment", async () => {
  const log = [];
  mockFetch([projectDomains([{ name: "a.com" }, { name: "b.com" }]), aliasesOf(["a.com", "b.com", "x.vercel.app"])], log);
  const r = await call(clock());
  assert.equal(r.outcome, "live");
  assert.deepEqual(r.prodAliases, { checked: 2, live: 2, missing: [], heldBy: {} });
  assert.ok(log.every((l) => l.method === "GET"));
  assert.ok(log.every((l) => l.url.includes("teamId=team_x")), "teamId on every call");
});

test("redirect domains are skipped", async () => {
  mockFetch([projectDomains([{ name: "a.com" }, { name: "www.a.com", redirect: "a.com" }]), aliasesOf(["a.com"])]);
  const r = await call(clock());
  assert.equal(r.outcome, "live");
  assert.equal(r.prodAliases.checked, 1);
});

test("wildcard domain is checked, not skipped", async () => {
  const log = [];
  mockFetch([
    projectDomains([{ name: "a.com" }, { name: "*.a.com" }]), aliasesOf(["a.com"]),
    { match: /\/v4\/aliases\/\*\.a\.com/, reply: { body: { deploymentId: "dpl_new" } } },
    { match: /\/v13\/deployments\/dpl_new/, reply: { body: { createdAt: NEW_AT } } },
  ], log);
  const r = await call(clock());
  assert.equal(r.outcome, "SUPERSEDED");
  assert.deepEqual(r.prodAliases.missing, ["*.a.com"]);
  assert.ok(log.some((l) => l.url.includes("/v4/aliases/*.a.com")));
});

test("SUPERSEDED: a newer deploy holds the domain (by createdAt), exit-0 outcome", async () => {
  mockFetch([
    projectDomains([{ name: "a.com" }]), aliasesOf([]),
    { match: /\/v4\/aliases\/a\.com/, reply: { body: { deploymentId: "dpl_new" } } },
    { match: /\/v13\/deployments\/dpl_new/, reply: { body: { createdAt: NEW_AT } } },
  ]);
  const r = await call(clock());
  assert.equal(r.outcome, "SUPERSEDED");
  assert.equal(r.prodAliases.heldBy["a.com"].deploymentId, "dpl_new");
  assert.equal(r.prodAliases.heldBy["a.com"].createdAt, new Date(NEW_AT).toISOString());
});

test("an OLDER holder is not SUPERSEDED: waits, then NOT_LIVE", async () => {
  const c = clock();
  mockFetch([
    projectDomains([{ name: "a.com" }]), aliasesOf([]),
    { match: /\/v4\/aliases\/a\.com/, reply: { body: { deploymentId: "dpl_older" } } },
    { match: /\/v13\/deployments\/dpl_older/, reply: { body: { createdAt: 500 } } },
  ]);
  const r = await call(c, { createdAt: OLD_AT });
  assert.equal(r.outcome, "NOT_LIVE");
  assert.deepEqual(r.prodAliases.missing, ["a.com"]);
  assert.ok(c.t >= 200_000, "it waited inside the budget instead of failing at once");
  assert.ok(c.t <= 300_000 - 10_000, "and never past deadline − 10 s");
});

test("alias lands during the wait → live", async () => {
  let n = 0;
  mockFetch([
    projectDomains([{ name: "a.com" }]),
    { match: /\/v2\/deployments\/dpl_ours\/aliases/, reply: () => ({ body: { aliases: ++n >= 3 ? [{ alias: "a.com" }] : [] } }) },
    { match: /\/v4\/aliases\/a\.com/, reply: { status: 404 } },
  ]);
  const r = await call(clock());
  assert.equal(r.outcome, "live");
  assert.equal(n, 3);
});

test("--domain overrides the API list (no /v9 request)", async () => {
  const log = [];
  mockFetch([aliasesOf(["only.com"])], log);
  const r = await call(clock(), { domains: ["only.com"] });
  assert.equal(r.outcome, "live");
  assert.ok(!log.some((l) => l.url.includes("/v9/")));
});

test("project domains are fetched once per call, not per iteration", async () => {
  const log = [];
  mockFetch([projectDomains([{ name: "a.com" }]), aliasesOf([]), { match: /\/v4\/aliases/, reply: { status: 404 } }], log);
  await call(clock());
  assert.equal(log.filter((l) => l.url.includes("/v9/")).length, 1);
});

test("empty production domain list → NO_DOMAINS, nothing else requested", async () => {
  const log = [];
  mockFetch([projectDomains([{ name: "www.a.com", redirect: "a.com" }])], log);
  const r = await call(clock());
  assert.equal(r.outcome, "NO_DOMAINS");
  assert.equal(r.prodAliases.checked, 0);
  assert.equal(log.length, 1);
});

test("API 5xx: wait and retry, never live; success afterwards → live", async () => {
  let n = 0;
  mockFetch([
    projectDomains([{ name: "a.com" }]),
    { match: /\/v2\/deployments\/dpl_ours\/aliases/, reply: () => (++n < 3 ? { status: 503 } : { body: { aliases: [{ alias: "a.com" }] } }) },
  ]);
  const r = await call(clock());
  assert.equal(r.outcome, "live");
  assert.equal(n, 3);
});

test("API keeps failing (network error) → NOT_LIVE with error, never live", async () => {
  globalThis.fetch = async () => { throw new TypeError("fetch failed"); };
  const r = await call(clock(), { domains: ["a.com"] });
  assert.equal(r.outcome, "NOT_LIVE");
  assert.match(r.error, /fetch failed/);
});

test("auth error propagates (the caller reports AUTH_ERROR)", async () => {
  mockFetch([{ match: /./, reply: { status: 403 } }]);
  await assert.rejects(call(clock(), { domains: ["a.com"] }), (e) => e.auth === true);
});

test("not enough budget (< 30 s): one check, a miss → RETRY, not NOT_LIVE", async () => {
  const c = clock();
  mockFetch([projectDomains([{ name: "a.com" }]), aliasesOf([]), { match: /\/v4\/aliases/, reply: { status: 404 } }]);
  const r = await call(c, { deadline: c.t + 25_000 });
  assert.equal(r.outcome, "RETRY");
  assert.equal(c.t, 0, "did not sleep");
});

test("budget under the safety margin: no request is sent at all → RETRY", async () => {
  const log = [];
  mockFetch([projectDomains([{ name: "a.com" }])], log);
  const c = clock();
  const r = await call(c, { deadline: c.t + 5_000 });
  assert.equal(r.outcome, "RETRY");
  assert.equal(log.length, 0);
});

test("domain validation: path tricks are rejected before any request", () => {
  for (const bad of ["../../v9/projects/x/env?decrypt=true", "a.com/../b", "a.com?x=1", "*", "a", "-a.com", "a..com", "", " , "]) {
    assert.ok(parseDomains(bad).error, `must reject ${bad}`);
  }
  assert.deepEqual(parseDomains("A.com, *.B.com,a.com").domains, ["a.com", "*.b.com"]);
});

// End to end through the real script with `fetch` replaced by a preload module.
import { spawnSync } from "node:child_process";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
function runScript(args, aliasesOk) {
  const dir = mkdtempSync(join(tmpdir(), "wvd-"));
  const preload = join(dir, "preload.mjs");
  writeFileSync(preload, `
    const dep = { uid: "dpl_ours", state: "READY", created: 1000, buildingAt: 1000, ready: 5000, url: "x.vercel.app",
      meta: { githubCommitSha: "${"a".repeat(40)}" }, target: ${JSON.stringify(args.includes("preview") ? null : "production")} };
    globalThis.fetch = async (u) => {
      u = String(u);
      globalThis.__urls = (globalThis.__urls ?? []).concat(u);
      const out = (b) => new Response(JSON.stringify(b), { status: 200 });
      if (u.includes("/v6/deployments")) return out({ deployments: [dep] });
      if (u.includes("/v9/projects")) return out({ domains: [{ name: "a.com" }] });
      if (u.includes("/v2/deployments")) return out({ aliases: ${aliasesOk ? '[{ alias: "a.com" }]' : "[]"} });
      if (u.includes("/v4/aliases")) return out({ deploymentId: "dpl_new" });
      if (u.includes("/v13/deployments")) return out({ createdAt: 9000 });
      return new Response("{}", { status: 404 });
    };
    process.on("exit", () => console.error("URLS " + JSON.stringify(globalThis.__urls)));
  `);
  const res = spawnSync(process.execPath, ["--import", preload, join(here, "wait-vercel-deploy.mjs"), "--sha", "a".repeat(40), ...args],
    { encoding: "utf8", cwd: dir, env: { ...process.env, VERCEL_TOKEN: "fake", VERCEL_PROJECT_ID: "prj_1", VERCEL_ORG_ID: "team_x" } });
  return { code: res.status, out: res.stdout ? JSON.parse(res.stdout) : null, urls: (res.stderr.match(/URLS (.*)/) ?? [])[1] ?? "" };
}

test("script: target preview → no domain check, exit 0", () => {
  const r = runScript(["--target", "preview"], false);
  assert.equal(r.code, 0);
  assert.equal(r.out.prodAliases, undefined);
  assert.ok(!r.urls.includes("/v9/") && !r.urls.includes("/v2/deployments"));
});

test("script: production, domains on this deploy → live: true, exit 0", () => {
  const r = runScript(["--target", "production"], true);
  assert.equal(r.code, 0);
  assert.equal(r.out.live, true);
  assert.deepEqual(r.out.prodAliases, { checked: 1, live: 1, missing: [], heldBy: {} });
});

test("script: production, newer deploy holds the domain → SUPERSEDED, exit 0", () => {
  const r = runScript(["--target", "production"], false);
  assert.equal(r.code, 0);
  assert.equal(r.out.status, "SUPERSEDED");
  assert.equal(r.out.prodAliases.heldBy["a.com"].deploymentId, "dpl_new");
});

test("script: invalid --domain → BAD_ARGS, exit 5", () => {
  const r = runScript(["--domain", "../x"], true);
  assert.equal(r.code, 5);
});
