#!/usr/bin/env bash
# Collab MCP — PostToolUse hook
# Checks for unread messages mentioning @name or @all.
# Returns additionalContext with messages if found. Silent otherwise.

. "$(dirname "$0")/_state.sh" || exit 0

# Claim the Herdr address <name>-<room> so peers resolve this session by lookup
# instead of guessing from cwd, which cannot separate two agents in one repo.
if [ -n "$HERDR_ENV" ] && [ -n "$HERDR_PANE_ID" ] && command -v herdr >/dev/null 2>&1; then
  ADDRESS=$(collab_herdr_address "$NAME" "$ROOM")
  CLAIMED=$(cat "$HERDR_FILE" 2>/dev/null)
  # Record failures too: the name is globally unique, so a peer already holding
  # this role in this room is a real conflict, not something to retry forever.
  if [ "$CLAIMED" != "$ADDRESS" ] && [ "$CLAIMED" != "taken:$ADDRESS" ]; then
    if herdr agent rename "$HERDR_PANE_ID" "$ADDRESS" >/dev/null 2>&1; then
      printf '%s' "$ADDRESS" > "$HERDR_FILE"
    else
      printf 'taken:%s' "$ADDRESS" > "$HERDR_FILE"
    fi
  fi
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
