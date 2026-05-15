#!/usr/bin/env node
// Validate an asciinema cast against required positive signals and forbidden
// markers. Usage: validate.mjs <spec.json> <cast.cast>
// Exit 0 on pass, non-zero on fail. SKIP_VALIDATE=1 forces pass.
//
// Modes (under spec.validate):
//   must_contain:           array of strings, set membership (any order)
//   must_contain_in_order:  array of strings, must appear in given order
//   must_not_contain:       array of strings, none may appear

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
const mustInOrder = spec.validate?.must_contain_in_order ?? [];
const mustNot = spec.validate?.must_not_contain ?? [
  "step_aborted",
  "failure_reason",
];

// asciinema cast v2: header line 1, remaining lines are [time,"o","text"].
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

// Strip ANSI/CSI/OSC escapes, then APPLY backspaces (they delete the
// preceding character — without this, "ERROR<BS><BS><BS><BS><BS>CLEAR"
// would leave "ERROR" present and false-fail must_not_contain).
// Pragmatic, not a full emulator: handles colours, cursor positioning,
// alternate-screen toggles, CRs, BS char-deletion. Does NOT replay
// cursor movements or wraparound (documented in design.md).
function cleanCast(s) {
  const escStripped = s
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")           // CSI
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "") // OSC
    .replace(/\x1b[@-_]/g, "")                          // single-char ESC
    .replace(/\x1b./g, "")                              // any remaining ESC seq
    .replace(/\r/g, "");
  // Apply \x08 (backspace) destructively: each BS removes the preceding char.
  const out = [];
  for (const ch of escStripped) {
    if (ch === "\x08") {
      if (out.length > 0) out.pop();
    } else {
      out.push(ch);
    }
  }
  // Strip remaining low control chars (preserve \t=09 and \n=0a).
  return out.join("").replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, "");
}

const cleaned = cleanCast(output);

const missing = must.filter((s) => !cleaned.includes(s));
const present = mustNot.filter((s) => cleaned.includes(s));

let orderViolation = null;
if (mustInOrder.length > 0) {
  // Cursor semantics: each needle must START strictly after the previous
  // needle's START position. This permits overlapping needles (e.g.
  // ["ab","bc"] in "abc") while still enforcing order — needed for cases
  // where the asserted strings share a suffix/prefix.
  let cursor = 0;
  for (const needle of mustInOrder) {
    const idx = cleaned.indexOf(needle, cursor);
    if (idx === -1) {
      orderViolation = `'${needle}' missing or out of order after position ${cursor}`;
      break;
    }
    cursor = idx + 1;
  }
}

if (missing.length || present.length || orderViolation) {
  console.error("[validate] FAILED");
  if (missing.length) console.error("  missing required:", missing);
  if (present.length) console.error("  forbidden present:", present);
  if (orderViolation) console.error("  order violation:", orderViolation);
  process.exit(1);
}

console.log("[validate] PASSED");
