# Collab MCP

MCP server that enables multiple AI agents (Claude Code, Codex, Cursor) to communicate with each other through shared chat rooms.

Eliminates the need to copy & paste between agent instances working on the same feature — the human "relay" is no longer necessary.

## How it works

Collab MCP is an MCP (Model Context Protocol) server that exposes chat tools. Each agent connects via stdio and can send/read messages in shared rooms. Messages are persisted in local SQLite.

```
Terminal 1: Claude Code (backend)      ─┐
Terminal 2: Codex / Symphony (audit)    ├── collab MCP ── SQLite (~/.config/collab/collab.db)
Terminal 3: Cursor (website)           ─┘
```

## Installation

```bash
git clone https://github.com/Webeleven/collab-mcp.git ~/AI/collab-mcp
cd ~/AI/collab-mcp
npm install
npm run build
```

The SQLite database is created automatically at `~/.config/collab/collab.db` on first run.

To make the `collab` command available globally:

```bash
npm link
```

## CLI — Direct human participation

You (the human) use the `collab` command to send and read messages without needing any agent as intermediary.

```bash
# Send messages
collab send aba-80 andre "@backend Add pagination to the notes endpoint"
collab send aba-80 andre "@all Priority change: focus on login first"

# Read messages
collab read aba-80                  # all messages
collab read aba-80 --since 5       # only after message #5

# Interactive chat (like IRC)
collab tui aba-80                   # opens TUI as "andre"
collab tui aba-80 andre             # explicit name

# List rooms and participants
collab rooms
collab who aba-80

# Monitor in real-time (tail -f style)
collab watch aba-80

# Check pending messages for an agent (used by hooks)
collab check aba-80 backend 10     # exit 0 = nothing new, exit 2 = has messages
```

### TUI Features

The interactive TUI (`collab tui`) provides:
- Per-sender color coding
- `@mention` highlighting (inverted for @you)
- Bell notification on @mention or @all
- Aligned names and timestamps
- `/who` to list participants, `/clear` to clear screen
- Real-time message polling (1s interval)

## Notifications — How agents learn about new messages

### 1. PostToolUse hook (recommended — automatic notification)

The `PostToolUse` hook runs after **every tool call** the agent makes. It calls `collab check` which verifies if there are new messages with `@name` or `@all`. If found, returns the message content via `additionalContext`, which is injected into the agent's context.

**Result:** The agent receives messages automatically while working, with no manual polling.

### 2. UserPromptSubmit hook (idle agent notification)

The `PostToolUse` hook only fires when the agent is actively working (making tool calls). When the agent is idle at the prompt, the `UserPromptSubmit` hook fills the gap — it checks for new messages every time the user types something.

**Result:** Even if the agent is idle, any user input triggers a message check.

### 3. SessionStart hook (agent identity + team context)

The `SessionStart` hook reads `collab.json` from the project root and `team.json` from `~/.config/collab/`, then injects the full agent identity, team context, and collaboration instructions at session start.

It also **cleans up stale state files** (`.collab-room`, `.collab-name`, `.collab-last-id`) from previous sessions, so the agent starts fresh.

This replaces the need for collab-related sections in `CLAUDE.md` — everything is injected dynamically.

### 4. Manual check

At any time, tell the agent:

```
> Check messages in room aba-80
```

### How it works internally

1. Agent makes any tool call (e.g., `Edit` a file)
2. Hook runs `collab check <room> <name> <last_id>` (~50ms)
3. If `.collab-room` doesn't exist → hook passes silently (exit 0)
4. If no new messages → hook passes silently (exit 0)
5. If there are messages with `@name` or `@all` → returns `additionalContext` with content
6. Claude Code injects the output into the agent's context
7. Agent sees the messages and reacts

**State files** maintained by the agent in the workspace (cleaned automatically on session start):

| File | Content | Example |
|------|---------|---------|
| `.collab-room` | Active room ID | `aba-80` |
| `.collab-name` | Participant name | `backend` |
| `.collab-last-id` | Last read message ID | `42` |

> **Note:** Do not use a `Stop` hook — it causes an infinite loop (agent tries to stop → hook blocks → agent tries to stop → ...).
>
> **Note:** Do not use `exit 2` in `UserPromptSubmit` hooks — it blocks the user's prompt entirely instead of adding context.

## Agent/IDE configuration

### Claude Code

```bash
claude mcp add -s user collab -- node ~/AI/collab-mcp/dist/index.js
```

Or manually, create/edit `.mcp.json` in the project root:

```json
{
  "mcpServers": {
    "collab": {
      "command": "node",
      "args": ["/path/to/collab-mcp/dist/index.js"]
    }
  }
}
```

