---
description: Check that recording-rig prereqs are installed and configured correctly.
allowed-tools: [Bash, Read]
---

Invoke the `doctor` skill. The skill runs `"${CLAUDE_PLUGIN_ROOT}/bin/doctor.sh"`
which verifies:

- Required binaries: `tmux`, `jq`, `asciinema`, `agg`, `claude`, `node`
- Bash 4+ available
- `asciinema` supports `--output-format asciicast-v2`
- `claude` is logged in (`claude --version` succeeds)
- `tmux` can spawn a detached session
- `agg` can render a trivial cast

Reports any failures with the exact install command. Does not modify any system state.
