---
name: author-spec
description: Interactively author a recording-rig spec JSON for a new tutorial/demo/screencast. Use when the user says "write a recording spec", "I want to record X", "set up a recording for <skill>", or "/recording-rig:author". Walks the user through agent command, gates, companion pane, and validation, then writes a valid spec file.
---

# author-spec

Turn a prose description of what the user wants to record into a working JSON spec.

## When to use

Trigger when the user describes a recording they want — even informally:

- "I want to record my new /foo command running"
- "Let's make a gif for the README of this skill"
- "Capture this two-pane demo where the agent kicks off a job and a watcher reports progress"
- "/recording-rig:author"

## What to ask (in order — each as a separate `AskUserQuestion` if interactive)

1. **Session name.** Suggest a slug-cased default derived from the user's description. Must match `[A-Za-z0-9._-]+`.

2. **Recording shape** — pick one:
   - Single-pane (agent runs a command and replies)
   - Gated (agent calls `AskUserQuestion`, rig auto-answers a specific option)
   - Multi-command (agent runs commands in sequence across turns)
   - Two-pane (agent + companion observer process — companion subscribes to a sentinel emitted by a `PostToolUse` hook)

3. **Agent command(s).** The slash command(s) or prose prompt(s) to paste. Single string for shape 1/2; array for shape 3. Be explicit in the prompt — claude works best with "Reply with exactly one line: PREFIX=<answer>" style instructions.

4. **Working dir (`agent.cwd`).** Where the child claude session runs. Often the user's current project root.

5. **Bypass permissions?** Default yes for tutorial recordings (smoother flow). Spec field: `agent.bypass_permissions: true`.

6. **Model.** Default `haiku` for fast deterministic answers, `sonnet` for anything reasoning-heavy. Goes in `agent.extra_args: ["--model", "haiku"]`.

7. **Gates (shape 2 only).** For each gate: which option index to pick (1-based), pre/post Enter hold seconds. The rig sends `(N-1) × Down + Enter`.

8. **PostToolUse capture (shape 4 only).** Tool matcher regex (e.g. `^Bash$` or `^mcp__.*__start_job$`) and a jq expression to extract the ID/payload from `tool_response`. Sentinel name must match `[A-Za-z0-9._-]+`.

9. **Companion (shape 4 only).** Command + args. Environment vars referencing sentinels as `$sentinel-name`. List the sentinels in `wait_for_sentinels`.

10. **Validation assertions.** What strings prove the recording worked? Most important: pick strings that the agent emits but the prompt does NOT contain — otherwise the validator passes on the prompt echo. Use either `must_contain` (set check) or `must_contain_in_order` (sequence check). The `must_not_contain` default already covers `step_aborted` / `failure_reason`.

## Critical correctness rules

- **Validation strings must be agent-output, not prompt text.** If the user asks "validate against ANSWER=42", check whether "ANSWER=42" appears in the agent.command — if yes, suggest a more unique assertion (e.g. add a random suffix prefix like "RESULT-7K2F=" that's clearly emitted, not echoed).
- **`pre_enter_sec >= 1`.** The driver floors this at 1, but the spec author should pick 3-5s for human readability of the gate.
- **Sentinel names + env keys are shell-validated** — `[A-Za-z0-9._-]+` for sentinels, `[A-Za-z_][A-Za-z0-9_]*` for env keys. Reject anything else at authoring time.

## Output

Write the spec to a path the user picks (default: `recordings/<session>.json` in the current project). After writing, suggest the next step:

```
Spec written to recordings/<session>.json. Run with:
  ${CLAUDE_PLUGIN_ROOT}/bin/record.sh recordings/<session>.json
```

Reference the four canonical examples for shape-matching:

- `${CLAUDE_PLUGIN_ROOT}/examples/single-pane.json`
- `${CLAUDE_PLUGIN_ROOT}/examples/gated.json`
- `${CLAUDE_PLUGIN_ROOT}/examples/two-pane.json`
- `${CLAUDE_PLUGIN_ROOT}/examples/multi-command.json`