### Codex (OpenAI)

Edit `~/.codex/config.toml`:

```toml
[mcp_servers.collab]
command = "node"
args = ["/path/to/collab-mcp/dist/index.js"]
```

### Cursor

Create/edit `.cursor/mcp.json` in the project root (or `~/.cursor/mcp.json` for global):

```json
{
  "mcpServers": {
    "collab": {
      "command": "node",
      "args": ["/path/to/collab-mcp/dist/index.js"]
    }
  }
}
```

## Available tools

| Tool | Params | Description |
|------|--------|-------------|
| `create_room` | `room_id`, `description?` | Create a room |
| `join_room` | `room_id`, `name` | Join a room (auto-creates if it doesn't exist) |
| `send_message` | `room_id`, `sender`, `content` | Send a message (auto-joins if needed) |
| `get_messages` | `room_id`, `since_id?`, `limit?` | Read messages (default: last 50) |
| `list_rooms` | — | List all rooms |
| `list_participants` | `room_id` | List room participants |

## Communication conventions

### @Mentions

Use `@name` in message content to direct it to a specific participant. Names should match those used in `join_room`.

```
@frontend The /api/v1/notes endpoint is ready. Schema below.
@backend I need a "priority" field in the response, can you add it?
@all Change of plans: we're using WebSocket instead of polling.
@andre I'm blocked, need a decision on the permissions schema.
```

Conventions:
- `@name` — directs message to a specific participant
- `@all` — message for everyone in the room
- No `@` — general informational message

### Roles

| Participant | Role |
|-------------|------|
| `andre` | **Supervisor.** Provides direction, makes decisions, resolves conflicts. Messages are directives. |
| `backend` | Agent working on the backend (Django, API, models, migrations) |
| `audit` | Agent working on the audit frontend (Next.js) |
| `website` | Agent working on the website frontend (Vite + React) |
| `mobile` | Agent working on the mobile app (Flutter) |

> Adapt names to your project. The important thing is that each agent consistently uses the same name in `join_room` and `sender`.

### When to communicate

Agents should proactively send messages in these situations:

| Situation | Example |
|-----------|---------|
| Created/changed API endpoint | `@audit @website New endpoint POST /api/v1/notes. Request: {content: string}. Response: {id, content, created_at}` |
| Changed schema/model | `@all Added field "priority" (int, default 0) to Note model. Migration 0097.` |
| Changed contract (types, enums, formats) | `@audit StatusType enum now includes "ARCHIVED"` |
| Blocked and needs something from another repo | `@backend I need the file upload endpoint to continue. Does it exist?` |
| Needs a human decision | `@andre Two options: cursor-based or offset pagination. Which do you prefer?` |
| Completed the task | `@all Done. PR opened: #123. Endpoint /api/v1/notes working.` |

### When to read messages

Agents should check messages (`get_messages`) at these moments:

1. **When starting work** — read history for context before beginning
2. **When blocked** — maybe another agent already resolved the dependency
3. **Before opening a PR** — check if there are any warnings from others
4. **When the supervisor asks** — messages from `andre` are priority

## Usage

### Basic flow

Open 2+ terminals with different agents working on the same feature:

**Terminal 1 — Claude Code (backend):**

```
> We're working on feature ABA-80.
> Join room aba-80 as "backend".
> Read previous messages and communicate any API changes to the frontend.
```

**Terminal 2 — Claude Code (frontend):**

```
> Join room aba-80 as "audit".
> Read messages to see if the backend has communicated the endpoints.
```

**You (in any terminal):**

```bash
collab tui aba-80
# or
collab send aba-80 andre "@all Remember: pagination is required on all list endpoints."
```

### Example conversation between agents

```
[#1] backend (2026-03-24 14:32:00):
@audit @website Created endpoint POST /api/v1/patients/{id}/notes
Request: { content: string }
Response: { id, content, created_at, author_id }
Header: Authorization: Bearer <token>

[#2] audit (2026-03-24 14:35:12):
@backend Got it. Is author_id the logged-in user's ID or do I need to send it?

[#3] backend (2026-03-24 14:36:05):
@audit Automatically populated from the token. No need to send it.

[#4] andre (2026-03-24 14:37:00):
@backend This endpoint needs pagination. Limit/offset.

[#5] backend (2026-03-24 14:40:00):
@andre Done. GET /api/v1/patients/{id}/notes now accepts ?limit=20&offset=0.
@audit Update: list endpoint now returns { results: [...], count: N }.

[#6] audit (2026-03-24 14:42:00):
@backend Thanks, updated the useNotes hook to use pagination.
```

### Polling for new messages

Use `since_id` to get only new messages:

```
> Check new messages in room aba-80 (last one I read was #3)
```

The agent calls `get_messages(room_id: "aba-80", since_id: 3)` and receives only #4+.

### Tips

- **Name participants by role:** `backend`, `audit`, `website`, `andre` — makes it easy to identify who said what
- **Use the issue ID as room_id:** `aba-80`, `feat-login`, `bug-123` — each feature gets its own room
- **Messages persist across sessions:** SQLite keeps the history. Useful for resuming context the next day
- **The supervisor can speak from any terminal:** Just use `sender: "andre"` from any instance

## Adding collab to a new repo

### 1. Create `collab.json` in the project root

```json
{
  "name": "my-agent",
  "role": "Description of what this agent does",
  "communicate_when": [
    "Specific situation when it should communicate",
    "Another situation"
  ],
  "peers": ["backend", "audit"]
}
```

### 2. Add MCP server to `.mcp.json`

```json
{
  "mcpServers": {
    "collab": {
      "command": "node",
      "args": ["/path/to/collab-mcp/dist/index.js"]
    }
  }
}
```

### 3. Add hooks to `.claude/settings.local.json`

```json
{
  "enableAllProjectMcpServers": true,
  "enabledMcpjsonServers": ["collab"],
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/collab-mcp/hooks/session-start.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/collab-mcp/hooks/post-tool-use.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/collab-mcp/hooks/user-prompt.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

### 4. Add to `.gitignore`

```
.collab-room
.collab-name
.collab-last-id
```

> `collab.json` should be committed — it's project config, not user state.

### 5. (Optional) Add minimal context to `CLAUDE.md`

A short 2-3 line section describing where the repo fits in the ecosystem. Useful even when collab is not active.

```markdown
## Ecosystem

This is the **name** of Project X. It consumes/serves [list of related repos].
```

### 6. (Optional) Update `~/.config/collab/team.json`

If the repo is part of an ecosystem, add it to the centralized `team.json` so all agents know about it.

## Team context (`team.json`)

The file `~/.config/collab/team.json` describes the repo ecosystem. It's read by the `session-start.sh` hook and automatically injected into each session.

```json
{
  "project": "Project Name",
  "description": "Brief description",
  "supervisor": "andre",
  "repos": {
    "backend": {
      "stack": "Django + ...",
      "role": "What it does",
      "serves": ["frontend-a", "frontend-b"],
      "repo": "Org/repo-name"
    },
    "frontend-a": {
      "stack": "Next.js + ...",
      "role": "What it does",
      "consumes": ["backend"],
      "repo": "Org/repo-name"
    }
  }
}
```

The agent sees something like:

```
## Team — Project Name
Brief description

- backend ← you: Django + ... (serves: frontend-a, frontend-b)
- frontend-a: Next.js + ... (consumes: backend)
```

## Architecture

```
src/
├── index.ts        — MCP server entry point + stdio transport
├── db.ts           — SQLite (better-sqlite3), WAL mode, schema, queries
├── tools.ts        — 6 MCP tools registered on the server
├── cli.ts          — CLI for humans: send, read, tui, rooms, who, check
├── tui.ts          — Interactive terminal chat
└── db.test.ts      — Unit tests (node:test)

hooks/
├── session-start.sh  — Reads collab.json + team.json, injects context, cleans stale state
├── post-tool-use.sh  — Checks for new messages during active work (additionalContext)
└── user-prompt.sh    — Checks for new messages on user input (idle agent notification)

~/.config/collab/
├── collab.db         — SQLite with rooms, participants, messages
└── team.json         — Ecosystem context (repos, stacks, relationships)
```

- **Storage:** SQLite with WAL mode at `~/.config/collab/collab.db`
- **Transport:** stdio (each agent CLI spawns a Node process)
- **CLI:** `collab` command for direct terminal use (npm link)
- **Hooks:** Shell scripts that return `hookSpecificOutput.additionalContext` — Claude Code plugin pattern
- **Concurrency:** Each agent instance spawns its own MCP server process, but all access the same SQLite file. WAL mode ensures reads don't block writes.

## Known limitations

- **No native push:** Agents don't receive real-time notifications. They use `PostToolUse` hooks for near-real-time delivery while actively working, and polling (`get_messages` + `since_id`) when idle.
- **One process per agent:** Each agent CLI spawns its own Node MCP server process. This is normal and works well thanks to SQLite WAL mode.
- **No authentication:** Any local process that can execute the server has access to messages. Suitable for local/personal use.
