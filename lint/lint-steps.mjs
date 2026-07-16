#!/usr/bin/env node
// Offline schema lint for *.steps.json scenario suites — the fast `!test` gate
// every suite runs (no simulator, no browser, no dependencies).
//
//   node lint-steps.mjs <suite-dir | file.steps.json> [...more]
//
// Validates the shared vocabulary (see STEPS.md). Core verbs are checked
// strictly; `app:*` verbs pass through (they are the suite's own, registered in
// its player). Exit 0 = clean, 1 = violations.

import { readFileSync, readdirSync, statSync } from "node:fs";
import { basename, join } from "node:path";

const CORE_VERBS = new Set([
  "launch", "tap", "longPress", "type", "waitFor", "waitGone",
  "assertEnabled", "assertDisabled", "drag", "dragReorder", "scrollTo", "shot",
]);
const SELECTORS = ["id", "label", "contains", "placeholderPrefix"];
const SHOT_LABEL = /^\d{2}-[A-Za-z0-9][A-Za-z0-9-]*$/;

const args = process.argv.slice(2);
if (args.length === 0) {
  console.error("usage: node lint-steps.mjs <suite-dir | file.steps.json> [...more]");
  process.exit(1);
}

// Expand dirs to their *.steps.json.
const files = [];
for (const arg of args) {
  let st;
  try { st = statSync(arg); } catch {
    console.error(`lint: no such path: ${arg}`);
    process.exit(1);
  }
  if (st.isDirectory()) {
    const found = readdirSync(arg).filter((f) => f.endsWith(".steps.json")).sort();
    if (found.length === 0) console.error(`lint: warning: no *.steps.json in ${arg}`);
    files.push(...found.map((f) => join(arg, f)));
  } else {
    files.push(arg);
  }
}

let errors = 0;
let warnings = 0;
let heroes = 0;
const err = (file, msg) => { errors++; console.error(`✗ ${file}: ${msg}`); };
const warn = (file, msg) => { warnings++; console.error(`⚠ ${file}: ${msg}`); };

for (const file of files) {
  const name = basename(file).replace(/\.steps\.json$/, "");
  let top;
  try {
    top = JSON.parse(readFileSync(file, "utf8"));
  } catch (e) {
    err(file, `invalid JSON: ${e.message}`);
    continue;
  }

  let steps;
  if (Array.isArray(top)) {
    steps = top;
  } else if (top && typeof top === "object") {
    if (top.scenario !== undefined && top.scenario !== name) {
      err(file, `scenario "${top.scenario}" does not match filename "${name}"`);
    }
    if (!Array.isArray(top.steps)) {
      err(file, "missing `steps` array");
      continue;
    }
    steps = top.steps;
  } else {
    err(file, "top level must be an object with `steps` or a bare array");
    continue;
  }

  if (steps.length === 0) { err(file, "empty steps array"); continue; }

  const shotLabels = new Set();
  let launched = false;
  steps.forEach((step, idx) => {
    const at = `step ${idx + 1}`;
    if (!step || typeof step !== "object" || Array.isArray(step)) {
      err(file, `${at}: not a JSON object`);
      return;
    }
    const verb = step.do;
    if (typeof verb !== "string" || verb === "") {
      err(file, `${at}: missing \`do\` action`);
      return;
    }
    if (!CORE_VERBS.has(verb) && !verb.startsWith("app:")) {
      err(file, `${at}: unknown verb \`${verb}\` (core verbs are fixed; app moves use \`app:<name>\`)`);
    }
    if (verb.startsWith("app:") && verb.length === 4) {
      err(file, `${at}: empty app verb name`);
    }

    const used = SELECTORS.filter((s) => step[s] !== undefined);
    if (used.length > 1) {
      err(file, `${at}: more than one selector (${used.join(", ")}) — use exactly one`);
    }

    if (verb === "type" && typeof step.text !== "string") {
      err(file, `${at}: \`type\` requires a string \`text\``);
    }
    if (verb === "drag" && (typeof step.fromId !== "string" || typeof step.toId !== "string")) {
      err(file, `${at}: \`drag\` requires \`fromId\` and \`toId\``);
    }
    if (verb === "dragReorder" && (step.from === undefined || step.to === undefined)) {
      err(file, `${at}: \`dragReorder\` requires \`from\` and \`to\``);
    }
    if (verb === "shot" && typeof step.as !== "string") {
      err(file, `${at}: standalone \`shot\` requires \`as\``);
    }

    // `launch` must come before any core interaction verb; app:* setup steps
    // (backend seeding, resets) may legitimately precede it.
    if (verb === "launch") launched = true;
    if (!launched && CORE_VERBS.has(verb)) {
      err(file, `core verb \`${verb}\` before any \`launch\``);
    }

    const label = verb === "shot" ? step.as : step.shot;
    if (label !== undefined) {
      if (typeof label !== "string" || !SHOT_LABEL.test(label)) {
        err(file, `${at}: shot label \`${label}\` must be NN-label (e.g. "01-lobby")`);
      } else if (shotLabels.has(label)) {
        err(file, `${at}: duplicate shot label \`${label}\``);
      } else {
        shotLabels.add(label);
      }
      if (step.hero === true) heroes++;
    } else if (step.hero === true) {
      err(file, `${at}: \`hero\` without a shot label`);
    }
  });
}

if (heroes === 0 && errors === 0 && files.length > 0) {
  warn("(suite)", "no `hero` shot — no shots/main.png will be produced, the node card stays empty");
}
if (heroes > 1) {
  err("(suite)", `${heroes} hero shots — exactly one per suite designates shots/main.png`);
}

const n = files.length;
if (errors > 0) {
  console.error(`lint: ${errors} error(s), ${warnings} warning(s) across ${n} scenario file(s)`);
  process.exit(1);
}
console.log(`lint: OK — ${n} scenario file(s), ${warnings} warning(s)`);
