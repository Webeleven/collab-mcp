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
    RENAME_OUTPUT=$(herdr agent rename "$HERDR_PANE_ID" "$ADDRESS" 2>&1)
    if [ $? -eq 0 ]; then
      printf '%s' "$ADDRESS" > "$HERDR_FILE"
    elif printf '%s' "$RENAME_OUTPUT" | "$COLLAB_PYTHON" -c '
import sys

raise SystemExit(0 if "agent_name_taken" in sys.stdin.read() else 1)
'; then
      printf 'taken:%s' "$ADDRESS" > "$HERDR_FILE"
    fi
  fi
fi

# A room post that asks a peer for something only reaches a live session with a
# wake; a post without one is the most common reason a reply never comes.
REMINDER=""
case "$HOOK_INPUT" in
  *mcp__collab__send_message*)
    REMINDER=$(printf '%s' "$HOOK_INPUT" | "$COLLAB_PYTHON" -c '
import json
import re
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if data.get("tool_name") != "mcp__collab__send_message":
    raise SystemExit(0)
tool_input = data.get("tool_input") or {}
sender = tool_input.get("sender") or ""
mentions = re.findall(r"@([a-z][a-z0-9_-]*)", tool_input.get("content") or "")
targets = sorted({m for m in mentions if m not in ("andre", "all", sender)})
if targets:
    roles = ", ".join("@" + t for t in targets)
    print(
        f"[collab] Você postou para {roles}. Se a mensagem pede ação ou resposta, "
        "acorde o destinatário agora pelo skill peer-notify (SendMessage nativo "
        "para Claude Code); se não pede nada, registre `room only`."
    )
' 2>/dev/null)
    ;;
esac

# Use collab check — capture stdout only, discard stderr
OUTPUT=$(collab check "$ROOM" "$NAME" "$LAST_ID" 2>/dev/null)
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  # No new messages
  OUTPUT=""
else
  collab_advance_cursor "$OUTPUT"
  OUTPUT=$(collab_strip_cursor_line "$OUTPUT")
fi

OUTPUT=$(printf '%s\n%s' "$REMINDER" "$OUTPUT" | sed '/./,$!d')
[ -n "$OUTPUT" ] || exit 0

# Return as additionalContext instead of blocking
CONTEXT_ESCAPED=$(echo "$OUTPUT" | "$COLLAB_PYTHON" -c "import sys,json; print(json.dumps(sys.stdin.read()))")

cat << ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": ${CONTEXT_ESCAPED}
  }
}
ENDJSON

exit 0
