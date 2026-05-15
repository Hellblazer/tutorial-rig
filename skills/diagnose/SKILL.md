---
name: diagnose
description: Diagnose a failed recording-rig run. Use when the user reports a recording failed, the validator said FAILED, the rig hung, the cast looks wrong, or invokes `/recording-rig:diagnose`. Examines the cast, sentinels under /tmp/${SESSION}.*, rendered hooks file, and rig output to identify the failure mode and propose a fix.
---

# diagnose

Identify why a recording failed and propose a specific fix. This is targeted forensics on a known-bad run — not a general "review my spec" tool.

## When to use

- Validator reported FAILED (missing `must_contain` or present `must_not_contain`)
- Rig hung > 3 minutes with no `agent-done` sentinel
- `[validate] PASSED` but the rendered GIF is empty or wrong
- User says "the recording broke" / "my rig output is weird"

## Inputs to gather

Ask the user for (or derive from context):
- Session name (or cast path → derive `${SESSION}` from filename)
- Path to the spec JSON that was used

Then read:
- `/tmp/${SESSION}.cast` — the recording itself
- `/tmp/${SESSION}.hooks.json` — what hooks were installed
- `/tmp/${SESSION}.*` — all sentinels (which fired, mtimes, contents)
- Spec file — what was supposed to happen

## Failure-mode taxonomy

Walk this list. The first match is usually the answer.

### "FAILED: missing required" — `must_contain` not satisfied

1. Run `node` on the cast to extract the stripped output (use the cleanCast function from `bin/validate.mjs`). Check whether the missing string appears at all (could be a typo) or appears in modified form (ANSI/cursor-overwrite mangling).
2. Check whether the missing string is *only in the prompt echo*. If the agent's reply didn't actually contain it, that's a model behaviour issue — adjust the prompt.
3. If the assertion is uniquely an agent-output string (e.g. `RESULT=42`) and absent: did the agent's turn complete? Check for `turn-end` sentinel mtime versus the cast end-time.

### "FAILED: forbidden present" — `must_not_contain` matched

1. Likely `step_aborted` / `failure_reason` from claude — the agent crashed mid-turn. Inspect the cast for the surrounding context.
2. Could be cursor-overwrite ghost text (the validator strips ANSI but doesn't replay cursor positioning). Document the limitation; if real, switch the assertion to `must_contain_in_order` with a uniquely-emitted positive marker.

### Rig hung; `session-start` sentinel never fired

The consent dialogs blocked claude from starting hooks. The consent-sweep should have caught them, but:
1. Check if a NEW consent dialog text appeared (claude updates) — the sweep's regex may be stale.
2. Check if `--dangerously-skip-permissions` was actually set (`agent.bypass_permissions: true` in spec).
3. The user may need to run `claude --dangerously-skip-permissions` interactively once to accept the legal consent globally.

### Rig hung; `session-start` fired but no `prompt-submitted`

The driver pasted but claude didn't ingest it. Common causes:
1. `agent.cwd` requires a trust dialog the sweep didn't dismiss. Check `tmux capture-pane -t ${SESSION}` if the session is still alive.
2. `ATTACH_GAP_SEC` too short — driver pasted before asciinema attached. Bump `pacing.attach_gap_sec` to 8-10.
3. `pre_enter_sec: 0` was specified for a gate — keys lost. The driver now floors at 1, but check the rig version.

### Rig hung; `prompt-submitted` fired but no `turn-end`

The agent is stuck mid-turn. Causes:
1. The model is slow (sonnet on a heavy reasoning prompt) — bump `pacing.turn_timeout_sec`.
2. The `Stop` hook command in the rendered hooks.json failed (rare — it's a trivial `touch`).
3. The agent called `AskUserQuestion` but the spec didn't list it as a gate — the agent is waiting forever. Add a gate entry to the spec.

### Companion never produced output (two-pane)

1. Read `/tmp/${SESSION}.companion-env` — is it well-formed bash? If line concatenation is visible (e.g. `export XYexec ...`), there's a rig bug; report it.
2. Did the `PostToolUse` hook fire? Check sentinel existence + content. Empty file = jq failed to extract the payload.
3. The `tool_response` shape may not match the hook's unwrap pattern. Test the jq manually against a captured tool_response sample.

### `must_contain_in_order` failed at an unexpected position

The cleaned cast probably has the strings, but in a different order. Cursor-overwrite or claude printing summaries can reorder visible text. Switch to plain `must_contain` if order is incidental.

## Reporting

For each diagnosed failure, state:
1. **Symptom** (what the rig produced)
2. **Root cause** (which failure mode from the taxonomy)
3. **Fix** (specific spec change, env var, or command)
4. **How to verify** (re-run command + expected new outcome)

## What this skill does NOT do

- Apply fixes automatically. Diagnosis is read-only; the user accepts the fix and re-runs.
- Diagnose architectural design choices in the spec (route to `author-spec` for redesigns).
- Recover from incomplete artifacts that are already overwritten by a new run.
