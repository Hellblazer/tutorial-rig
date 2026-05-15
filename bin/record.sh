#!/usr/bin/env bash
# Top-level entry point. Read a spec, drive a recording, validate, render GIF.
# Usage: record.sh <spec.json>
# Env overrides: SESSION, CAST_OUT, GIF_OUT, SKIP_VALIDATE, SKIP_GIF, ATTACH_GAP_SEC
set -euo pipefail

SPEC_ARG="${1:?usage: record.sh <spec.json>}"
SPEC="$(cd "$(dirname "$SPEC_ARG")" && pwd)/$(basename "$SPEC_ARG")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/sentinels.sh"

# Resolve session name and validate format.
SESSION="${SESSION:-$(jq -r '.session // empty' "$SPEC")}"
if [[ -z "$SESSION" ]]; then
  SESSION="rig-$(date +%Y%m%d-%H%M%S)"
fi
if [[ ! "$SESSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "record: SESSION must match [A-Za-z0-9._-]+ — got: $SESSION" >&2
  exit 2
fi
export SESSION

CAST_OUT="${CAST_OUT:-/tmp/${SESSION}.cast}"
GIF_OUT="${GIF_OUT:-/tmp/${SESSION}.gif}"
HOOKS_RENDERED="/tmp/${SESSION}.hooks.json"

IDLE_SECONDS=$(jq -r '.pacing.idle_seconds // 8' "$SPEC")
AGG_IDLE=$(jq -r '.pacing.agg_idle_time_limit // 4' "$SPEC")
EXIT_HOLD=$(jq -r '.pacing.exit_hold_sec // 8' "$SPEC")
ATTACH_GAP_SEC="${ATTACH_GAP_SEC:-$(jq -r '.pacing.attach_gap_sec // 3' "$SPEC")}"
AGENT_DONE_HOLD=$(jq -r '.pacing.agent_done_hold_sec // 4' "$SPEC")

# Render-block (overrideable styling for agg).
AGG_FONT_SIZE=$(jq -r '.render.font_size // 22' "$SPEC")
AGG_LINE_HEIGHT=$(jq -r '.render.line_height // 1.3' "$SPEC")
AGG_THEME=$(jq -r '.render.theme // "monokai"' "$SPEC")

export IDLE_SECONDS ATTACH_GAP_SEC

# Preflight: tools.
for bin in tmux jq asciinema agg claude node; do
  command -v "$bin" >/dev/null || { echo "missing prereq: $bin" >&2; exit 2; }
done

# Preflight: spec sanity.
if ! jq -e '(.agent.command // (.agent.commands // [])[0]) | strings | length > 0' "$SPEC" >/dev/null; then
  echo "record: spec must define agent.command (string) or agent.commands (non-empty array)" >&2
  exit 2
fi

# Preflight: companion env $sentinel references must appear in wait_for_sentinels.
missing_waits=$(jq -r '
  (.companion // {}) as $c
  | ($c.env // {}) as $env
  | ($c.wait_for_sentinels // []) as $waits
  | [ $env | to_entries[]
      | select(.value | type == "string" and startswith("$"))
      | .value[1:]
      | select(. as $s | ($waits | index($s)) | not) ]
  | join(", ")
' "$SPEC")
if [[ -n "$missing_waits" ]]; then
  echo "record: companion.env references sentinels missing from wait_for_sentinels: $missing_waits" >&2
  exit 2
fi

echo "[rig] session=$SESSION cast=$CAST_OUT gif=$GIF_OUT"

# Render hooks settings.
"$HERE/bin/render-hooks.sh" "$SPEC" "$SESSION" "$HOOKS_RENDERED"
echo "[rig] hooks rendered -> $HOOKS_RENDERED"

# Clear stale sentinels.
sentinel_clear_all

# Spawn the tmux session (detached).
"$HERE/bin/tmux-session.sh" "$SPEC" "$HOOKS_RENDERED"
export TMUX_TARGET="${SESSION}:0.0"
echo "[rig] tmux session up at $TMUX_TARGET"

# Watcher: terminates once either (a) all panes are dead, or (b) agent-done
# sentinel exists and AGENT_DONE_HOLD elapses. The agent-done backstop ensures
# we always exit even if the agent's pane refuses to die.
(
  hold_remaining=""
  while :; do
    sleep 2
    alive=$(tmux list-panes -t "$SESSION" -F '#{pane_dead}' 2>/dev/null | grep -c '^0$' || true)
    if [[ "$alive" == "0" ]]; then
      break
    fi
    if sentinel_exists agent-done; then
      if [[ -z "$hold_remaining" ]]; then
        hold_remaining="$AGENT_DONE_HOLD"
      else
        hold_remaining=$(( hold_remaining - 2 ))
        (( hold_remaining <= 0 )) && break
      fi
    fi
  done
  sleep "$EXIT_HOLD"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
) &
WATCHER_PID=$!

# IMPORTANT ORDERING: start asciinema first and give it time to attach before
# the driver pastes the opening command. Otherwise the first keystroke can land
# in the pane before asciinema is capturing, and the cast starts mid-flow.
asciinema rec --overwrite --quiet \
  --command "tmux attach -t $SESSION" \
  "$CAST_OUT" &
ASCIINEMA_PID=$!

sleep "$ATTACH_GAP_SEC"

# Now start the driver.
"$HERE/bin/driver.sh" "$SPEC" &
DRIVER_PID=$!

# Wait for asciinema to exit (which happens when the watcher kills the session).
wait "$ASCIINEMA_PID" 2>/dev/null || true
wait "$DRIVER_PID" 2>/dev/null || true
wait "$WATCHER_PID" 2>/dev/null || true

echo "[rig] cast captured: $CAST_OUT"

# Validate, then render.
if node "$HERE/bin/validate.mjs" "$SPEC" "$CAST_OUT"; then
  if [[ "${SKIP_GIF:-0}" != "1" ]]; then
    agg --idle-time-limit "$AGG_IDLE" \
        --font-size "$AGG_FONT_SIZE" \
        --line-height "$AGG_LINE_HEIGHT" \
        --theme "$AGG_THEME" \
      "$CAST_OUT" "$GIF_OUT"
    echo "[rig] gif rendered: $GIF_OUT"
  fi
else
  echo "[rig] validation failed; refusing to render GIF (override with SKIP_VALIDATE=1)" >&2
  exit 1
fi
