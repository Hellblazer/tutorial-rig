#!/usr/bin/env bash
# Render hooks.json from the template by substituting SESSION via jq --arg.
# Usage: render-hooks.sh <spec.json> <session> <out-path>
set -euo pipefail

SPEC="$1"; SESSION="$2"; OUT="$3"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPL="$HERE/hooks/hooks.json.tmpl"

# Reject SESSION values that could escape /tmp/ or inject shell metacharacters.
if [[ ! "$SESSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "render-hooks: SESSION must match [A-Za-z0-9._-]+ — got: $SESSION" >&2
  exit 2
fi

# Build the PostToolUse array from spec.hooks.capture_tools[].
capture_json=$(jq --arg sess "$SESSION" '
  (.hooks.capture_tools // []) as $caps
  | [ $caps[] | {
      matcher: .matcher,
      hooks: [{
        type: "command",
        command: (
          "jq -r '\''.tool_response | (if type==\"array\" then .[0].text else . end) | fromjson | ("
          + .jq
          + " // empty)'\'' | tr -d '\''\\n'\'' > /tmp/" + $sess + "." + .name
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
