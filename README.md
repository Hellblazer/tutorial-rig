# tutorial-rig

A reusable, language-agnostic framework for recording deterministic Claude Code tutorials.
Hook-driven coordination, no TUI scraping. See [`docs/design.md`](docs/design.md) for the rationale.

## Quick start

```bash
# 1. Write a spec (declarative tutorial description)
cp tools/tutorial-rig/examples/single-pane.json my-tutorial.json
$EDITOR my-tutorial.json

# 2. Record
tools/tutorial-rig/bin/record.sh my-tutorial.json

# Outputs:
#   /tmp/<session>.cast   (lossless asciinema cast)
#   /tmp/<session>.gif    (agg-rendered GIF; only if validation passes)
```

## What the rig gives you

- **Hook-driven coordination.** A generated `--settings` file installs three lifecycle hooks
  (`UserPromptSubmit`, `Stop`, `PostToolUse`) that drop sentinel files. The driver watches
  sentinels, not pane text.
- **Multi-turn idle detection.** The `Stop` hook touches a `turn-end` sentinel every turn.
  Idle = mtime hasn't moved for N seconds. Works uniformly for single-turn and multi-turn flows.
- **Reliable gate handling.** `AskUserQuestion` gates are handled by ordered gate decisions in
  the spec. The driver pastes the chosen option index via `tmux paste-buffer`, holds for
  pre/post-Enter seconds for readability.
- **Two-pane lockstep (optional).** A companion pane can subscribe to backend state via
  sentinels emitted by the agent's `PostToolUse` hook. One drives, the other observes.
- **Validation gate.** Before rendering the GIF, parse the cast for required positive signals
  and forbidden failure markers. Refuse to render on mismatch (override with `SKIP_VALIDATE=1`).

## Spec format

A tutorial is one JSON file. Fields:

```jsonc
{
  "session": "my-tutorial",            // ${SESSION} for sentinels; auto-generated if absent
  "agent": {
    "command": "/my-skill arg1 arg2",  // slash command (or prose) pasted into the agent pane
    "cwd": ".",                        // working dir for `claude`; defaults to $PWD
    "extra_args": []                   // extra args passed to `claude`
  },
  "hooks": {
    "capture_tools": [                 // PostToolUse matchers — each drops a sentinel
      {
        "name": "project-id",          // sentinel filename suffix
        "matcher": "^mcp__.*__start_research$",
        "jq": ".project_id // .projectId"
      }
    ]
  },
  "gates": [                           // ordered AskUserQuestion answers
    { "wait_for": "turn-end-idle", "answer_index": 1, "pre_enter_sec": 5, "post_enter_sec": 2 },
    { "wait_for": "turn-end-idle", "answer_index": 1 }
  ],
  "companion": {                       // optional second pane
    "command": "node my-observer.js",
    "wait_for_sentinels": ["project-id"],
    "env": { "SUBSCRIBE_TO": "$project-id" }
  },
  "validate": {
    "must_contain": ["Research complete", "Recommended:"],
    "must_not_contain": ["step_aborted", "failure_reason", "Error:"]
  },
  "pacing": {
    "idle_seconds": 8,                 // Stop-mtime idle threshold
    "agg_idle_time_limit": 4,          // GIF-only silence cap
    "exit_hold_sec": 8,                // hold final frame before kill-session
    "tmux_size": "180x50"
  }
}
```

Only `agent.command` is required. Everything else has sane defaults.

## Architecture

```
record.sh                                                        // entry point
  ├─ render hooks.json from hooks.json.tmpl (substitute __SESSION__, capture_tools)
  ├─ clear /tmp/${SESSION}.* sentinels
  ├─ tmux-session.sh   // spawn tmux, optionally split for companion pane
  │     ├─ pane 0: claude --settings=<rendered-hooks> ...
  │     └─ pane 1: <companion command>   (optional)
  ├─ asciinema rec wrapping `tmux attach`
  ├─ driver.sh         // paste command, then for each gate: wait_for + press Enter
  ├─ pane-dead watcher // kill-session after exit_hold_sec
  ├─ validate.mjs      // pass/fail the cast
  └─ agg               // render GIF iff validation passes
```

## Prerequisites

`tmux`, `jq`, `asciinema`, `agg`, the `claude` CLI logged in, Node 20+ (for the validator).
Plus whatever your tutorial's own stack needs.

## See also

- [`docs/design.md`](docs/design.md) — design rationale and failure modes.
- `examples/single-pane.json` — minimal one-pane tutorial.
- `examples/two-pane.json` — lockstep agent + companion.
- `examples/gated.json` — `AskUserQuestion` gates.
