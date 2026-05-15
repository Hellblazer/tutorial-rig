#!/usr/bin/env node
// Validate an asciinema cast against required positive signals and forbidden markers.
// Usage: validate.mjs <spec.json> <cast.cast>
// Exit 0 on pass, non-zero on fail. SKIP_VALIDATE=1 forces pass.

import { readFileSync } from "node:fs";

const [, , specPath, castPath] = process.argv;
if (!specPath || !castPath) {
  console.error("usage: validate.mjs <spec.json> <cast.cast>");
  process.exit(2);
}

if (process.env.SKIP_VALIDATE === "1") {
  console.log("[validate] SKIP_VALIDATE=1, skipping");
  process.exit(0);
}

const spec = JSON.parse(readFileSync(specPath, "utf8"));
const must = spec.validate?.must_contain ?? [];
const mustNot = spec.validate?.must_not_contain ?? [
  "step_aborted",
  "failure_reason",
];

// Asciinema cast v2: first line is a JSON header, remaining lines are JSON arrays
// [time, "o", "output text"]. We concatenate all "o" text.
const raw = readFileSync(castPath, "utf8").split(/\r?\n/);
let output = "";
for (let i = 1; i < raw.length; i++) {
  const line = raw[i].trim();
  if (!line) continue;
  try {
    const ev = JSON.parse(line);
    if (Array.isArray(ev) && ev[1] === "o") output += ev[2];
  } catch {
    /* tolerate malformed trailing lines */
  }
}

const missing = must.filter((s) => !output.includes(s));
const present = mustNot.filter((s) => output.includes(s));

if (missing.length || present.length) {
  console.error("[validate] FAILED");
  if (missing.length) console.error("  missing required:", missing);
  if (present.length) console.error("  forbidden present:", present);
  process.exit(1);
}

console.log("[validate] PASSED");
