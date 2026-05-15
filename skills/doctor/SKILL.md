---
name: doctor
description: Verify that recording-rig prereqs are installed and working. Use when the user asks "is recording-rig set up", "check my rig install", "/recording-rig:doctor", or before any first-time recording. Checks tmux, jq, asciinema, agg, node, bash version, claude login state, and consent dialogs.
---

# doctor

Verify the host can run a recording end-to-end before the user tries.

## Checks (run via Bash, in order)

1. **Binaries on PATH** — fail loudly if missing, suggest install command:
   ```bash
   for b in tmux jq asciinema agg claude node; do
     if ! command -v $b >/dev/null; then echo "MISSING: $b"; fi
   done
   ```
   Suggested installs (macOS): `brew install tmux jq asciinema agg node`. `claude` install is per Anthropic's instructions.

2. **bash version 4+** — record.sh refuses to run on bash 3.2 (macOS default).
   ```bash
   bash -c '(( BASH_VERSINFO[0] >= 4 )) && echo OK || echo "bash too old: $BASH_VERSION (need 4+; brew install bash)"'
   ```

3. **asciinema version + output format** — v3 defaults to asciicast-v3; the rig forces v2. Confirm `asciinema rec --help | grep -q asciicast-v2`.

4. **claude is logged in**:
   ```bash
   claude --version
   ```
   If this prompts for login, route the user to `claude login` first.

5. **tmux can spawn a detached session** (sanity check, isolates tmux config breakage):
   ```bash
   tmux new-session -d -s rig-doctor-$$ 'sleep 1' && tmux kill-session -t rig-doctor-$$
   ```

6. **agg can render a trivial cast**:
   ```bash
   printf '{"version":2,"width":80,"height":24}\n[0.1,"o","hello\\n"]\n' > /tmp/rig-doctor.cast
   agg /tmp/rig-doctor.cast /tmp/rig-doctor.gif && rm /tmp/rig-doctor.cast /tmp/rig-doctor.gif
   ```

7. **Consent state (informational only)** — first time on a machine, the user must accept claude's `--dangerously-skip-permissions` consent once. The recording-rig's consent-sweep handles this automatically, but it adds ~25s to the first recording. Mention this to set expectations.

## Reporting

If all checks pass: report "doctor: all checks passed" with one summary line.

If any fail: list the failures with the exact install command for each. Don't proceed to recording until they're fixed.

## What this skill does NOT do

- Install anything (the host's package manager is the user's responsibility).
- Modify the user's `~/.claude/` state (consent acceptance happens during real recordings, not here).
- Run an actual recording (route to the `record` skill for that).
