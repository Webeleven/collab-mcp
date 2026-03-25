#!/usr/bin/env bash
# Collab MCP — PostToolUse hook
# Checks for unread messages mentioning @name or @all.
# Returns additionalContext with messages if found. Silent otherwise.

if [ ! -f .collab-room ]; then
  exit 0
fi

ROOM=$(cat .collab-room 2>/dev/null)
NAME=$(cat .collab-name 2>/dev/null)
LAST_ID=$(cat .collab-last-id 2>/dev/null || echo 0)

if [ -z "$ROOM" ] || [ -z "$NAME" ]; then
  exit 0
fi

# Use collab check — capture stdout only, discard stderr
OUTPUT=$(collab check "$ROOM" "$NAME" "$LAST_ID" 2>/dev/null)
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  # No new messages
  exit 0
fi

# Has messages — return as additionalContext instead of blocking
CONTEXT_ESCAPED=$(echo "$OUTPUT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")

cat << ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": ${CONTEXT_ESCAPED}
  }
}
ENDJSON

exit 0
