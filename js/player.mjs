// The browser scenario player — the same steps.json vocabulary as the native
// player (see ../STEPS.md), interpreted over the playwright LIBRARY API (no
// test-runner framework: scenarios are data).
//
// The suite supplies an `app.mjs` module (see run.mjs) that owns everything
// app-specific: launch/auth/backend setup, the id→locator map, `app:` verbs,
// and the pre-shot freeze. Core verbs live here and are fixed — a missing
// generic capability is a change to this repo, not a suite-local fork.
//
// Browser-only extensions (documented here, ignored by the lint):
//   - shot steps may carry `of: "<id>"` — capture just that element's region.
//   - steps may carry `actor: "<name>"` — multi-user scenarios: a `launch`
//     with an actor opens that user's own browser context; later steps with
//     the same actor drive that user's page. Steps without an actor drive the
//     most recent launch.
"use strict";

import { mkdirSync, writeFileSync, copyFileSync, rmSync } from "node:fs";
import { join } from "node:path";

export const CORE_VERBS = new Set([
  "launch", "tap", "longPress", "type", "waitFor", "waitGone",
  "assertEnabled", "assertDisabled", "drag", "dragReorder", "scrollTo", "shot",
]);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export class ScenarioContext {
  constructor({ browser, app, scenario, shotsDir, timeout = 20000, log = console.log }) {
    this.browser = browser;
    this.app = app;
    this.scenario = scenario;
    this.shotsDir = shotsDir;
    this.timeout = timeout;
    this.log = log;
    this.pages = new Map();   // actor -> page
    this.contexts = [];       // every context opened (closed by run.mjs)
    this.page = null;         // the active (last-launched / step-addressed) page
    this.errors = [];         // failure-guard collection across all pages
  }

  /// Resolve a step's page: its `actor`'s page, else the active one.
  pageFor(step) {
    if (step.actor) {
      const p = this.pages.get(step.actor);
      if (!p) throw new Error(`step ${step.ordinal}: no launch for actor "${step.actor}"`);
      return p;
    }
    if (!this.page) throw new Error(`step ${step.ordinal} (\`${step.do}\`) before any \`launch\``);
    return this.page;
  }

  /// Open a fresh context+page (one per launch actor). The app's `browser`
  /// export supplies contextOptions; failure guards attach automatically.
  async newPage(step) {
    const opts = (this.app.browser && this.app.browser.contextOptions) || {};
    const context = await this.browser.newContext(opts);
    this.contexts.push(context);
    const page = await context.newPage();
    attachFailureGuards(page, this.errors, this.app.guardIgnore || []);
    this.pages.set(step.actor || "default", page);
    this.page = page;
    return page;
  }

  /// Shared selector resolution: suite override first (the id→CSS map lives
  /// there), then data-testid / #id, label (exact), contains, placeholder.
  locator(step) {
    const page = this.pageFor(step);
    if (this.app.locator) {
      const l = this.app.locator(page, step);
      if (l) return l;
    }
    if (step.id) return page.locator(`[data-testid="${step.id}"], #${step.id.replace(/([^\w-])/g, "\\$1")}`).first();
    if (step.label) return page.getByText(step.label, { exact: true }).first();
    if (step.contains) return page.getByText(step.contains).first();
    if (step.placeholderPrefix) return page.locator(`[placeholder^="${step.placeholderPrefix}"]`).first();
    return null;
  }

  required(step, what) {
    const l = this.locator(step);
    if (!l) throw new Error(`step ${step.ordinal}: ${what} has no selector (id/label/contains/placeholderPrefix)`);
    return l;
  }

  /// Poll `fn` until truthy (returned) or timeout (throws `message`).
  async poll(fn, { timeout = this.timeout, interval = 400, message = "poll timed out" } = {}) {
    const deadline = Date.now() + timeout;
    for (;;) {
      const v = await fn();
      if (v) return v;
      if (Date.now() > deadline) throw new Error(message);
      await sleep(interval);
    }
  }

  /// Capture a shot: full page, or `of` region. Freezes volatile UI via the
  /// suite hook first. Hero also lands as shots/main.png.
  async capture(step, label, { hero = false } = {}) {
    const page = this.pageFor(step);
    if (this.app.beforeShot) await this.app.beforeShot(page);
    mkdirSync(this.shotsDir, { recursive: true });
    const path = join(this.shotsDir, `${this.scenario}-${label}.png`);
    if (step && step.of) {
      const region = this.locator({ ...step, id: step.of, label: undefined, contains: undefined, ordinal: step.ordinal });
      await region.screenshot({ path, animations: "disabled" });
    } else {
      await page.screenshot({ path, animations: "disabled" });
    }
    if (hero) copyFileSync(path, join(this.shotsDir, "main.png"));
    this.log(`  shot ${this.scenario}-${label}.png${hero ? " (hero → main.png)" : ""}`);
  }

  /// Assert the failure guards collected nothing (called at scenario end).
  checkErrors() {
    if (this.errors.length) {
      throw new Error("page errors:\n  " + this.errors.join("\n  "));
    }
  }
}

