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
    "additionalContext": "When you reference a source location, render it as a markdown link whose display text and p value are the SAME string: [PATH:LINE](https://openloc.invalid/o?p=PATH:LINE). PATH is the path as it resolves from the current working directory, or an absolute path. Spell it exactly as it appears in tool output: do not percent-encode it, do not abbreviate it, and do not shorten the display text. Example: [apps/web/src/app.ts:42](https://openloc.invalid/o?p=apps/web/src/app.ts:42)"
  }
}
JSON
