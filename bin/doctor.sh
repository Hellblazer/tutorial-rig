#!/usr/bin/env bash
# Verify recording-rig prereqs. Exit 0 on all pass, non-zero on any fail.
# Used by the `doctor` skill and the /recording-rig:doctor slash command.
set -u

fail=0
ok() { printf "  ✓  %s\n" "$1"; }
bad() { printf "  ✗  %s\n" "$1" >&2; fail=$((fail+1)); }
hint() { printf "     → %s\n" "$1" >&2; }

echo "[doctor] checking prereqs..."

# 1. Binaries on PATH
for b in tmux jq asciinema agg claude node; do
  if command -v "$b" >/dev/null 2>&1; then
    ok "$b on PATH ($(command -v "$b"))"
  else
    bad "$b MISSING"
    case "$b" in
      tmux|jq|asciinema|agg|node) hint "install: brew install $b" ;;
      claude) hint "install: see https://docs.claude.com/en/docs/claude-code" ;;
    esac
  fi
done

# 2. Bash version
if (( BASH_VERSINFO[0] >= 4 )); then
  ok "bash version ${BASH_VERSION%%(*}"
else
  bad "bash ${BASH_VERSION} is too old (need 4+)"
  hint "install: brew install bash, then ensure /opt/homebrew/bin is in PATH before /bin"
fi

# 3. asciinema v2 format support
if command -v asciinema >/dev/null 2>&1; then
  if asciinema rec --help 2>&1 | grep -q "asciicast-v2"; then
    ok "asciinema supports --output-format asciicast-v2"
  else
    bad "asciinema does not advertise asciicast-v2 — validator parses v2 only"
    hint "upgrade asciinema or downgrade to a v2-emitting build"
  fi
fi

# 4. claude reachable
if command -v claude >/dev/null 2>&1; then
  if claude --version >/dev/null 2>&1; then
    ok "claude --version succeeds ($(claude --version 2>&1 | head -1))"
  else
    bad "claude --version failed — not logged in?"
    hint "log in interactively first: claude"
  fi
fi

# 5. tmux can spawn detached
if command -v tmux >/dev/null 2>&1; then
  s="rig-doctor-$$"
  if tmux new-session -d -s "$s" 'sleep 1' 2>/dev/null; then
    ok "tmux new-session works"
    tmux kill-session -t "$s" 2>/dev/null || true
  else
    bad "tmux new-session failed"
    hint "check ~/.tmux.conf for syntax errors; try: tmux -f /dev/null new-session -d -s test"
  fi
fi

# 6. agg can render a trivial cast
if command -v agg >/dev/null 2>&1; then
  tmp_cast="/tmp/rig-doctor-$$.cast"
  tmp_gif="/tmp/rig-doctor-$$.gif"
  printf '{"version":2,"width":80,"height":24}\n[0.1,"o","hello\\n"]\n' > "$tmp_cast"
  if agg --idle-time-limit 1 "$tmp_cast" "$tmp_gif" >/dev/null 2>&1; then
    ok "agg renders a trivial cast"
  else
    bad "agg failed on a trivial cast"
    hint "check agg version: agg --version"
  fi
  rm -f "$tmp_cast" "$tmp_gif"
fi

echo
if (( fail == 0 )); then
  echo "[doctor] all checks passed."
  exit 0
else
  echo "[doctor] $fail check(s) failed." >&2
  exit 1
fi
