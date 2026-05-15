---
name: record
description: Record a deterministic Claude Code session to an asciicast + GIF. Triggers on "record this tutorial", "make a gif of <skill>", "screencast this", "capture this flow", "run my recording spec", or `/recording-rig:record`. The rig spawns an isolated child claude session under tmux, coordinates via lifecycle-hook sentinels (no TUI scraping), validates the cast, renders a GIF. Requires a JSON spec (see the author-spec skill if you don't have one).
---

# record

Drive `bin/record.sh` to capture a session, validate it, render the GIF.

## When to use

- User has a recording spec and wants to run it
- User asks to "record" / "make a gif of" / "screencast" a Claude Code flow
- The `/recording-rig:record <spec>` slash command was invoked

If the user doesn't have a spec, route to the `author-spec` skill first.

## Preflight (always)

1. Run the doctor skill (or `bin/doctor.sh` if it exists) to verify prereqs (`tmux`, `jq`, `asciinema`, `agg`, `claude`, `node`, bash 4+).
2. Read the spec JSON; verify `agent.command` or `agent.commands[]` is set.
3. If `agent.cwd` is in a folder claude has never trusted before, warn the user: the first run on a new cwd takes ~25s extra for the consent sweep.

## Invocation

```bash
${CLAUDE_PLUGIN_ROOT}/bin/record.sh <path-to-spec.json>
```

Or, if the user wants to override the session name or paths:

```bash
SESSION=my-session CAST_OUT=/tmp/out.cast GIF_OUT=/tmp/out.gif \
  ${CLAUDE_PLUGIN_ROOT}/bin/record.sh <spec>
```

## Reading the result

Exit code 0 + `[rig] gif rendered: <path>` line → success. Show the user the GIF path and the cast path.

Non-zero exit + `[validate] FAILED` → validation failure. Route to the `diagnose` skill with the cast path and spec path.

Hang or `sentinel_wait_idle: no turn-end progress` → the hooks aren't firing in the child claude. Common causes: the child's `~/.claude/` isn't set up (the consent sweep should have handled this — if not, run `claude` interactively once manually to accept consents), or the spec's `agent.cwd` requires a trust accept the sweep missed. Route to `diagnose`.

## Important reminders

- The recording spawns a **separate child claude session** with its own settings file (rendered hooks). The parent claude session (the one running this skill) is unaffected.
- The child session by default inherits the user's installed plugins. If the spec sets `agent.bare: true` (when implemented) or includes `--bare` in `extra_args`, the child runs without plugins — useful for clean tutorials.
- All artifacts land in `/tmp/${SESSION}.*`. Don't store sensitive output there.
- Wall time: 30-90s for a single-pane recording, 60-200s for gated/multi-turn flows. Don't poll status — wait for the process to exit.

## Examples

```
User: record the gated example
Skill: bash ${CLAUDE_PLUGIN_ROOT}/bin/record.sh ${CLAUDE_PLUGIN_ROOT}/examples/gated.json
       Then report the GIF path and validation status.

User: /recording-rig:record /path/to/spec.json
Skill: same, with that explicit path.
```
