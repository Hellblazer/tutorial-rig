#!/usr/bin/env bash
# Top-level entry point. Read a spec, drive a recording, validate, render GIF.
# Usage: record.sh <spec.json>
# Env overrides: SESSION, CAST_OUT, GIF_OUT, SKIP_VALIDATE, SKIP_GIF
set -euo pipefail

SPEC_ARG="${1:?usage: record.sh <spec.json>}"
SPEC="$(cd "$(dirname "$SPEC_ARG")" && pwd)/$(basename "$SPEC_ARG")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/sentinels.sh"

# Resolve session name.
SESSION="${SESSION:-$(jq -r '.session // empty' "$SPEC")}"
if [[ -z "$SESSION" ]]; then
  SESSION="rig-$(date +%Y%m%d-%H%M%S)"
fi
export SESSION

CAST_OUT="${CAST_OUT:-/tmp/${SESSION}.cast}"
GIF_OUT="${GIF_OUT:-/tmp/${SESSION}.gif}"
HOOKS_RENDERED="/tmp/${SESSION}.hooks.json"

IDLE_SECONDS=$(jq -r '.pacing.idle_seconds // 8' "$SPEC")
AGG_IDLE=$(jq -r '.pacing.agg_idle_time_limit // 4' "$SPEC")
EXIT_HOLD=$(jq -r '.pacing.exit_hold_sec // 8' "$SPEC")
export IDLE_SECONDS

# Preflight.
for bin in tmux jq asciinema agg claude node; do
  command -v "$bin" >/dev/null || { echo "missing prereq: $bin" >&2; exit 2; }
done

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

# Background pane-dead watcher: kill session once all panes are dead + hold.
(
  while :; do
    sleep 2
    alive=$(tmux list-panes -t "$SESSION" -F '#{pane_dead}' 2>/dev/null | grep -c '^0$' || true)
    [[ "$alive" == "0" ]] && break
  done
  sleep "$EXIT_HOLD"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
) &
WATCHER_PID=$!

# Background driver.
"$HERE/bin/driver.sh" "$SPEC" &
DRIVER_PID=$!

# Foreground: record via asciinema attaching to the session.
# When asciinema exits (session killed by watcher), we move on.
asciinema rec --overwrite --quiet \
  --command "tmux attach -t $SESSION" \
  "$CAST_OUT" || true

wait "$DRIVER_PID" 2>/dev/null || true
wait "$WATCHER_PID" 2>/dev/null || true

echo "[rig] cast captured: $CAST_OUT"

# Validate.
if node "$HERE/bin/validate.mjs" "$SPEC" "$CAST_OUT"; then
  if [[ "${SKIP_GIF:-0}" != "1" ]]; then
    agg --idle-time-limit "$AGG_IDLE" --font-size 22 --line-height 1.3 --theme monokai \
      "$CAST_OUT" "$GIF_OUT"
    echo "[rig] gif rendered: $GIF_OUT"
  fi
else
  echo "[rig] validation failed; refusing to render GIF (override with SKIP_VALIDATE=1)" >&2
  exit 1
fi
