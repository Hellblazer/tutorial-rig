# tutorial-rig

A reusable, language-agnostic framework for recording deterministic Claude Code tutorials.
Hook-driven coordination, no TUI scraping. See [`docs/design.md`](docs/design.md) for the rationale.

## Quick start

```bash
# 1. Write a spec (declarative tutorial description)
cp examples/single-pane.json my-tutorial.json
$EDITOR my-tutorial.json

# 2. Record
bin/record.sh my-tutorial.json

# Outputs:
#   /tmp/<session>.cast   (lossless asciinema cast)
#   /tmp/<session>.gif    (agg-rendered GIF; only if validation passes)
```

## What the rig gives you

- **Hook-driven coordination.** A generated `--settings` file installs lifecycle hooks
  (`UserPromptSubmit`, `Stop`, `PreToolUse[AskUserQuestion]`, `PostToolUse`, `SessionStart`)
  that drop sentinel files. The driver watches sentinels, not pane text.
- **Multi-turn idle detection.** The `Stop` hook touches a `turn-end` sentinel every turn.
  Idle = mtime hasn't moved for N seconds. Works uniformly for single-turn and multi-turn flows.
- **Multi-command tutorials.** `agent.commands[]` runs commands in sequence; gates can target
  specific commands via `gates[].for_command`.
- **Reliable gate handling.** `AskUserQuestion` gates are handled by ordered gate decisions in
  the spec. The driver navigates to option N via (N−1) `Down` keypresses then `Enter`, holding
  for pre/post-Enter seconds for readability.
- **Consent sweep.** Before recording, an auxiliary tmux session (not captured) dismisses
  Claude's two interactive consent dialogs (`--dangerously-skip-permissions` legal accept;
  per-workspace trust). Skip with `SKIP_CONSENT_SWEEP=1`. This is the only place the rig
  does TUI screen-scrape, and it's outside the recorded window.
- **Autonomous termination.** Driver sends `/exit` (falling back to `C-c` + `C-d`) when work is
  done so the tmux pane dies, asciinema returns, and the recording completes without manual
  intervention. A backstop in `record.sh` also kills the session once the `agent-done` sentinel
  has been present long enough.
- **Two-pane lockstep (optional).** A companion pane can subscribe to backend state via
  sentinels emitted by the agent's `PostToolUse` hook. One drives, the other observes.
- **Validation gate.** Before rendering the GIF, parse the cast (ANSI/CSI escapes stripped) for
  required positive signals, optional in-order signals, and forbidden failure markers. Refuse
  to render on mismatch (override with `SKIP_VALIDATE=1`).

## Spec format

A tutorial is one JSON file. Fields:

```jsonc
{
  "session": "my-tutorial",            // [A-Za-z0-9._-]+; auto-generated if absent

  "agent": {
    // Either:
    "command": "/my-skill arg1",       // single slash command (or prose)
    // Or:
    "commands": ["/cmd-a", "/cmd-b"],  // sequence of commands across turns
    "cwd": ".",                        // working dir for `claude`; resolved to absolute path
    "extra_args": [],                  // extra args passed to `claude`
    "bypass_permissions": false        // pass --dangerously-skip-permissions
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
    {
      "wait_for": "gate-pending",      // "turn-end-idle" | "gate-pending" | "<sentinel-name>"
      "answer_index": 1,               // 1-based option index; driver sends (N-1) Down + Enter
      "pre_enter_sec": 5,              // hold before Enter (readability)
      "post_enter_sec": 2,             // hold after Enter (resolution on camera)
      "for_command": "/cmd-a"          // optional: only consume after this command
    }
  ],

  "companion": {                       // optional second pane
    "command": "node",                 // executable (program name only when args[] is set)
    "args": ["my-observer.js"],        // optional; argv passed safely (%q-quoted) — use for
                                       //   any command with spaces, quotes, or shell metas
    "wait_for_sentinels": ["project-id"],
    "env": { "SUBSCRIBE_TO": "$project-id" }   // $name resolves /tmp/${SESSION}.name at spawn
  },

  "validate": {
    "must_contain": ["Research complete"],
    "must_contain_in_order": ["Phase 1", "Phase 2", "done"],   // optional ordering check
    "must_not_contain": ["step_aborted", "failure_reason"]     // defaulted if absent
  },

  "pacing": {
    "idle_seconds": 8,                 // Stop-mtime idle threshold (turn-end stable for N s)
    "turn_timeout_sec": 120,           // per-turn ceiling: if turn-end never progresses for this
                                       //   long, abort (Stop hook may not be firing)
    "session_max_sec": 1800,           // absolute upper bound on a single sentinel_wait_idle call
    "attach_gap_sec": 3,               // wait after asciinema start before driver pastes
    "agent_done_hold_sec": 4,          // kill-session backstop after agent-done
    "exit_hold_sec": 8,                // hold final frame before kill-session
    "tmux_size": "180x50"
  },

  "render": {                          // agg styling
    "font_size": 22,
    "line_height": 1.3,
    "theme": "monokai"
  }
}
```

Only `agent.command` or `agent.commands[0]` is required; everything else has sane defaults.
Preflight (in `record.sh`) rejects: bad SESSION characters, missing commands, and any
`companion.env` `$sentinel` reference not listed in `companion.wait_for_sentinels`.

## Architecture

```
record.sh                                              // entry point
  ├─ preflight (tools, spec sanity, env↔wait coherence)
  ├─ render-hooks.sh   // spec → claude --settings file (jq, no sed on JSON body)
  ├─ sentinel_clear_all
  ├─ tmux-session.sh   // spawn detached tmux, optional split for companion pane
  │     ├─ pane 0: claude --settings=<rendered-hooks> [--dangerously-skip-permissions]
  │     └─ pane 1: <companion command, env sourced from /tmp/${SESSION}.companion-env>
  ├─ watcher (background) // exit on all-panes-dead OR agent-done + hold
  ├─ asciinema rec (background, attached to session)
  ├─ ATTACH_GAP_SEC sleep so asciinema is capturing before the first keystroke
  ├─ driver.sh         // paste each command, navigate gates, send /exit
  ├─ validate.mjs      // strip ANSI, check must_contain + order + must_not_contain
  └─ agg               // render GIF iff validation passes (params from spec.render)
```

## Prerequisites

`tmux`, `jq`, `asciinema`, `agg`, the `claude` CLI logged in, Node 20+ (for the validator).
Plus whatever your tutorial's own stack needs.

## See also

- [`docs/design.md`](docs/design.md) — design rationale and failure modes.
- `examples/single-pane.json` — minimal one-pane tutorial.
- `examples/two-pane.json` — lockstep agent + companion.
- `examples/gated.json` — `AskUserQuestion` gates.
