---
description: Interactively author a recording-rig spec JSON — walks through agent command, gates, companion pane, validation, then writes a valid spec file.
argument-hint: [output-path]
allowed-tools: [Read, Write, AskUserQuestion, Bash]
---

Invoke the `author-spec` skill. If `$ARGUMENTS` is set, use it as the output spec path;
otherwise let the skill suggest one based on the user's description.

The skill walks the user through:
- Session name + recording shape (single-pane, gated, multi-command, two-pane)
- Agent command(s), cwd, model, bypass-permissions
- Gates (option indices, hold timings)
- PostToolUse capture + companion env (for two-pane)
- Validation assertions — with a check that they're agent-output, not prompt-echo

Writes a complete, valid spec the user can immediately run with `/recording-rig:record`.
