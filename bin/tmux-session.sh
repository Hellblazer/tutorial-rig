#!/usr/bin/env bash
# Spawn a tmux session with the agent pane (and optional companion pane).
# Usage: tmux-session.sh <spec.json> <hooks-rendered.json>
# Env: SESSION
# Stdout: <agent-pane-id> (caller exports as TMUX_TARGET).
set -euo pipefail

SPEC="$1"
HOOKS="$2"
: "${SESSION:?SESSION required}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/sentinels.sh"

# Validate every spec-provided string that gets interpolated into shell.
while IFS= read -r sent; do
  [[ -z "$sent" ]] && continue
  rig_check_identifier "companion.wait_for_sentinels[]" "$sent" || exit 2
done < <(jq -r '.companion.wait_for_sentinels // [] | .[]' "$SPEC")
while IFS= read -r k; do
  [[ -z "$k" ]] && continue
  # Env keys must be valid POSIX identifiers (no dots/dashes — different from sentinel rules).
  rig_check_identifier "companion.env key" "$k" '^[A-Za-z_][A-Za-z0-9_]*$' || exit 2
done < <(jq -r '.companion.env // {} | keys[]' "$SPEC")

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

# Agent pane. Capture the pane ID (%N form, immune to base-index AND to
# active-pane shifts caused by later split-window) so the driver can target
# this exact pane regardless of which pane is "active" later.
AGENT_PANE_ID=$(
  tmux new-session -d -s "$SESSION" -x "$cols" -y "$rows" \
    -c "$cwd" \
    -e "SESSION=$SESSION" \
    -P -F '#{pane_id}' \
    "$agent_cmd"
)
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
  # NOTE: $(...) command substitution strips trailing newlines, so we cannot
  # rely on printf '...\n' inside the substitution. Append a literal $'\n'
  # outside the substitution after each block.
  while IFS=$'\t' read -r k v; do
    [[ -z "$k" ]] && continue
    if [[ "$v" == \$* ]]; then
      sent="${v#\$}"
      resolve_env+="$(printf '%s=$(cat /tmp/%s.%s)\nexport %s' "$k" "$SESSION" "$sent" "$k")"$'\n'
    else
      resolve_env+="$(printf 'export %s=%q' "$k" "$v")"$'\n'
    fi
  done < <(jq -r '.companion.env // {} | to_entries[] | "\(.key)\t\(.value)"' "$SPEC")

  # Build the companion exec line. If companion.args[] is set, treat
  # companion.command as the program and args[] as its argv (safely %q-quoted).
  # Otherwise fall back to companion.command as a single-line shell string
  # (works for trivial cases like "node observer.mjs" with no spaces in args).
  has_args=$(jq -r '(.companion.args // null) | (type == "array")' "$SPEC")
  if [[ "$has_args" == "true" ]]; then
    quoted_argv="$(printf '%q' "$companion_cmd")"
    while IFS= read -r arg; do
      quoted_argv+=" $(printf '%q' "$arg")"
    done < <(jq -r '.companion.args[]' "$SPEC")
    exec_line="exec $quoted_argv"
  else
    exec_line="exec $companion_cmd"
  fi

  {
    printf 'export SESSION=%q\n' "$SESSION"
    printf '%s' "$wait_prelude"
    printf '%s' "$resolve_env"
    printf '%s\n' "$exec_line"
  } > "$envfile"

  tmux split-window -h -t "$AGENT_PANE_ID" -c "$cwd" -e "SESSION=$SESSION" \
    bash -lc ". $(printf '%q' "$envfile")"
  tmux select-layout -t "$SESSION" even-horizontal
fi

# Emit the agent pane ID for record.sh to consume.
printf '%s\n' "$AGENT_PANE_ID"
