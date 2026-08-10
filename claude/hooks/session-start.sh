#!/bin/bash
# SessionStart hook: inject the openloc link-rendering instruction.
# OPENLOC_LINKS=off disables injection for this environment.
if [ "${OPENLOC_LINKS:-}" = "off" ]; then
  exit 0
fi
cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "When you reference a source location, render it as a markdown link of the form [path:line](https://openloc.invalid/o?p=PATH&l=LINE), where PATH is the percent-encoded file path and LINE is the line number. Keep the display text as path:line. Example: [src/app.rs:42](https://openloc.invalid/o?p=src%2Fapp.rs&l=42)"
  }
}
JSON
