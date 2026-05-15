#!/usr/bin/env bash
# Spawn a tmux session with the agent pane (and optional companion pane).
# Usage: tmux-session.sh <spec.json> <hooks-rendered.json>
# Env: SESSION
set -euo pipefail

SPEC="$1"
HOOKS="$2"
: "${SESSION:?SESSION required}"

tmux_size=$(jq -r '.pacing.tmux_size // "180x50"' "$SPEC")
cols="${tmux_size%x*}"; rows="${tmux_size#*x}"
cwd=$(jq -r '.agent.cwd // "."' "$SPEC")
extra_args=$(jq -r '.agent.extra_args // [] | join(" ")' "$SPEC")
companion_cmd=$(jq -r '.companion.command // empty' "$SPEC")

# Kill any prior session of this name.
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Agent pane.
agent_cmd="cd $cwd && claude --settings $HOOKS $extra_args"
tmux new-session -d -s "$SESSION" -x "$cols" -y "$rows" \
  -e "SESSION=$SESSION" \
  "$agent_cmd"
tmux set-option -t "$SESSION" remain-on-exit on

# Optional companion pane.
if [[ -n "$companion_cmd" ]]; then
  # Build env exports for the companion. Substitute $sentinel-name with cat of sentinel.
  env_exports=""
  while IFS=$'\t' read -r k v; do
    [[ -z "$k" ]] && continue
    if [[ "$v" == \$* ]]; then
      sent="${v#\$}"
      env_exports+="export $k=\"\$(cat /tmp/$SESSION.$sent 2>/dev/null)\"; "
    else
      env_exports+="export $k=\"$v\"; "
    fi
  done < <(jq -r '.companion.env // {} | to_entries[] | "\(.key)\t\(.value)"' "$SPEC")

  # Build a wait-for-sentinels prelude.
  wait_prelude=""
  while read -r sent; do
    [[ -z "$sent" ]] && continue
    wait_prelude+="while [ ! -e /tmp/$SESSION.$sent ]; do sleep 1; done; "
  done < <(jq -r '.companion.wait_for_sentinels // [] | .[]' "$SPEC")

  full_companion="export SESSION=$SESSION; $wait_prelude $env_exports $companion_cmd"
  tmux split-window -h -t "$SESSION:0" -e "SESSION=$SESSION" "bash -lc '$full_companion'"
  tmux select-layout -t "$SESSION:0" even-horizontal
fi
