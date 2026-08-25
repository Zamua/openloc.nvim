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
    "additionalContext": "When you reference a source location, render it as a markdown link [DISPLAY](https://openloc.invalid/o?p=PATH:LINE). PATH is the ABSOLUTE file path and LINE is the line number, so the link resolves whatever the working directory is. Do not percent-encode PATH, a plain / needs no escape. Keep DISPLAY short, the workspace-relative path:line. Example: [src/app.ts:42](https://openloc.invalid/o?p=/home/me/proj/src/app.ts:42)"
  }
}
JSON
