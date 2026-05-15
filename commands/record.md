---
description: Record a Claude Code session from a JSON spec — drives an isolated child claude under tmux + asciinema, validates the cast, renders a GIF.
argument-hint: <path-to-spec.json>
allowed-tools: [Bash, Read, AskUserQuestion]
---

Invoke the `record` skill with `"$ARGUMENTS"` as the spec path.

The skill verifies prereqs (routing to `doctor` on miss), runs
`"${CLAUDE_PLUGIN_ROOT}/bin/record.sh" "$ARGUMENTS"`, and reports the
cast + GIF paths on success — or routes to `diagnose` on failure.
