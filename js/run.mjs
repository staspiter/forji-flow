#!/usr/bin/env node
// CLI runner for browser scenario suites.
//
//   node run.mjs --suite <dir> [--shots-dir <dir>] [scenario...]
//
// The suite dir holds <scenario>.steps.json files and an app.mjs (default
// export) with the app-specific half:
//
//   export default {
//     browser: { launchOptions: {...}, contextOptions: {...} },  // optional
//     guardIgnore: [/gameshost/],                    // failure-guard URL skips
//     async launch(page, step, ctx) {},              // REQUIRED: navigate+auth
//     locator(page, step) {},                        // optional id→locator map
//     verbs: { name: async (page, step, ctx) => {} },// app: verbs
//     async beforeShot(page) {},                     // freeze volatile UI
//   }
//
// Playwright is resolved from the CONSUMING project (NODE_PATH or the suite's
// own node_modules) — this repo installs nothing.
"use strict";

import { readdirSync, readFileSync, mkdirSync, rmSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { createRequire } from "node:module";
import { ScenarioContext, playScenario } from "./player.mjs";

const argv = process.argv.slice(2);
let suiteDir = null, shotsDir = null;
const picked = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--suite") suiteDir = resolve(argv[++i]);
  else if (argv[i] === "--shots-dir") shotsDir = resolve(argv[++i]);
  else picked.push(argv[i]);
}
if (!suiteDir) {
  console.error("usage: node run.mjs --suite <dir> [--shots-dir <dir>] [scenario...]");
  process.exit(1);
}
shotsDir = shotsDir || join(suiteDir, "shots");

const app = (await import(pathToFileURL(join(suiteDir, "app.mjs")).href)).default;
if (!app || typeof app.launch !== "function") {
  console.error(`suite ${suiteDir}: app.mjs must default-export { launch(page, step, ctx), ... }`);
  process.exit(1);
}

// Resolve playwright from the suite's world (its node_modules or NODE_PATH).
const requireFromSuite = createRequire(join(suiteDir, "app.mjs"));
let chromium;
try {
  ({ chromium } = requireFromSuite("playwright"));
} catch {
  ({ chromium } = requireFromSuite("@playwright/test"));
}

const all = readdirSync(suiteDir).filter((f) => f.endsWith(".steps.json")).sort()
  .map((f) => basename(f, ".steps.json"));
const scenarios = picked.length ? picked : all;
const missing = scenarios.filter((s) => !all.includes(s));
if (missing.length) {
  console.error(`no such scenario(s): ${missing.join(", ")} (have: ${all.join(", ")})`);
  process.exit(1);
}

const browser = await chromium.launch({
  headless: true,
  ...((app.browser && app.browser.launchOptions) || {}),
});

let failed = 0;
for (const name of scenarios) {
  const plan = JSON.parse(readFileSync(join(suiteDir, `${name}.steps.json`), "utf8"));
  console.log(`==> scenario: ${name}`);
  // Clean this scenario's stale shots — labels are NN-… so `-[0-9]` scopes the
  // cleanup and never touches another scenario sharing the prefix.
  mkdirSync(shotsDir, { recursive: true });
  for (const f of readdirSync(shotsDir)) {
    if (new RegExp(`^${name}-\\d`).test(f)) rmSync(join(shotsDir, f));
  }
  const ctx = new ScenarioContext({ browser, app, scenario: name, shotsDir });
  try {
    await playScenario(plan, ctx);
    console.log(`    PASS`);
  } catch (e) {
    failed++;
    console.error(`    FAIL  ${e && e.message ? e.message : e}`);
    try {
      if (ctx.page) {
        mkdirSync(join(suiteDir, "out"), { recursive: true });
        await ctx.page.screenshot({ path: join(suiteDir, "out", `${name}-failure.png`) });
        console.error(`          failure shot: out/${name}-failure.png`);
      }
    } catch { /* the page may be gone */ }
  } finally {
    for (const c of ctx.contexts) await c.close().catch(() => {});
  }
}

await browser.close();
process.exit(failed ? 1 : 0);
