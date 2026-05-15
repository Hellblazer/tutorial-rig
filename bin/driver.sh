#!/usr/bin/env bash
# Drive the agent pane: paste each command in order, process its gates, then
# send an exit sequence so the tmux pane dies and the recording terminates.
# Usage: driver.sh <spec.json>
# Env: SESSION, TMUX_TARGET, IDLE_SECONDS, ATTACH_GAP_SEC
set -euo pipefail

SPEC="$1"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/sentinels.sh"

: "${SESSION:?SESSION required}"
: "${TMUX_TARGET:?TMUX_TARGET required (e.g. tutorial:0.0)}"
IDLE_SECONDS="${IDLE_SECONDS:-8}"
ATTACH_GAP_SEC="${ATTACH_GAP_SEC:-3}"
TURN_TIMEOUT_SEC="${TURN_TIMEOUT_SEC:-120}"
SESSION_MAX_SEC="${SESSION_MAX_SEC:-1800}"

paste_into() {
  local text="$1" buf="rig-buf-$$-$RANDOM"
  tmux load-buffer -b "$buf" - <<<"$text"
  tmux paste-buffer -b "$buf" -t "$TMUX_TARGET"
  tmux delete-buffer -b "$buf" 2>/dev/null || true
  tmux send-keys -t "$TMUX_TARGET" Enter
}

# Wait for the agent pane to initialise; SessionStart hook drops a sentinel.
sentinel_wait session-start 60 || true
# Extra gap so asciinema has time to attach before the first keystroke lands.
sleep "$ATTACH_GAP_SEC"

# Read commands. Backwards-compatible: agent.commands[] wins; agent.command is
# treated as a one-element list.
mapfile -t COMMANDS < <(jq -r '
  .agent as $a
  | if ($a.commands // []) | length > 0 then $a.commands[]
    elif $a.command then $a.command
    else empty end
' "$SPEC")

if (( ${#COMMANDS[@]} == 0 )); then
  echo "driver: spec has no agent.command or agent.commands" >&2
  exit 2
fi

GATE_COUNT=$(jq '.gates | length // 0' "$SPEC")
gate_idx=0

answer_gate() {
  # Gates in CC 2.x are arrow-key-navigable; default highlight is option 1.
  # To pick option N, send (N-1) Down presses, then Enter.
  local i="$1"
  local wait_for answer_index pre_sec post_sec
  wait_for=$(jq -r ".gates[$i].wait_for // \"gate-pending\"" "$SPEC")
  answer_index=$(jq -r ".gates[$i].answer_index // 1" "$SPEC")
  pre_sec=$(jq -r ".gates[$i].pre_enter_sec // 5" "$SPEC")
  post_sec=$(jq -r ".gates[$i].post_enter_sec // 2" "$SPEC")
  # Minimum floor — the AskUserQuestion UI needs a moment to render after the
  # PreToolUse sentinel drops; sending keys earlier loses them.
  (( pre_sec < 1 )) && pre_sec=1
  (( post_sec < 1 )) && post_sec=1

  case "$wait_for" in
    turn-end-idle)
      sentinel_wait_idle "$IDLE_SECONDS" "$TURN_TIMEOUT_SEC" "$SESSION_MAX_SEC" || {
        echo "driver: turn-idle wait failed before gate $i" >&2
        return 1
      }
      ;;
    gate-pending)
      sentinel_wait gate-pending 600
      rm -f "$(sentinel_path gate-pending)"
      ;;
    *)
      sentinel_wait "$wait_for" 600
      ;;
  esac

  sleep "$pre_sec"
  local steps=$(( answer_index - 1 ))
  if (( steps > 0 )); then
    for ((s=0; s<steps; s++)); do
      tmux send-keys -t "$TMUX_TARGET" Down
      sleep 0.2
    done
  fi
  tmux send-keys -t "$TMUX_TARGET" Enter
  sleep "$post_sec"

  touch "$(sentinel_path "gate-${i}-passed")"
}

for cmd in "${COMMANDS[@]}"; do
  if [[ "$cmd" == "null" || -z "$cmd" ]]; then
    echo "driver: skipping empty/null command" >&2
    continue
  fi
  paste_into "$cmd"

  # Consume gates targeted at this command (or all remaining if no targeting).
  while (( gate_idx < GATE_COUNT )); do
    target=$(jq -r ".gates[$gate_idx].for_command // null" "$SPEC")
    if [[ "$target" != "null" && "$target" != "$cmd" ]]; then
      break
    fi
    answer_gate "$gate_idx"
    gate_idx=$(( gate_idx + 1 ))
  done

  if ! sentinel_wait_idle "$IDLE_SECONDS" "$TURN_TIMEOUT_SEC" "$SESSION_MAX_SEC"; then
    rc=$?
    echo "driver: idle wait failed (rc=$rc) after command '$cmd' — aborting remaining commands" >&2
    break
  fi
done

touch "$(sentinel_path agent-done)"

# Send exit so the agent pane dies — otherwise pane_dead never becomes 1 and
# the watcher / asciinema spin forever. Try /exit first; fall back to C-c x2
# + C-d for builds that don't recognise the slash command.
sleep 1
tmux send-keys -t "$TMUX_TARGET" "/exit" Enter
sleep 2
if [[ "$(tmux display-message -p -t "$TMUX_TARGET" '#{pane_dead}' 2>/dev/null)" != "1" ]]; then
  tmux send-keys -t "$TMUX_TARGET" C-c
  sleep 1
  tmux send-keys -t "$TMUX_TARGET" C-c
  sleep 1
  tmux send-keys -t "$TMUX_TARGET" C-d
fi
