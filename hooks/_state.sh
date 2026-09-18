#!/usr/bin/env bash
# Collab MCP — shared state resolution, sourced by the other hooks.
#
# Agents sharing a repository share its working directory, so a single set of
# .collab-* files would let one agent wipe another's room membership and read
# cursor. Every file is therefore scoped to the pane that owns it.
#
# Sets PANE, ROOM_FILE, NAME_FILE, LAST_ID_FILE, HERDR_FILE, and on success
# ROOM, NAME, LAST_ID. Returns non-zero when this pane is not in a room.

collab_herdr_address() {
  python3 - "$1" "$2" <<'PY'
import hashlib
import re
import sys

address = re.sub(r"[^a-z0-9_-]+", "-", f"{sys.argv[1]}-{sys.argv[2]}".lower())
if not address or not address[0].isalpha():
    address = f"agent-{address}"
if len(address) > 32:
    address = f"{address[:23]}-{hashlib.sha256(address.encode()).hexdigest()[:8]}"
print(address)
PY
}

SESSION_ID=""
if [ ! -t 0 ]; then
  HOOK_INPUT=$(cat 2>/dev/null)
  SESSION_ID=$(printf '%s' "$HOOK_INPUT" | python3 -c '
import json
import sys

try:
    value = json.load(sys.stdin).get("session_id", "")
except Exception:
    value = ""
print(value if isinstance(value, str) else "")
' 2>/dev/null)
fi

STATE_OWNER=${HERDR_PANE_ID:-${SESSION_ID:-solo}}
PANE=$(printf '%s' "$STATE_OWNER" | tr -c 'a-zA-Z0-9_-' '-')
ROOM_FILE=".collab-room-$PANE"
NAME_FILE=".collab-name-$PANE"
LAST_ID_FILE=".collab-last-id-$PANE"
HERDR_FILE=".collab-herdr-$PANE"

# Unscoped files left by an older session are deliberately ignored rather than
# adopted: nothing in them says which pane wrote them, so adopting one would
# reintroduce exactly the theft this scoping exists to prevent. Such a session
# stops receiving notifications until it rejoins under its own pane.
[ -f "$ROOM_FILE" ] || return 1

ROOM=$(cat "$ROOM_FILE" 2>/dev/null)
NAME=$(cat "$NAME_FILE" 2>/dev/null)
LAST_ID=$(cat "$LAST_ID_FILE" 2>/dev/null || echo 0)

[ -n "$ROOM" ] && [ -n "$NAME" ]
