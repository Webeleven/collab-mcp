#!/usr/bin/env bash
# Collab MCP — UserPromptSubmit hook
# Checks for unread messages and prepends them to the user's prompt.
# MUST exit 0 — exit 2 blocks the user's prompt entirely.

if [ ! -f .collab-room ]; then
  exit 0
fi

ROOM=$(cat .collab-room 2>/dev/null)
NAME=$(cat .collab-name 2>/dev/null)
LAST_ID=$(cat .collab-last-id 2>/dev/null || echo 0)

if [ -z "$ROOM" ] || [ -z "$NAME" ]; then
  exit 0
fi

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
