// Session and conversation management
import { getDB } from './store.mjs';
import { resetSequenceCache } from './transcript.mjs';
import { randomUUID } from 'node:crypto';

let _conversationId = null;
let _sessionId = null;

export function getConversationId() { return _conversationId; }
export function getSessionId() { return _sessionId; }

export function createOrResumeConversation(projectDir) {
  const db = getDB();
  // Try to resume the most recent conversation
  const existing = db.prepare(
    "SELECT id FROM conversations ORDER BY last_active DESC LIMIT 1"
  ).get();
  if (existing) {
    _conversationId = existing.id;
    db.prepare(
      "UPDATE conversations SET last_active = datetime('now') WHERE id = ?"
    ).run(_conversationId);
    return _conversationId;
  }
  // Create new
  _conversationId = randomUUID();
  db.prepare(
    `INSERT INTO conversations(id, project_dir, phase)
     VALUES (?, ?, 'idle')`
  ).run(_conversationId, projectDir || process.cwd());
  return _conversationId;
}

export function createSession(conversationId) {
  const db = getDB();
  conversationId = conversationId || _conversationId;
  _sessionId = randomUUID();
  db.prepare(
    `INSERT INTO sessions(session_id, conversation_id)
     VALUES (?, ?)`
  ).run(_sessionId, conversationId);
  resetSequenceCache(_sessionId);
  return _sessionId;
}

export function newSession() {
  // Create new session for same conversation
  return createSession(_conversationId);
}

export function getPhase() {
  const db = getDB();
  const row = db.prepare(
    "SELECT phase FROM conversations WHERE id = ?"
  ).get(_conversationId);
  return row ? row.phase : 'idle';
}
