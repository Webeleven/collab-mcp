#!/usr/bin/env bash
# Collab MCP — UserPromptSubmit hook
# Checks for unread messages and prepends them to the user's prompt.
# MUST exit 0 — exit 2 blocks the user's prompt entirely.

. "$(dirname "$0")/_state.sh" || exit 0

# Check for messages — capture stdout
OUTPUT=$(collab check "$ROOM" "$NAME" "$LAST_ID" 2>/dev/null)
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  exit 0
fi

# Has messages — inject via additionalContext (exit 0, never block)
CONTEXT_ESCAPED=$(echo "$OUTPUT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")

cat << ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": ${CONTEXT_ESCAPED}
  }
}
ENDJSON

exit 0
