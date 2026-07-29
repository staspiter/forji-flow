#!/usr/bin/env node
// Lint self-test: the good fixture must pass, the bad fixture must fail with
// every planted violation reported. This is the repo's own verify gate.

import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const lint = join(here, "lint-steps.mjs");

function run(target) {
  try {
    const out = execFileSync(process.execPath, [lint, target], { encoding: "utf8", stdio: "pipe" });
    return { code: 0, out };
  } catch (e) {
    return { code: e.status ?? 1, out: `${e.stdout ?? ""}${e.stderr ?? ""}` };
  }
}

let failures = 0;
const check = (name, ok, detail) => {
  if (ok) { console.log(`✓ ${name}`); } else { failures++; console.error(`✗ ${name}\n${detail}`); }
};

const good = run(join(here, "fixtures/good"));
check("good fixture passes", good.code === 0, good.out);

const bad = run(join(here, "fixtures/bad"));
check("bad fixture fails", bad.code === 1, bad.out);
for (const planted of [
  "does not match filename",
  "more than one selector",
  "unknown verb `typo`",
  "requires a string `text`",
  "standalone `shot` requires `as`",
  "must be NN-label",
  "duplicate shot label",
  "`poster` without a shot label",
  "core verb `tap` before any `launch`",
]) {
  check(`bad fixture reports: ${planted}`, bad.out.includes(planted), bad.out);
}

if (failures > 0) {
  console.error(`self-test: ${failures} failure(s)`);
  process.exit(1);
}
console.log("self-test: OK");