// Console-error / pageerror / requestfailed / 4xx-5xx guards, collected into
// `sink`; `ignore` is a list of RegExps matched against the offending URL.
export function attachFailureGuards(page, sink, ignore = []) {
  const ignored = (url) => url.endsWith("/favicon.ico") || ignore.some((re) => re.test(url));
  page.on("console", (msg) => {
    if (msg.type() === "error" && !ignored(msg.location().url || "")) {
      sink.push("console.error: " + msg.text());
    }
  });
  page.on("pageerror", (err) => sink.push("pageerror: " + (err && err.message ? err.message : err)));
  page.on("requestfailed", (req) => {
    if (!ignored(req.url())) sink.push("requestfailed: " + req.url() + " — " + (req.failure() && req.failure().errorText));
  });
  page.on("response", (res) => {
    if (res.status() >= 400 && !ignored(res.url())) sink.push("response " + res.status() + ": " + res.url());
  });
}

/// Interpret one scenario plan. Throws on the first failed step.
export async function playScenario(plan, ctx) {
  const steps = plan.steps.map((s, i) => ({ ...s, ordinal: i + 1 }));
  for (const step of steps) {
    await perform(step, ctx);
    const label = step.do === "shot" ? step.as : step.shot;
    if (label) await ctx.capture(step, label, { hero: step.hero === true });
  }
  ctx.checkErrors();
}

async function perform(step, ctx) {
  const t = step.timeout || ctx.timeout;

  if (step.do.startsWith("app:")) {
    const name = step.do.slice(4);
    const verb = ctx.app.verbs && ctx.app.verbs[name];
    if (!verb) throw new Error(`step ${step.ordinal}: unregistered app verb \`${step.do}\``);
    // A backend-only verb may legitimately run before any launch → null page.
    const page = (step.actor || ctx.page) ? ctx.pageFor(step) : null;
    await verb(page, step, ctx);
    return;
  }

  switch (step.do) {
    case "launch": {
      const page = await ctx.newPage(step);
      if (!ctx.app.launch) throw new Error("the suite's app.mjs must export launch(page, step, ctx)");
      await ctx.app.launch(page, step, ctx);
      break;
    }
    case "tap":
      await ctx.required(step, "tap target").click({ timeout: t });
      break;
    case "longPress":
      await ctx.required(step, "longPress target").click({ delay: 800, timeout: t });
      break;
    case "type": {
      if (typeof step.text !== "string") throw new Error(`step ${step.ordinal}: \`type\` requires \`text\``);
      await ctx.required(step, "type target").fill(step.text, { timeout: t });
      break;
    }
    case "waitFor":
      await ctx.required(step, "waitFor target").waitFor({ state: "visible", timeout: t });
      break;
    case "waitGone":
      await ctx.required(step, "waitGone target").waitFor({ state: "hidden", timeout: t });
      break;
    case "assertEnabled":
    case "assertDisabled": {
      const want = step.do === "assertEnabled";
      const el = ctx.required(step, "assert target");
      await el.waitFor({ state: "visible", timeout: t });
      await ctx.poll(async () => (await el.isEnabled()) === want, {
        timeout: t, message: `step ${step.ordinal}: ${step.do}: expected enabled=${want}`,
      });
      break;
    }
    case "drag": {
      if (!step.fromId || !step.toId) throw new Error(`step ${step.ordinal}: \`drag\` requires \`fromId\`/\`toId\``);
      const from = ctx.locator({ ...step, id: step.fromId });
      const to = ctx.locator({ ...step, id: step.toId });
      await from.dragTo(to, { timeout: t });
      break;
    }
    case "dragReorder":
      throw new Error(`step ${step.ordinal}: \`dragReorder\` has no generic browser mapping — register an app: verb`);
    case "scrollTo":
      await ctx.required(step, "scrollTo target").scrollIntoViewIfNeeded({ timeout: t });
      break;
    case "shot":
      if (typeof step.as !== "string") throw new Error(`step ${step.ordinal}: standalone \`shot\` requires \`as\``);
      break; // captured by the shared post-step hook
    default:
      throw new Error(`step ${step.ordinal}: unknown verb \`${step.do}\``);
  }
}
