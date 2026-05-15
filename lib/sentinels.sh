#!/usr/bin/env bash
# Sentinel-file helpers. Sourced by other scripts.
# All sentinels live at /tmp/${SESSION}.<suffix>.

_require_session() {
  if [[ -z "${SESSION:-}" ]]; then
    echo "sentinels: SESSION is empty or unset" >&2
    return 1
  fi
  # Reject anything that could escape the /tmp/ prefix or inject shell metas.
  if [[ "$SESSION" =~ [^A-Za-z0-9._-] ]]; then
    echo "sentinels: SESSION contains forbidden characters: $SESSION" >&2
    return 1
  fi
}

sentinel_path() {
  _require_session || return 1
  printf '/tmp/%s.%s' "$SESSION" "$1"
}

sentinel_clear_all() {
  _require_session || return 1
  rm -f /tmp/"$SESSION".* 2>/dev/null || true
}

sentinel_exists() {
  [[ -e "$(sentinel_path "$1")" ]]
}

sentinel_read() {
  local p; p="$(sentinel_path "$1")"
  [[ -e "$p" ]] && cat "$p"
}

# Block until a sentinel file exists. Timeout in seconds (default 600).
sentinel_wait() {
  local name="$1" timeout="${2:-600}" elapsed=0
  while ! sentinel_exists "$name"; do
    sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed >= timeout )); then
      echo "sentinel_wait: timed out waiting for $name after ${timeout}s" >&2
      return 1
    fi
  done
}

# Block until `turn-end` has not been modified for $idle_seconds consecutive
# seconds. Detects multi-turn agent idle without counting turns.
#
# Two timeouts:
#   $idle           — quiet window (turn-end mtime stable for this long)
#   $turn_timeout   — per-turn ceiling: if turn-end never appears or never moves
#                     forward, give up after this many seconds. Distinct from
#                     the global session ceiling — a single hung turn shouldn't
#                     block the rig for 30 minutes.
#   $session_max    — absolute upper bound (default 1800s).
sentinel_wait_idle() {
  local idle="${1:-8}" turn_timeout="${2:-120}" session_max="${3:-1800}"
  local elapsed=0 since_progress=0
  local p; p="$(sentinel_path turn-end)" || return 1
  local last_mtime=0
  while :; do
    if [[ -e "$p" ]]; then
      local now mtime delta
      now=$(date +%s)
      mtime=$(stat -f %m "$p" 2>/dev/null || stat -c %Y "$p")
      delta=$((now - mtime))
      (( delta >= idle )) && return 0
      if (( mtime > last_mtime )); then
        last_mtime=$mtime
        since_progress=0
      fi
    fi
    sleep 1
    elapsed=$((elapsed + 1))
    since_progress=$((since_progress + 1))
    if (( since_progress >= turn_timeout )); then
      echo "sentinel_wait_idle: no turn-end progress for ${turn_timeout}s (stop hook may not be firing)" >&2
      return 2
    fi
    if (( elapsed >= session_max )); then
      echo "sentinel_wait_idle: session ceiling ${session_max}s exceeded" >&2
      return 1
    fi
  done
}
