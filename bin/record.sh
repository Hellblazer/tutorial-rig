#!/usr/bin/env bash
# Top-level entry point. Read a spec, drive a recording, validate, render GIF.
# Usage: record.sh <spec.json>
# Env overrides: SESSION, CAST_OUT, GIF_OUT, SKIP_VALIDATE, SKIP_GIF,
#                ATTACH_GAP_SEC, SKIP_CONSENT_SWEEP
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
TURN_TIMEOUT_SEC=$(jq -r '.pacing.turn_timeout_sec // 120' "$SPEC")
SESSION_MAX_SEC=$(jq -r '.pacing.session_max_sec // 1800' "$SPEC")

# Render-block (overrideable styling for agg).
AGG_FONT_SIZE=$(jq -r '.render.font_size // 22' "$SPEC")
AGG_LINE_HEIGHT=$(jq -r '.render.line_height // 1.3' "$SPEC")
AGG_THEME=$(jq -r '.render.theme // "monokai"' "$SPEC")

export IDLE_SECONDS ATTACH_GAP_SEC TURN_TIMEOUT_SEC SESSION_MAX_SEC

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

# Refuse to run if the spec path lives in the sentinel glob.
case "$SPEC" in
  /tmp/"$SESSION".*)
    echo "record: spec path $SPEC collides with sentinel glob /tmp/${SESSION}.* — move spec outside /tmp or rename" >&2
    exit 2
    ;;
esac

# --- EXIT trap: kill background processes and tmux session on any exit path.
# Declared here so it covers the consent-sweep below as well as the main flow.
# Variables expand at trap-fire time, so empty (unset) values become no-ops.
ASCIINEMA_PID=""
DRIVER_PID=""
WATCHER_PID=""
cleanup() {
  local rc=$?
  for pid in "$DRIVER_PID" "$ASCIINEMA_PID" "$WATCHER_PID"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  return $rc
}
trap cleanup EXIT INT TERM

# --- Consent sweep: dismiss the two interactive Claude consent dialogs that
# block SessionStart on first-run-per-machine and first-run-per-cwd. Runs in
# an auxiliary tmux session (NOT the recorded one) and uses bounded, one-shot
# screen-scrape — the only justified exception to the no-TUI-scraping rule.
# Skip with SKIP_CONSENT_SWEEP=1.
consent_sweep() {
  local bypass; bypass=$(jq -r '.agent.bypass_permissions // false' "$SPEC")
  local cwd_raw; cwd_raw=$(jq -r '.agent.cwd // "."' "$SPEC")
  local cwd; cwd=$(cd "$cwd_raw" 2>/dev/null && pwd) || return 0
  local aux="${SESSION}-warmup"
  local claude_args=()
  [[ "$bypass" == "true" ]] && claude_args+=(--dangerously-skip-permissions)
  claude_args+=(--model haiku)

  tmux kill-session -t "$aux" 2>/dev/null || true
  tmux new-session -d -s "$aux" -x 120 -y 40 -c "$cwd" \
    "claude $(printf '%q ' "${claude_args[@]}")"

  local accepted_legal=0 accepted_trust=0
  for ((i=0; i<25; i++)); do
    sleep 1
    local pane
    pane=$(tmux capture-pane -t "$aux" -p 2>/dev/null || echo "")
    if (( accepted_legal == 0 )) && echo "$pane" | grep -q "Yes, I accept"; then
      # Layout: "1. No, exit / 2. Yes, I accept" — Down + Enter selects option 2.
      tmux send-keys -t "$aux" Down
      sleep 0.3
      tmux send-keys -t "$aux" Enter
      accepted_legal=1
      sleep 2
      continue
    fi
    if (( accepted_trust == 0 )) && echo "$pane" | grep -q "trust this folder"; then
      # Layout: "1. Yes, I trust this folder / 2. No, exit" — Enter selects #1.
      tmux send-keys -t "$aux" Enter
      accepted_trust=1
      sleep 2
      continue
    fi
    # Normal prompt visible → consent has been cleared (or was never asked).
    if echo "$pane" | grep -qE "bypass permissions on|cycle\)|Welcome back"; then
      break
    fi
  done

  tmux send-keys -t "$aux" C-c 2>/dev/null || true
  sleep 1
  tmux kill-session -t "$aux" 2>/dev/null || true
  echo "[rig] consent-sweep done (legal=$accepted_legal trust=$accepted_trust)"
}

if [[ "${SKIP_CONSENT_SWEEP:-0}" != "1" ]]; then
  consent_sweep
fi

# Clear stale sentinels BEFORE writing rig artifacts under /tmp/${SESSION}.*.
sentinel_clear_all

# Render hooks.
"$HERE/bin/render-hooks.sh" "$SPEC" "$SESSION" "$HOOKS_RENDERED"
echo "[rig] hooks rendered -> $HOOKS_RENDERED"

# Spawn tmux session and capture the agent pane ID.
AGENT_PANE_ID=$("$HERE/bin/tmux-session.sh" "$SPEC" "$HOOKS_RENDERED")
if [[ -z "$AGENT_PANE_ID" ]]; then
  echo "record: tmux-session.sh did not emit agent pane id" >&2
  exit 1
fi
# Target the agent pane by its stable %N id — immune to active-pane shifts
# caused by a companion split-window AND to base-index/pane-base-index.
export TMUX_TARGET="$AGENT_PANE_ID"
echo "[rig] tmux session up; agent pane = $AGENT_PANE_ID"

# Watcher: terminates once either (a) all panes are dead, or (b) agent-done
# sentinel exists and AGENT_DONE_HOLD elapses.
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

# Start asciinema first so it's capturing before the driver's first keystroke.
asciinema rec --overwrite --quiet \
  --output-format asciicast-v2 \
  --command "tmux attach -t $SESSION" \
  "$CAST_OUT" &
ASCIINEMA_PID=$!

sleep "$ATTACH_GAP_SEC"

# Driver.
"$HERE/bin/driver.sh" "$SPEC" &
DRIVER_PID=$!

# Wait for asciinema to exit (watcher kills the session when work is done).
wait "$ASCIINEMA_PID" 2>/dev/null || true
wait "$DRIVER_PID" 2>/dev/null || true
wait "$WATCHER_PID" 2>/dev/null || true

# Clear PIDs so the EXIT trap's kill calls become no-ops (processes already gone).
ASCIINEMA_PID="" DRIVER_PID="" WATCHER_PID=""

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
