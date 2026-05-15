#!/usr/bin/env bash
# Meta-test: run the rig inside an "isolated sandbox" claude installation.
# The sandbox has its own HOME but with key files BIND-symlinked to the
# user's real ~/.claude so OAuth / keychain auth works, while the user's
# ambient plugins/skills/agents/CLAUDE.md are sandboxed away.
#
# Outer recording: invokes /recording-rig:record on inner-spec.json from
# inside a sandboxed claude session. Validator asserts the inner rig's
# log lines appeared in the outer cast — proving the rig works as a
# plugin under HOME-isolation AND survives nested tmux.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SANDBOX=$(mktemp -d /tmp/rig-sandbox-XXXXXX)
echo "[meta] sandbox HOME = $SANDBOX"

# Symlink every direct dotfile and every non-overridden ~/.claude/ entry.
# Then layer ~/.claude/plugins → empty dir so only --plugin-dir loads.
shopt -s dotglob nullglob
for f in "$HOME"/*; do
  name=$(basename "$f")
  case "$name" in
    .claude) ;;  # special-case below
    *) ln -s "$f" "$SANDBOX/$name" ;;
  esac
done

mkdir -p "$SANDBOX/.claude"
for entry in "$HOME"/.claude/*; do
  name=$(basename "$entry")
  case "$name" in
    plugins|skills|agents|CLAUDE.md)
      # Sandbox: empty directory (still navigable) instead of symlink
      [[ "$name" != "CLAUDE.md" ]] && mkdir -p "$SANDBOX/.claude/$name"
      ;;
    *)
      ln -s "$entry" "$SANDBOX/.claude/$name"
      ;;
  esac
done
shopt -u dotglob nullglob

# Clean any prior meta-rig artifacts.
tmux -L recording-rig kill-session -t meta-rig 2>/dev/null || true
tmux -L recording-rig kill-session -t meta-rig-warmup 2>/dev/null || true
tmux -L recording-rig kill-session -t inner-spec 2>/dev/null || true
tmux -L recording-rig kill-session -t inner-spec-warmup 2>/dev/null || true
rm -f /tmp/meta-rig.* /tmp/inner-spec.*

cleanup() {
  local rc=$?
  echo "[meta] cleanup: removing sandbox $SANDBOX"
  rm -rf "$SANDBOX"
  return $rc
}
trap cleanup EXIT

HOME="$SANDBOX" "$HERE/bin/record.sh" "$HERE/test-runs/meta-rig.json"
