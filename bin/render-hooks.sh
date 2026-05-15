#!/usr/bin/env bash
# Render hooks.json from the template by substituting __SESSION__ and __CAPTURE_TOOLS__.
# Usage: render-hooks.sh <spec.json> <session> <out-path>
set -euo pipefail

SPEC="$1"; SESSION="$2"; OUT="$3"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPL="$HERE/hooks/hooks.json.tmpl"

# Build the PostToolUse array from spec.hooks.capture_tools[].
# Each entry becomes a hook that pipes tool_response through jq and writes a sentinel.
capture_json=$(jq --arg sess "$SESSION" '
  (.hooks.capture_tools // []) as $caps
  | [ $caps[] | {
      matcher: .matcher,
      hooks: [{
        type: "command",
        command: ("jq -r '\''.tool_response | (if type==\"array\" then .[0].text else . end) | fromjson | (" + .jq + " // empty)'\'' | tr -d '\''\\n'\'' > /tmp/" + $sess + "." + .name)
      }]
    } ]
' "$SPEC")

# Substitute into the template.
sed -e "s/__SESSION__/$SESSION/g" -e 's/__CAPTURE_TOOLS__/[]/' "$TMPL" \
  | jq --argjson caps "$capture_json" '.hooks.PostToolUse = $caps' \
  > "$OUT"
