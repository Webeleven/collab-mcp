import Database from "better-sqlite3";
import { appendFileSync, mkdirSync, renameSync, statSync } from "fs";
import { dirname, join } from "path";
import { homedir } from "os";

const DEFAULT_DB_PATH = join(homedir(), ".config", "collab", "collab.db");

let _db: Database.Database | null = null;
let _dbPath: string = DEFAULT_DB_PATH;

export function setDbPath(path: string) {
  if (_db) {
    _db.close();
    _db = null;
  }
  _dbPath = path;
}

export function resetDb() {
  if (_db) {
    _db.close();
    _db = null;
  }
  _dbPath = DEFAULT_DB_PATH;
}

export function getDb(): Database.Database {
  if (_db) return _db;

  mkdirSync(dirname(_dbPath), { recursive: true });

  _db = new Database(_dbPath);
  _db.pragma("journal_mode = WAL");
  _db.pragma("foreign_keys = ON");

  _db.exec(`
    CREATE TABLE IF NOT EXISTS rooms (
      id TEXT PRIMARY KEY,
      description TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS participants (
      room_id TEXT REFERENCES rooms(id) ON DELETE CASCADE,
      name TEXT,
      joined_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (room_id, name)
    );

    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      room_id TEXT REFERENCES rooms(id) ON DELETE CASCADE,
      sender TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );

    CREATE INDEX IF NOT EXISTS idx_messages_room_created
      ON messages(room_id, created_at);
  `);

  return _db;
}

// Room operations

export function createRoom(id: string, description?: string) {
  const db = getDb();
  db.prepare(
    "INSERT OR IGNORE INTO rooms (id, description) VALUES (?, ?)"
  ).run(id, description ?? null);
}

export function listRooms() {
  const db = getDb();
  return db
    .prepare(
      `SELECT r.id, r.description, r.created_at,
              (SELECT COUNT(*) FROM participants p WHERE p.room_id = r.id) as participant_count,
              (SELECT COUNT(*) FROM messages m WHERE m.room_id = r.id) as message_count
       FROM rooms r
       ORDER BY r.created_at DESC`
    )
    .all();
}

// Participant operations

export function joinRoom(roomId: string, name: string) {
  const db = getDb();
  // Auto-create room if it doesn't exist
  createRoom(roomId);
  db.prepare(
    "INSERT OR IGNORE INTO participants (room_id, name) VALUES (?, ?)"
  ).run(roomId, name);
}

export function listParticipants(roomId: string) {
  const db = getDb();
  return db
    .prepare(
      "SELECT name, joined_at FROM participants WHERE room_id = ? ORDER BY joined_at"
    )
    .all(roomId);
}

// Message operations

export function sendMessage(roomId: string, sender: string, content: string) {
  const db = getDb();
  // Auto-create room and join sender
  joinRoom(roomId, sender);
  const result = db
    .prepare(
      "INSERT INTO messages (room_id, sender, content) VALUES (?, ?, ?)"
    )
    .run(roomId, sender, content);
  return result.lastInsertRowid;
}

function queryMessages(
  db: Database.Database,
  roomId: string,
  sinceId?: number,
  limit: number = 50
) {
  if (sinceId) {
    return db
      .prepare(
        `SELECT id, sender, content, created_at
         FROM messages
         WHERE room_id = ? AND id > ?
         ORDER BY created_at ASC
         LIMIT ?`
      )
      .all(roomId, sinceId, limit);
  }
  return db
    .prepare(
      `SELECT id, sender, content, created_at
       FROM messages
       WHERE room_id = ?
       ORDER BY created_at DESC
       LIMIT ?`
    )
    .all(roomId, limit)
    .reverse();
}

export function getMessages(
  roomId: string,
  sinceId?: number,
  limit: number = 50
) {
  return queryMessages(getDb(), roomId, sinceId, limit);
}

// Read path for `collab check`, which runs inside prompt hooks with a hard
// timeout. It must fail cheap: a read-only connection with a short busy
// timeout, no journal_mode pragma and no DDL, so it never waits on a lock and
// never creates the database. Any failure reads as "no messages" — the next
// hook run retries — but is recorded, because both hooks go through here and
// a permanent failure would otherwise silence them without a trace.
const CHECK_LOG_MAX_BYTES = 256 * 1024;

export function checkErrorLogPath() {
  return join(dirname(_dbPath), "check-errors.log");
}

function logCheckError(err: unknown) {
  try {
    const path = checkErrorLogPath();
    try {
      if (statSync(path).size > CHECK_LOG_MAX_BYTES) {
        renameSync(path, `${path}.1`);
      }
    } catch {
      // no log yet
    }
    const code = (err as { code?: string })?.code ?? "ERROR";
    const message = err instanceof Error ? err.message : String(err);
    // No mkdir: a missing directory means collab was never used here.
    appendFileSync(
      path,
      `${new Date().toISOString()} pid=${process.pid} ${code} ${message} (${_dbPath})\n`
    );
  } catch {
    // logging must never fail the check
  }
}

export function peekMessages(
  roomId: string,
  sinceId?: number,
  limit: number = 50
) {
  let db: Database.Database | null = null;
  try {
    db = new Database(_dbPath, {
      readonly: true,
      fileMustExist: true,
      timeout: 300,
    });
    return queryMessages(db, roomId, sinceId, limit);
  } catch (err) {
    logCheckError(err);
    return [];
  } finally {
    try {
      db?.close();
    } catch {
      // nothing useful to do in a hook
    }
  }
}
