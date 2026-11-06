#!/usr/bin/env node
/**
 * gen-codemap.mjs — shared "code map" generator (Node >= 18, no dependencies).
 *
 * Scans the project (fs + regex) and writes a greppable index to docs/codemap/:
 *   INDEX.md       — counters, top-level directory tree
 *   routes.md      — HTTP entry points: Next.js (app/pages router), Express/Fastify,
 *                    FastAPI/Flask, Django urls
 *   pages.md       — Next.js pages (app/**\/page.*, pages/**)
 *   exports.md     — TS/JS module exports and top-level def/class in Python
 *   migrations.md  — migration files (migrations/ directories)
 *
 * Usage (from the project root):
 *   node gen-codemap.mjs [--root <dir>] [--out <dir>]
 *   --root  project root (default: current directory)
 *   --out   where to write (default: <root>/docs/codemap)
 *
 * Output is deterministic: no timestamps, so regenerating without
 * code changes produces no diff (otherwise INDEX.md "changes" on every run).
 */
import fs from "node:fs";
import path from "node:path";

// ── arguments ───────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
function arg(name) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}
const ROOT = path.resolve(arg("--root") || process.cwd());
const OUT_DIR = path.resolve(arg("--out") || path.join(ROOT, "docs", "codemap"));

// Directories we do not walk
const SKIP_DIRS = new Set([
  "node_modules", ".git", "dist", "build", ".next", ".nuxt", ".svelte-kit", ".output",
  "venv", ".venv", "env", "__pycache__", "site-packages", ".tox", ".mypy_cache",
  ".pytest_cache", "coverage", "target", "out", "vendor", ".turbo", ".cache",
  ".vercel", ".idea", ".vscode", "Pods", "DerivedData",
]);
const MAX_FILE_BYTES = 512 * 1024; // large files (bundles, dumps) are not read
const JS_EXT = /\.(?:[cm]?[jt]s|[jt]sx)$/;
const PY_EXT = /\.py$/;

// ── walk ───────────────────────────────────────────────────────────────────
/** @type {{abs:string, rel:string, size:number}[]} */
const files = [];
function walk(dir) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  for (const e of entries) {
    const abs = path.join(dir, e.name);
    if (e.isDirectory()) {
      // skip hidden and service directories and the output directory itself
      if (SKIP_DIRS.has(e.name) || e.name.startsWith(".") || abs === OUT_DIR) continue;
      walk(abs);
    } else if (e.isFile()) {
      let size = 0;
      try { size = fs.statSync(abs).size; } catch { /* skip */ }
      files.push({ abs, rel: path.relative(ROOT, abs).split(path.sep).join("/"), size });
    }
  }
}
walk(ROOT);

function read(f) {
  if (f.size > MAX_FILE_BYTES) return "";
  try { return fs.readFileSync(f.abs, "utf8"); } catch { return ""; }
}
const isTest = (rel) =>
  /(?:^|\/)(?:__tests__|tests?|e2e)\//.test(rel) ||
  /\.(?:test|spec)\.[cm]?[jt]sx?$/.test(rel) ||
  /(?:^|\/)test_[^/]+\.py$|_test\.py$|(?:^|\/)conftest\.py$/.test(rel);

// ── Next.js: routes ───────────────────────────────────────────────────────
const HTTP = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"];

/** app-router file path → URL: strip app/, the file name, (groups) and @slots */
function appUrl(rel) {
  const m = rel.match(/(?:^|\/)(?:src\/)?app\/(.*)$/);
  if (!m) return null;
  const segs = m[1].split("/");
  segs.pop();
  const url = segs.filter((s) => !/^\(.*\)$/.test(s) && !s.startsWith("@")).join("/");
  return "/" + url;
}
/** pages-router file path → URL */
function pagesUrl(rel) {
  const m = rel.match(/(?:^|\/)(?:src\/)?pages\/(.*)$/);
  if (!m) return null;
  let p = m[1].replace(/\.[^.]+$/, "").replace(/(^|\/)index$/, "");
  return "/" + p;
}

const routes = []; // {url, methods, file, kind}
const pages = []; // {url, file, kind}

