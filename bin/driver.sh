#!/usr/bin/env bash
# Drive the agent pane: paste the slash command, then process ordered gates.
# Usage: driver.sh <spec.json>
# Env: SESSION, TMUX_TARGET (e.g. "tutorial:0.0"), IDLE_SECONDS
set -euo pipefail

SPEC="$1"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/sentinels.sh"

: "${SESSION:?SESSION required}"
: "${TMUX_TARGET:?TMUX_TARGET required (e.g. tutorial:0.0)}"
IDLE_SECONDS="${IDLE_SECONDS:-8}"

# Paste a string into the target pane using buffer (reliable for long inputs).
paste_into() {
  local text="$1" buf="rig-buf-$$"
  tmux load-buffer -b "$buf" - <<<"$text"
  tmux paste-buffer -b "$buf" -t "$TMUX_TARGET"
  tmux delete-buffer -b "$buf" 2>/dev/null || true
  tmux send-keys -t "$TMUX_TARGET" Enter
}

# Wait until the agent pane is initialised. SessionStart hook drops a sentinel.
sentinel_wait session-start 60 || true
sleep 2  # let the UI settle

# 1. Paste the slash command.
command=$(jq -r '.agent.command' "$SPEC")
paste_into "$command"

# 2. Process gates in order.
gate_count=$(jq '.gates | length // 0' "$SPEC")
for ((i=0; i < gate_count; i++)); do
  wait_for=$(jq -r ".gates[$i].wait_for // \"gate-pending\"" "$SPEC")
  answer_index=$(jq -r ".gates[$i].answer_index // 1" "$SPEC")
  pre_sec=$(jq -r ".gates[$i].pre_enter_sec // 5" "$SPEC")
  post_sec=$(jq -r ".gates[$i].post_enter_sec // 2" "$SPEC")

  case "$wait_for" in
    turn-end-idle)
      sentinel_wait_idle "$IDLE_SECONDS"
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
  # AskUserQuestion UI: options are numbered; sending the index then Enter selects it.
  tmux send-keys -t "$TMUX_TARGET" "$answer_index"
  sleep 1
  tmux send-keys -t "$TMUX_TARGET" Enter
  sleep "$post_sec"

  touch "$(sentinel_path "gate-${i}-passed")"
done

# 3. Wait for final idle.
sentinel_wait_idle "$IDLE_SECONDS"
touch "$(sentinel_path agent-done)"
