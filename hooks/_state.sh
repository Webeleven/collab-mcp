#!/usr/bin/env bash
# Collab MCP — shared state resolution, sourced by the other hooks.
#
# Agents sharing a repository share its working directory, so a single set of
# .collab-* files would let one agent wipe another's room membership and read
# cursor. Every file is therefore scoped to the pane that owns it.
#
# Sets COLLAB_PYTHON, PANE, ROOM_FILE, NAME_FILE, LAST_ID_FILE, HERDR_FILE, and on success
# ROOM, NAME, LAST_ID. Returns non-zero when this pane is not in a room.

# The hooks run on every prompt and tool call, and a python3 that resolves to a
# version-manager shim costs ~10x the real interpreter. Prefer the system one;
# on macOS it only works once the developer tools are installed.
if [ -z "$COLLAB_PYTHON" ]; then
  COLLAB_PYTHON=python3
  if [ -x /usr/bin/python3 ]; then
    case "$OSTYPE" in
      darwin*)
        if [ -d /Library/Developer/CommandLineTools ] || [ -d /Applications/Xcode.app ]; then
          COLLAB_PYTHON=/usr/bin/python3
        fi
        ;;
      *) COLLAB_PYTHON=/usr/bin/python3 ;;
    esac
  fi
fi

collab_herdr_address() {
  "$COLLAB_PYTHON" - "$1" "$2" <<'PY'
import hashlib
import json
import re
import sys

name, room = sys.argv[1:3]
slug = re.sub(r"[^a-z0-9_-]+", "-", f"{name}-{room}".lower())
if not slug or not slug[0].isalpha():
    slug = f"agent-{slug}"
identity = json.dumps([name, room], ensure_ascii=False, separators=(",", ":"))
digest = hashlib.sha256(identity.encode()).hexdigest()[:8]
print(f"{slug[:23]}-{digest}")
PY
}

# Runs on every hook, so it stays in shell: python3 can be a slow shim. The
# output names the state files and must not change — hooks.test.ts pins it.
collab_state_suffix() {
  local slug digest
  slug=$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C sed -E 's/[^a-z0-9_-]+/-/g')
  digest=$(printf '%s' "$1" | shasum -a 256)
  slug=${slug:-state}
  printf '%s-%s\n' "${slug:0:40}" "${digest:0:8}"
}

SESSION_ID=""
if [ ! -t 0 ]; then
  HOOK_INPUT=$(cat 2>/dev/null)
  # The session id only matters as a fallback owner; skip the parse otherwise.
  [ -n "$HERDR_PANE_ID" ] || SESSION_ID=$(printf '%s' "$HOOK_INPUT" | "$COLLAB_PYTHON" -c '
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
PANE=$(collab_state_suffix "$STATE_OWNER")
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
