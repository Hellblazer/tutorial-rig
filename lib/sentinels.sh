#!/usr/bin/env bash
# Sentinel-file helpers. Sourced by other scripts.
# All sentinels live at /tmp/${SESSION}.<suffix>.

sentinel_path() {
  printf '/tmp/%s.%s' "$SESSION" "$1"
}

sentinel_clear_all() {
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

# Block until `turn-end` has not been modified for $idle_seconds consecutive seconds.
# Detects multi-turn agent idle without counting turns.
sentinel_wait_idle() {
  local idle="${1:-8}" timeout="${2:-1800}" elapsed=0
  local p; p="$(sentinel_path turn-end)"
  while :; do
    if [[ -e "$p" ]]; then
      local now mtime delta
      now=$(date +%s)
      mtime=$(stat -f %m "$p" 2>/dev/null || stat -c %Y "$p")
      delta=$((now - mtime))
      (( delta >= idle )) && return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed >= timeout )); then
      echo "sentinel_wait_idle: timed out after ${timeout}s" >&2
      return 1
    fi
  done
}
