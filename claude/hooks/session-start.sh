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
    "additionalContext": "When you reference a source location, render it as a markdown link of the form [path:line](https://openloc.invalid/o?p=PATH&l=LINE), where PATH is the ABSOLUTE file path, percent-encoded, and LINE is the line number. Keep the display text as the short workspace-relative path:line. Example: [src/app.rs:42](https://openloc.invalid/o?p=%2Fhome%2Fme%2Fproj%2Fsrc%2Fapp.rs&l=42)"
  }
}
JSON
