import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  createRoom,
  joinRoom,
  sendMessage,
  getMessages,
  listRooms,
  listParticipants,
} from "./db.js";

export function registerTools(server: McpServer) {
  server.tool(
    "create_room",
    "Create a collaboration room for agents to communicate",
    {
      room_id: z.string().describe("Unique room identifier (e.g. 'aba-80', 'feature-xyz')"),
      description: z.string().optional().describe("What this room is about"),
    },
    async ({ room_id, description }) => {
      createRoom(room_id, description);
      return {
        content: [
          {
            type: "text" as const,
            text: `Room "${room_id}" created.${description ? ` Description: ${description}` : ""}`,
          },
        ],
      };
    }
  );

  server.tool(
    "join_room",
    "Join a collaboration room as a named participant. Auto-creates the room if it doesn't exist.",
    {
      room_id: z.string().describe("Room to join"),
      name: z.string().describe("Your identity in this room (e.g. 'backend', 'frontend', 'andre')"),
    },
    async ({ room_id, name }) => {
      joinRoom(room_id, name);
      const participants = listParticipants(room_id);
      const names = (participants as Array<{ name: string }>).map((p) => p.name);
      return {
        content: [
          {
            type: "text" as const,
            text: `Joined room "${room_id}" as "${name}". Participants: ${names.join(", ")}`,
          },
        ],
      };
    }
  );

  server.tool(
    "send_message",
    "Send a message to a collaboration room. Auto-joins the room if not already a participant.",
    {
      room_id: z.string().describe("Room to send message to"),
      sender: z.string().describe("Your identity (e.g. 'backend', 'frontend')"),
      content: z.string().describe("Message content"),
    },
    async ({ room_id, sender, content }) => {
      const id = sendMessage(room_id, sender, content);
      return {
        content: [
          {
            type: "text" as const,
            text: `Message #${id} sent to room "${room_id}".`,
          },
        ],
      };
    }
  );

  server.tool(
    "get_messages",
    "Read messages from a collaboration room. Use since_id to get only new messages since your last read.",
    {
      room_id: z.string().describe("Room to read messages from"),
      since_id: z.number().optional().describe("Only return messages after this ID (for polling new messages)"),
      limit: z.number().optional().default(50).describe("Max messages to return (default 50)"),
    },
    async ({ room_id, since_id, limit }) => {
      const messages = getMessages(room_id, since_id, limit) as Array<{
        id: number;
        sender: string;
        content: string;
        created_at: string;
      }>;

      if (messages.length === 0) {
        return {
          content: [
            {
              type: "text" as const,
              text: since_id
                ? `No new messages in room "${room_id}" since #${since_id}.`
                : `No messages in room "${room_id}".`,
            },
          ],
        };
      }

      const formatted = messages
        .map((m) => `[#${m.id}] ${m.sender} (${m.created_at}):\n${m.content}`)
        .join("\n\n");

      return {
        content: [
          {
            type: "text" as const,
            text: `${messages.length} message(s) in room "${room_id}":\n\n${formatted}`,
          },
        ],
      };
    }
  );

  server.tool(
    "list_rooms",
    "List all collaboration rooms",
    {},
    async () => {
      const rooms = listRooms() as Array<{
        id: string;
        description: string | null;
        created_at: string;
        participant_count: number;
        message_count: number;
      }>;

      if (rooms.length === 0) {
        return {
          content: [{ type: "text" as const, text: "No rooms yet." }],
        };
      }

      const formatted = rooms
        .map(
          (r) =>
            `- ${r.id}${r.description ? ` — ${r.description}` : ""} (${r.participant_count} participants, ${r.message_count} messages)`
        )
        .join("\n");

      return {
        content: [{ type: "text" as const, text: formatted }],
      };
    }
  );

  server.tool(
    "list_participants",
    "List participants in a collaboration room",
    {
      room_id: z.string().describe("Room to list participants for"),
    },
    async ({ room_id }) => {
      const participants = listParticipants(room_id) as Array<{
        name: string;
        joined_at: string;
      }>;

      if (participants.length === 0) {
        return {
          content: [
            {
              type: "text" as const,
              text: `No participants in room "${room_id}" (room may not exist).`,
            },
          ],
        };
      }

      const formatted = participants
        .map((p) => `- ${p.name} (joined ${p.joined_at})`)
        .join("\n");

      return {
        content: [
          {
            type: "text" as const,
            text: `Participants in "${room_id}":\n${formatted}`,
          },
        ],
      };
    }
  );
}