for (const f of files) {
  // isTest is not applied here: app/api/test/route.ts is a real route
  if (!JS_EXT.test(f.rel) || /\.(?:test|spec)\.[cm]?[jt]sx?$/.test(f.rel)) continue;

  // app router: route.ts
  if (/(?:^|\/)(?:src\/)?app\/(?:.*\/)?route\.[cm]?[jt]sx?$/.test(f.rel)) {
    const src = read(f);
    const methods = new Set();
    for (const mm of src.matchAll(/export\s+(?:async\s+)?function\s+(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\b/g)) methods.add(mm[1]);
    for (const mm of src.matchAll(/export\s+const\s+(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\b/g)) methods.add(mm[1]);
    for (const mm of src.matchAll(/export\s*\{([^}]*)\}/g))
      for (const n of mm[1].split(",")) {
        const nm = n.trim().split(/\s+as\s+/).pop();
        if (HTTP.includes(nm)) methods.add(nm);
      }
    routes.push({ url: appUrl(f.rel), methods: HTTP.filter((x) => methods.has(x)), file: f.rel, kind: "next-app" });
    continue;
  }
  // app router: page.tsx
  if (/(?:^|\/)(?:src\/)?app\/(?:.*\/)?page\.[cm]?[jt]sx?$/.test(f.rel)) {
    pages.push({ url: appUrl(f.rel), file: f.rel, kind: "next-app" });
    continue;
  }
  // pages router
  if (/(?:^|\/)(?:src\/)?pages\//.test(f.rel) && !/\/_(?:app|document|error|middleware)\./.test(f.rel)) {
    const url = pagesUrl(f.rel);
    if (/^\/api(?:\/|$)/.test(url)) {
      routes.push({ url, methods: [], file: f.rel, kind: "next-pages-api" });
    } else if (/\.(?:tsx|jsx)$/.test(f.rel)) {
      pages.push({ url, file: f.rel, kind: "next-pages" });
    }
    continue;
  }
}

// ── Express / Fastify / Hono / Koa-router: rough regex ─────────────────────
const NODE_ROUTE_RE =
  /\b([A-Za-z_$][\w$]*)\.(get|post|put|patch|delete|all|options|head)\(\s*(['"`])((?:\/|\*)[^'"`]*)\3/g;
const NODE_ROUTER_NAME = /^(?:app|router|server|fastify|api|route|routes|r|[\w$]*(?:Router|router|App|app|Server|server|Api|api))$/;
for (const f of files) {
  if (!JS_EXT.test(f.rel) || isTest(f.rel)) continue;
  if (/(?:^|\/)(?:src\/)?(?:app|pages)\//.test(f.rel) && /(?:route|page)\.[cm]?[jt]sx?$/.test(f.rel)) continue;
  const src = read(f);
  if (!src || !/\.(?:get|post|put|patch|delete|all)\(/.test(src)) continue;
  for (const mm of src.matchAll(NODE_ROUTE_RE)) {
    if (!NODE_ROUTER_NAME.test(mm[1])) continue;
    routes.push({ url: mm[4], methods: [mm[2].toUpperCase()], file: f.rel, kind: "node-router" });
  }
}

// ── Python: FastAPI / Flask / Django ────────────────────────────────────────
const PY_DECOR_RE = /^\s*@([A-Za-z_][\w]*)\.(get|post|put|patch|delete|route|websocket)\(\s*(['"])([^'"]*)\3([^)]*)\)/gm;
for (const f of files) {
  if (!PY_EXT.test(f.rel) || isTest(f.rel)) continue;
  const src = read(f);
  if (!src) continue;
  for (const mm of src.matchAll(PY_DECOR_RE)) {
    let methods;
    if (mm[2] === "route") {
      const ms = mm[5].match(/methods\s*=\s*[\[(]([^\])]*)[\])]/);
      methods = ms ? ms[1].split(",").map((s) => s.replace(/['"\s]/g, "").toUpperCase()).filter(Boolean) : ["GET"];
    } else if (mm[2] === "websocket") methods = ["WS"];
    else methods = [mm[2].toUpperCase()];
    routes.push({ url: mm[4], methods, file: f.rel, kind: "python-decorator" });
  }
  if (/(?:^|\/)urls\.py$/.test(f.rel)) {
    for (const mm of src.matchAll(/\b(?:re_)?path\(\s*r?(['"])([^'"]*)\1/g))
      routes.push({ url: "/" + mm[2], methods: [], file: f.rel, kind: "django-urls" });
  }
}

// ── Migrations ────────────────────────────────────────────────────────────────
const migrations = [];
for (const f of files) {
  if (!/(?:^|\/)migrations\//.test(f.rel)) continue;
  if (!/\.(?:sql|py|[cm]?[jt]s|rb|php)$/.test(f.rel)) continue;
  if (/__init__\.py$|migration_lock/.test(f.rel)) continue;
  let desc = "";
  if (/\.sql$/.test(f.rel) && f.size <= MAX_FILE_BYTES) {
    const first = read(f).split("\n").slice(0, 8).find((l) => /^\s*--\s*\S/.test(l));
    if (first) desc = first.replace(/^\s*--\s*/, "").trim().slice(0, 140);
  }
  migrations.push({ file: f.rel, desc });
}

// ── Module exports ────────────────────────────────────────────────────────
const exportsIdx = []; // {file, items: string[]}
const JS_EXPORT_RES = [
  [/^export\s+(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)/gm, "fn"],
  [/^export\s+(?:declare\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)/gm, "const"],
  [/^export\s+(?:default\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)/gm, "class"],
  [/^export\s+(?:declare\s+)?type\s+([A-Za-z_$][\w$]*)/gm, "type"],
  [/^export\s+(?:declare\s+)?interface\s+([A-Za-z_$][\w$]*)/gm, "interface"],
  [/^export\s+(?:declare\s+)?(?:const\s+)?enum\s+([A-Za-z_$][\w$]*)/gm, "enum"],
];
const MAX_ITEMS_PER_FILE = 40;
for (const f of files) {
  if (isTest(f.rel) || /\.d\.ts$/.test(f.rel)) continue;
  const isJs = JS_EXT.test(f.rel);
  const isPy = PY_EXT.test(f.rel);
  if (!isJs && !isPy) continue;
  const src = read(f);
  if (!src) continue;
  const items = [];
  const seen = new Set();
  const add = (kind, name) => {
    const k = kind + " " + name;
    if (!seen.has(k)) { seen.add(k); items.push(k); }
  };
  if (isJs) {
    for (const [re, kind] of JS_EXPORT_RES) for (const mm of src.matchAll(re)) add(kind, mm[1]);
    if (/^export\s+default\b/m.test(src) && !items.some((x) => /^(?:fn|class) /.test(x) && /export\s+default/.test(src))) add("default", "");
    for (const mm of src.matchAll(/^export\s*(?:type\s*)?\{([^}]*)\}/gm))
      for (const n of mm[1].split(",")) {
        const nm = n.trim().split(/\s+as\s+/).pop().trim();
        if (nm && /^[A-Za-z_$][\w$]*$/.test(nm)) add("re", nm);
      }
    // CommonJS
    for (const mm of src.matchAll(/^module\.exports\s*=\s*\{([^}]*)\}/gm))
      for (const n of mm[1].split(",")) {
        const nm = n.trim().split(/[:\s(]/)[0];
        if (nm && /^[A-Za-z_$][\w$]*$/.test(nm)) add("cjs", nm);
      }
    for (const mm of src.matchAll(/^(?:module\.)?exports\.([A-Za-z_$][\w$]*)\s*=/gm)) add("cjs", mm[1]);
  } else {
    for (const mm of src.matchAll(/^(?:async\s+)?def\s+([A-Za-z_]\w*)/gm)) if (!mm[1].startsWith("_")) add("def", mm[1]);
    for (const mm of src.matchAll(/^class\s+([A-Za-z_]\w*)/gm)) if (!mm[1].startsWith("_")) add("class", mm[1]);
  }
  if (items.length) exportsIdx.push({ file: f.rel, items });
}

// ── Output ───────────────────────────────────────────────────────────────────
fs.mkdirSync(OUT_DIR, { recursive: true });
const write = (name, text) => fs.writeFileSync(path.join(OUT_DIR, name), text.endsWith("\n") ? text : text + "\n");
const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

// routes.md
routes.sort((a, b) => cmp(a.url, b.url) || cmp(a.file, b.file) || cmp(a.methods.join(), b.methods.join()));
{
  const byKind = {};
  for (const r of routes) byKind[r.kind] = (byKind[r.kind] || 0) + 1;
  let t = `# HTTP entry points (${routes.length})\n\nAuto-generated by gen-codemap.mjs. Kinds: ${Object.entries(byKind).map(([k, v]) => `${k}=${v}`).join(", ") || "—"}.\n\n| URL | Methods | Kind | File |\n|---|---|---|---|\n`;
  for (const r of routes) t += `| \`${r.url}\` | ${r.methods.join(", ") || "—"} | ${r.kind} | \`${r.file}\` |\n`;
  if (!routes.length) t += "\n_None found._\n";
  write("routes.md", t);
}
// pages.md
pages.sort((a, b) => cmp(a.url, b.url) || cmp(a.file, b.file));
{
  let t = `# Pages (${pages.length})\n\nAuto-generated by gen-codemap.mjs (Next.js app/pages router).\n\n| URL | File |\n|---|---|\n`;
  for (const p of pages) t += `| \`${p.url}\` | \`${p.file}\` |\n`;
  if (!pages.length) t += "\n_None found (the project is not on Next.js, or has no pages)._\n";
  write("pages.md", t);
}
// exports.md
exportsIdx.sort((a, b) => cmp(a.file, b.file));
{
  const total = exportsIdx.reduce((s, e) => s + e.items.length, 0);
  let t = `# Module exports (${exportsIdx.length} files, ${total} names)\n\nAuto-generated by gen-codemap.mjs. Format: \`file\` — kind name, … (fn/const/class/type/interface/enum, re = re-export, cjs = module.exports, def/class for Python).\n\n`;
  for (const e of exportsIdx) {
    const shown = e.items.slice(0, MAX_ITEMS_PER_FILE).map((x) => x.trim()).join(", ");
    t += `- \`${e.file}\` — ${shown}${e.items.length > MAX_ITEMS_PER_FILE ? ` … (+${e.items.length - MAX_ITEMS_PER_FILE})` : ""}\n`;
  }
  write("exports.md", t);
}
// migrations.md
migrations.sort((a, b) => cmp(a.file, b.file));
{
  let t = `# Migrations (${migrations.length})\n\nAuto-generated by gen-codemap.mjs. \`migrations/\` directories.\n\n`;
  for (const m of migrations) t += `- \`${m.file}\`${m.desc ? ` — ${m.desc}` : ""}\n`;
  if (!migrations.length) t += "_None found._\n";
  write("migrations.md", t);
}
// INDEX.md
{
  const top = new Map(); // name -> {count, sub: Map}
  let rootFiles = 0;
  for (const f of files) {
    const segs = f.rel.split("/");
    if (segs.length === 1) { rootFiles++; continue; }
    const t = top.get(segs[0]) || { count: 0, sub: new Map() };
    t.count++;
    if (segs.length > 2) t.sub.set(segs[1], (t.sub.get(segs[1]) || 0) + 1);
    top.set(segs[0], t);
  }
  const rel = (p) => path.relative(ROOT, p).split(path.sep).join("/") || ".";
  let t = `# Code index\n\nRoot: \`${path.basename(ROOT)}\` · files: ${files.length} · generator: gen-codemap.mjs (architecture-map skill)\n\n`;
  t += `## Reference\n- [routes.md](routes.md) — HTTP entry points: ${routes.length}\n- [pages.md](pages.md) — pages: ${pages.length}\n- [exports.md](exports.md) — modules with exports: ${exportsIdx.length}\n- [migrations.md](migrations.md) — migrations: ${migrations.length}\n- [ARCHITECTURE.md](ARCHITECTURE.md) — narrative: domains, hubs (written by Claude, not the generator)\n\n`;
  t += `## Top-level tree\n\n| Directory | Files | Large subdirectories |\n|---|---|---|\n`;
  t += `| \`.\` (root) | ${rootFiles} | |\n`;
  for (const [name, v] of [...top.entries()].sort((a, b) => cmp(a[0], b[0]))) {
    const subs = [...v.sub.entries()].filter(([, c]) => c >= 10).sort((a, b) => b[1] - a[1] || cmp(a[0], b[0])).slice(0, 8)
      .map(([n, c]) => `${n} (${c})`).join(", ");
    t += `| \`${name}/\` | ${v.count} | ${subs} |\n`;
  }
  write("INDEX.md", t);
  console.log(`codemap → ${rel(OUT_DIR) === "." ? OUT_DIR : OUT_DIR}`);
}
console.log(`files: ${files.length} · routes: ${routes.length} · pages: ${pages.length} · modules with exports: ${exportsIdx.length} (names: ${exportsIdx.reduce((s, e) => s + e.items.length, 0)}) · migrations: ${migrations.length}`);
