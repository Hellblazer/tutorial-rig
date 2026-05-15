#!/usr/bin/env node
// Minimal companion-pane fixture: print the inherited JOB_ID, "do work",
// print completion. Exits cleanly so the companion pane dies and the
// watcher can terminate the recording.

const jobId = process.env.JOB_ID || "<unset>";
console.log(`[observer] watching JOB_ID=${jobId}`);

await new Promise((r) => setTimeout(r, 2000));
console.log(`[observer] tick 1 for ${jobId}`);

await new Promise((r) => setTimeout(r, 2000));
console.log(`[observer] tick 2 for ${jobId}`);

await new Promise((r) => setTimeout(r, 2000));
console.log(`[observer] job complete: ${jobId}`);

process.exit(0);
