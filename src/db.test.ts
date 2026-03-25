import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import {
  setDbPath,
  resetDb,
  createRoom,
  listRooms,
  joinRoom,
  listParticipants,
  sendMessage,
  getMessages,
} from "./db.js";

let tmpDir: string;

beforeEach(() => {
  tmpDir = mkdtempSync(join(tmpdir(), "collab-test-"));
  setDbPath(join(tmpDir, "test.db"));
});

afterEach(() => {
  resetDb();
  rmSync(tmpDir, { recursive: true, force: true });
});

describe("rooms", () => {
  it("createRoom and listRooms", () => {
    createRoom("room-1", "Test room");
    createRoom("room-2");

    const rooms = listRooms() as Array<{
      id: string;
      description: string | null;
      participant_count: number;
      message_count: number;
    }>;
    assert.equal(rooms.length, 2);

    const r1 = rooms.find((r) => r.id === "room-1")!;
    assert.equal(r1.description, "Test room");
    assert.equal(r1.participant_count, 0);
    assert.equal(r1.message_count, 0);

    const r2 = rooms.find((r) => r.id === "room-2")!;
    assert.equal(r2.description, null);
  });

  it("createRoom is idempotent", () => {
    createRoom("room-1", "First");
    createRoom("room-1", "Second");

    const rooms = listRooms() as Array<{ id: string; description: string }>;
    assert.equal(rooms.length, 1);
    assert.equal(rooms[0].description, "First"); // INSERT OR IGNORE keeps first
  });
});

describe("participants", () => {
  it("joinRoom auto-creates room", () => {
    joinRoom("auto-room", "backend");

    const rooms = listRooms() as Array<{ id: string }>;
    assert.equal(rooms.length, 1);
    assert.equal(rooms[0].id, "auto-room");

    const participants = listParticipants("auto-room") as Array<{
      name: string;
    }>;
    assert.equal(participants.length, 1);
    assert.equal(participants[0].name, "backend");
  });

  it("joinRoom is idempotent", () => {
    joinRoom("room-1", "backend");
    joinRoom("room-1", "backend");

    const participants = listParticipants("room-1") as Array<{
      name: string;
    }>;
    assert.equal(participants.length, 1);
  });

  it("multiple participants", () => {
    joinRoom("room-1", "backend");
    joinRoom("room-1", "audit");
    joinRoom("room-1", "andre");

    const participants = listParticipants("room-1") as Array<{
      name: string;
    }>;
    assert.equal(participants.length, 3);
    const names = participants.map((p) => p.name);
    assert.ok(names.includes("backend"));
    assert.ok(names.includes("audit"));
    assert.ok(names.includes("andre"));
  });

  it("listParticipants on nonexistent room returns empty", () => {
    const participants = listParticipants("nope");
    assert.equal(participants.length, 0);
  });
});

describe("messages", () => {
  it("sendMessage auto-creates room and joins sender", () => {
    const id = sendMessage("room-1", "backend", "Hello");

    assert.equal(id, 1);

    const rooms = listRooms() as Array<{ id: string; message_count: number }>;
    assert.equal(rooms.length, 1);
    assert.equal(rooms[0].message_count, 1);

    const participants = listParticipants("room-1") as Array<{
      name: string;
    }>;
    assert.equal(participants.length, 1);
    assert.equal(participants[0].name, "backend");
  });

  it("getMessages returns messages in chronological order", () => {
    sendMessage("room-1", "backend", "First");
    sendMessage("room-1", "audit", "Second");
    sendMessage("room-1", "andre", "Third");

    const messages = getMessages("room-1") as Array<{
      id: number;
      sender: string;
      content: string;
    }>;
    assert.equal(messages.length, 3);
    assert.equal(messages[0].content, "First");
    assert.equal(messages[1].content, "Second");
    assert.equal(messages[2].content, "Third");
  });

  it("getMessages with since_id returns only newer messages", () => {
    const id1 = sendMessage("room-1", "backend", "First");
    sendMessage("room-1", "audit", "Second");
    sendMessage("room-1", "andre", "Third");

    const messages = getMessages("room-1", id1 as number) as Array<{
      id: number;
      content: string;
    }>;
    assert.equal(messages.length, 2);
    assert.equal(messages[0].content, "Second");
    assert.equal(messages[1].content, "Third");
  });

  it("getMessages with limit", () => {
    sendMessage("room-1", "backend", "1");
    sendMessage("room-1", "backend", "2");
    sendMessage("room-1", "backend", "3");
    sendMessage("room-1", "backend", "4");
    sendMessage("room-1", "backend", "5");

    const messages = getMessages("room-1", undefined, 3) as Array<{
      content: string;
    }>;
    assert.equal(messages.length, 3);
    // Without since_id, returns last N in chronological order
    assert.equal(messages[0].content, "3");
    assert.equal(messages[1].content, "4");
    assert.equal(messages[2].content, "5");
  });

  it("getMessages with since_id and limit", () => {
    sendMessage("room-1", "backend", "1");
    const id2 = sendMessage("room-1", "backend", "2");
    sendMessage("room-1", "backend", "3");
    sendMessage("room-1", "backend", "4");
    sendMessage("room-1", "backend", "5");

    const messages = getMessages("room-1", id2 as number, 2) as Array<{
      content: string;
    }>;
    assert.equal(messages.length, 2);
    assert.equal(messages[0].content, "3");
    assert.equal(messages[1].content, "4");
  });

  it("getMessages on empty room returns empty", () => {
    createRoom("empty");
    const messages = getMessages("empty");
    assert.equal(messages.length, 0);
  });

  it("getMessages with since_id and no new messages returns empty", () => {
    const id = sendMessage("room-1", "backend", "Only one");
    const messages = getMessages("room-1", id as number);
    assert.equal(messages.length, 0);
  });

  it("messages are isolated per room", () => {
    sendMessage("room-a", "backend", "In room A");
    sendMessage("room-b", "audit", "In room B");

    const msgsA = getMessages("room-a") as Array<{ content: string }>;
    const msgsB = getMessages("room-b") as Array<{ content: string }>;

    assert.equal(msgsA.length, 1);
    assert.equal(msgsA[0].content, "In room A");
    assert.equal(msgsB.length, 1);
    assert.equal(msgsB[0].content, "In room B");
  });
});

describe("listRooms aggregation", () => {
  it("shows correct participant and message counts", () => {
    joinRoom("room-1", "backend");
    joinRoom("room-1", "audit");
    sendMessage("room-1", "backend", "msg1");
    sendMessage("room-1", "audit", "msg2");
    sendMessage("room-1", "backend", "msg3");

    const rooms = listRooms() as Array<{
      id: string;
      participant_count: number;
      message_count: number;
    }>;
    assert.equal(rooms.length, 1);
    assert.equal(rooms[0].participant_count, 2);
    assert.equal(rooms[0].message_count, 3);
  });
});
