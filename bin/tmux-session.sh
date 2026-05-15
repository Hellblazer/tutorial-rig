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
cwd_raw=$(jq -r '.agent.cwd // "."' "$SPEC")
cwd=$(cd "$cwd_raw" 2>/dev/null && pwd) || { echo "tmux-session: bad cwd: $cwd_raw" >&2; exit 2; }
bypass=$(jq -r '.agent.bypass_permissions // false' "$SPEC")
companion_cmd=$(jq -r '.companion.command // empty' "$SPEC")

# Build claude argv as a quoted single-string command for tmux.
declare -a claude_argv=(claude --settings "$HOOKS")
if [[ "$bypass" == "true" ]]; then
  claude_argv+=(--dangerously-skip-permissions)
fi
while IFS= read -r arg; do
  [[ -z "$arg" ]] && continue
  claude_argv+=("$arg")
done < <(jq -r '.agent.extra_args // [] | .[]' "$SPEC")

agent_cmd=""
for a in "${claude_argv[@]}"; do
  agent_cmd+="$(printf '%q ' "$a")"
done

# Kill any prior session of this name.
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Agent pane. -c sets working dir cleanly (no `cd && ...` string-splicing).
tmux new-session -d -s "$SESSION" -x "$cols" -y "$rows" \
  -c "$cwd" \
  -e "SESSION=$SESSION" \
  "$agent_cmd"
tmux set-option -t "$SESSION" remain-on-exit on

# Optional companion pane.
if [[ -n "$companion_cmd" ]]; then
  # Companion env is written to a sourced env-file (not embedded in a bash -c
  # string) so sentinel values containing quotes/$/\ can't break the spawn.
  envfile="/tmp/${SESSION}.companion-env"
  : > "$envfile"

  wait_prelude=""
  while read -r sent; do
    [[ -z "$sent" ]] && continue
    wait_prelude+="while [ ! -e /tmp/${SESSION}.${sent} ]; do sleep 1; done"$'\n'
  done < <(jq -r '.companion.wait_for_sentinels // [] | .[]' "$SPEC")

  resolve_env=""
  while IFS=$'\t' read -r k v; do
    [[ -z "$k" ]] && continue
    if [[ "$v" == \$* ]]; then
      sent="${v#\$}"
      # cat the sentinel into a shell var (no quoting issues — shell does the read)
      resolve_env+="$(printf '%s=$(cat /tmp/%s.%s)\nexport %s\n' "$k" "$SESSION" "$sent" "$k")"
    else
      resolve_env+="$(printf 'export %s=%q\n' "$k" "$v")"
    fi
  done < <(jq -r '.companion.env // {} | to_entries[] | "\(.key)\t\(.value)"' "$SPEC")

  {
    printf 'export SESSION=%q\n' "$SESSION"
    printf '%s' "$wait_prelude"
    printf '%s' "$resolve_env"
  } > "$envfile"

  tmux split-window -h -t "$SESSION:0" -c "$cwd" -e "SESSION=$SESSION" \
    bash -lc ". $(printf '%q' "$envfile") && exec $companion_cmd"
  tmux select-layout -t "$SESSION:0" even-horizontal
fi
