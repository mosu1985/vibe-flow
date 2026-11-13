---
name: smoke-ui
description: Smoke check of a web app via Claude in Chrome — open sections under the user's live session, collect console errors and 4xx/5xx requests, return a report. Use after a deploy, after UI/API changes, on a complaint like "this section doesn't work", or on the command "run the smoke test". Works on localhost, a preview deploy and prod.
user-invocable: true
---

# UI smoke check (Claude in Chrome)

A pass through the web app's sections in the user's **live Chrome** with their session: the page opened → the console is clean → the network has no 4xx/5xx.

## ⚠️ This is a skill, not a script

Claude in Chrome is MCP tools, not a CLI. Running it from cron or CI is impossible: the agent performs the procedure. In exchange you get the user's live session (httpOnly auth cookies, which cannot be moved into a headless browser).

The extension is **optional**. No connection (`Browser extension is not connected`) or no `mcp__claude-in-chrome__*` tools → honestly return "unavailable: the Claude in Chrome extension is not connected — install/enable: https://claude.ai/chrome". Do not substitute the smoke test with `curl` and do not pass it off as a UI run.

## Parameters

| What | Where from |
|---|---|
| Worktree | the line `Worktree: <absolute path>` from the assignment; none — `git worktree list`: one tree → the current directory, more than one → don't guess, ask (or return "⏸️ specify the worktree: <list>" if you are a subagent). `cd` does not persist between Bash calls — commands as `cd "<worktree>" && …` |
| Base (URL) | from the user; otherwise **the dev of the tree being checked**: the port of its dev server — `cd "<worktree>" && lsof -nP -a -p "$(cat .wt-dev.pid)" -iTCP -sTCP:LISTEN` (a child process may be the one listening — check `pgrep -P <pid>` too; each worktree has its own dev on its own port); no `.wt-dev.pid` — the dev address from the `## 🧩 Project` section of `CLAUDE.md` (between the `<!-- vibe-flow:project:begin -->` / `<!-- vibe-flow:project:end -->` markers; older installs title it `## 🧩 Проект`) / `GG_DEV_CMD` in `.gitguards.conf` (the port as in the project, don't guess `3000`). 🔴 A neighbor tree's port = a smoke test of someone else's code with a false "clean" |
| Sections | from the user; otherwise **from the project** (see below); otherwise the home page + 3–5 key screens |
| Prefixes | locale/base path — as the project does it |

**Where to get the list of sections if the user didn't name any:**
1. `docs/codemap/pages.md` (if there is an index from `vibe-flow:architecture-map`) — the page routes.
2. The app's navigation: the menu/sidebar/header component, the router (`app/**/page.*`, `pages/`, `routes.*`, `urls.py`, templates).
3. Propose a short list to the user (5–8 sections: login, home, the 2–3 most important, the recently changed one) and **start with those changed in the current branch**: `cd "<worktree>" && git diff --name-only <prod-branch>...HEAD`, where the prod branch is `origin/HEAD` → `main` → `master` (the `base:` line of `scripts/release-gate.sh scope`), not the tree's `.gitguards.conf`.

Skip parameterized pages (`/orders/[id]`) or take a real id from the data — do not make one up.

---

## Step 0. Prepare Chrome

1. Load the tools with **one** `ToolSearch`:
   ```
   select:mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__get_page_text,mcp__claude-in-chrome__read_console_messages,mcp__claude-in-chrome__read_network_requests,mcp__claude-in-chrome__browser_batch,mcp__claude-in-chrome__computer,mcp__claude-in-chrome__list_connected_browsers,mcp__claude-in-chrome__select_browser,mcp__claude-in-chrome__tabs_close_mcp
   ```
2. `list_connected_browsers`. **More than one** browser → `AskUserQuestion` with ALL the options (you must not choose for the user), then `select_browser` with the chosen `deviceId`. Just one — use it.
3. `tabs_context_mcp{createIfEmpty:true}` → remember the `tabId`.

🔴 **The tab group opens in a SEPARATE Chrome window** — it may be behind the current one.

🔴 **Different Chrome browsers/profiles — different cookies.** Connect to the wrong one and you get a 401 and a redirect to login while the user, on the same URL, sees their data. Before the run, open the target URL: thrown to login → you are in someone else's profile, switch (`AskUserQuestion` → `select_browser`), do NOT ask to sign in again. Any 4xx/5xx from an unauthenticated profile **does not count as a finding**: before reporting a defect, make sure the session existed.

🔴 **Changing the extension's permissions reloads it and kills the tab group** — `tabId`s go stale (`Tab … no longer exists`), recreate via `tabs_context_mcp{createIfEmpty:true}`.

🔴 **The extension needs site permissions.** Without them the page comes up as an error page and the tools answer `Frame with ID 0 is showing error page` — while `curl` returns 200. The user fixes it: `chrome://extensions` → Claude → Details → Site access → On all sites. Don't work around it yourself, return the instruction.

---

## Step 1. Prime the diagnostics

🔴 **The main gotcha.** `read_console_messages` and `read_network_requests` start tracking **from the moment of the first call**. Call them after the page has loaded and they return empty, and you report a false "clean" while 500s are live.

The order is always: **prime → navigate → read.** Priming does not work on `chrome://newtab` (`Can't interact with browser-internal or unparseable URLs`), and a fresh tab is always there, so: `navigate` to the target URL → prime → `navigate` to the same URL → `wait` → read.

```
browser_batch([
  navigate {tabId, url: <first section>},                   // leave chrome://newtab
  read_console_messages {tabId, clear:true, pattern:"."},   // priming
  read_network_requests {tabId, clear:true},                // priming
  navigate {tabId, url: <same URL>},                        // reload under recording
  computer {action:"wait", duration:5},
  get_page_text {tabId},
  read_console_messages {tabId, onlyErrors:true, clear:true},
  read_network_requests {tabId, clear:true, limit:200},
])
```

`clear:true` on every read is mandatory: the buffer is cumulative, otherwise the first section's requests resurface in all the following ones and get counted again. Set the network filter (`urlPattern`) by this project's API prefix (`/api/`, `/graphql` …) if you only need its requests.

---

## Step 2. Check authorization

Open the main protected section and look at the final URL:

- redirect to the login page:
  - the form is already **filled in by the password manager** → click "Sign in" and continue;
  - the fields are empty → **do NOT type the password** (except a dev-environment test account, if the user explicitly gave it to you). Return: "sign in to `<base>` in a regular window of this same Chrome profile — cookies are shared, my tab will pick up the session"
- stayed in the section → there is a session, continue

The page may show `Loading…` — wait 4–5 s and re-read.

---

## Step 3. Walk the sections

For each section, one `browser_batch`: `navigate` → `wait 5` → `get_page_text` (or the first lines) → `read_console_messages{onlyErrors:true, clear:true}` → `read_network_requests{clear:true}`. Two or three sections can be merged into one batch — the reads in between separate the samples.

A section showed 4xx/5xx → compare with `get_page_text`: **what the user sees when a request fails**. A mismatch between the API's refusal and what is drawn on screen ("empty" instead of "no access/error") is a defect in its own right.

---

## Step 4. Filter the noise

Do not count as a defect:
- **Duplicate requests in dev** — the framework's development mode renders twice (React StrictMode etc.). On prod, duplicates are a finding
- **A 401 on the session check (`/me`, `/session`) on the login page** for an unauthenticated user — normal
- Console `log`/`info`/`debug` messages — only `error` and unhandled exceptions go into the report
- `statusCode: pending` — the request had not finished
- Requests to third-party trackers/analytics blocked by extensions

A defect is everything else: 4xx, 5xx, console errors, timeouts, endless spinners.

---

## Step 5. Clean up

`tabs_close_mcp` — only your own tab. Don't touch others.

---

## Report format

```
✅ / ⚠️ / ❌ <one-line summary>
Base: <URL> · profile/browser: <which> · session: yes/no

🔎 Sections
- /path — "<title>" · console N · network 4xx/5xx: M
- ...

🐞 Findings
- <section>: <method> <url> → <code>, <how many times>, recovered or not
  What the user sees: <from get_page_text>

✔️ Clean
- <sections with no findings>

📌 Conclusion
<1–3 sentences: what to fix and how urgently>
```

Do not print secrets: mask tokens, cookies and passwords even if they ended up in a URL or a request body.

## Related

- Standalone browser tasks outside a smoke test — the `vibe-flow:browser-operator` agent
- Server logs on a 5xx — the project's hosting logs
