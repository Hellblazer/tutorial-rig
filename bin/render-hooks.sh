#!/usr/bin/env bash
# Render hooks.json from the template by substituting SESSION via jq --arg.
# Usage: render-hooks.sh <spec.json> <session> <out-path>
set -euo pipefail

SPEC="$1"; SESSION="$2"; OUT="$3"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPL="$HERE/hooks/hooks.json.tmpl"
# shellcheck disable=SC1091
source "$HERE/lib/sentinels.sh"

# Reject SESSION values that could escape /tmp/ or inject shell metacharacters.
rig_check_identifier "render-hooks SESSION" "$SESSION" || exit 2

# capture_tools[].name flows into the generated hook command as a sentinel
# filename suffix. Validate before building the shell string.
while IFS= read -r capname; do
  rig_check_identifier "capture_tools[].name" "$capname" || exit 2
done < <(jq -r '(.hooks.capture_tools // []) | .[].name' "$SPEC")

# Build the PostToolUse array from spec.hooks.capture_tools[].
# tool_response shape varies by tool/transport:
#   - HTTP-transport MCP: array of content blocks, [{type:"text", text:"<json>"}]
#   - stdio-transport MCP: JSON-encoded string of the payload
#   - native built-in tools (Bash, Write, AskUserQuestion, etc.): bare structured object
# The unwrap pattern handles all three.
# Generated hook command writes to a .partial sibling, then atomically renames
# to the final sentinel path. Prevents readers from seeing 0-byte / partial
# state if the hook fires twice or jq fails mid-extract. The final filename is
# NAME (no suffix); .partial is invisible to sentinel readers.
capture_json=$(jq --arg sess "$SESSION" '
  (.hooks.capture_tools // []) as $caps
  | [ $caps[] | {
      matcher: .matcher,
      hooks: [{
        type: "command",
        command: (
          "jq -r '\''.tool_response | (if type==\"array\" then (.[0].text | fromjson) elif type==\"string\" then fromjson else . end) | ("
          + .jq
          + " // empty)'\'' | tr -d '\''\\n'\'' > /tmp/" + $sess + "." + .name + ".partial && mv /tmp/" + $sess + "." + .name + ".partial /tmp/" + $sess + "." + .name
        )
      }]
    } ]
' "$SPEC")

# Parse template, swap the __CAPTURE_TOOLS__ placeholder for [], then use jq to
# substitute SESSION recursively in any string field. No sed pass on the JSON
# body, so a SESSION value with regex/replacement metacharacters can't corrupt
# the output (the up-front regex guard above is the primary defence).
sed 's/__CAPTURE_TOOLS__/[]/' "$TMPL" \
  | jq --arg sess "$SESSION" --argjson caps "$capture_json" '
      (.. | strings) |= gsub("__SESSION__"; $sess)
      | .hooks.PostToolUse = $caps
    ' > "$OUT"
