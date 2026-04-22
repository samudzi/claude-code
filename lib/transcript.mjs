// §4.5 Transcript — append/read transcript_entries
// Appendix C — payload_json shapes
import { getDB } from './store.mjs';
import { randomUUID } from 'node:crypto';

// Track next sequence per session
const _seqCounters = new Map();

export function nextSequence(sessionId) {
  const db = getDB();
  if (!_seqCounters.has(sessionId)) {
    const row = db.prepare(
      "SELECT MAX(sequence) as mx FROM transcript_entries WHERE session_id = ?"
    ).get(sessionId);
    _seqCounters.set(sessionId, row && row.mx !== null ? row.mx + 1 : 0);
  }
  const seq = _seqCounters.get(sessionId);
  _seqCounters.set(sessionId, seq + 1);
  return seq;
}

export function resetSequenceCache(sessionId) {
  _seqCounters.delete(sessionId);
}

// Appendix C payloads
export function appendUser(sessionId, text) {
  const db = getDB();
  const seq = nextSequence(sessionId);
  const payload = {
    _t: 'user',
    uuid: randomUUID(),
    content: [{ type: 'text', text }]
  };
  db.prepare(
    `INSERT INTO transcript_entries(session_id, sequence, entry_type, payload_json)
     VALUES (?, ?, 'user', ?)`
  ).run(sessionId, seq, JSON.stringify(payload));
  return payload;
}

export function appendAssistant(sessionId, content, toolCalls) {
  const db = getDB();
  const seq = nextSequence(sessionId);
  const blocks = [];
  if (content) {
    blocks.push({ type: 'text', text: content });
  }
  if (toolCalls) {
    for (const tc of toolCalls) {
      blocks.push({
        type: 'tool_use',
        id: tc.id,
        name: tc.function.name,
        input: JSON.parse(tc.function.arguments || '{}')
      });
    }
  }
  const payload = {
    _t: 'assistant',
    uuid: randomUUID(),
    content: blocks
  };
  db.prepare(
    `INSERT INTO transcript_entries(session_id, sequence, entry_type, payload_json)
     VALUES (?, ?, 'assistant', ?)`
  ).run(sessionId, seq, JSON.stringify(payload));
  return payload;
}

export function appendToolUse(sessionId, toolUseId, toolName, input) {
  const db = getDB();
  const seq = nextSequence(sessionId);
  const payload = {
    _t: 'tool_use',
    id: toolUseId,
    name: toolName,
    input
  };
  db.prepare(
    `INSERT INTO transcript_entries(session_id, sequence, entry_type, payload_json, tool_use_id)
     VALUES (?, ?, 'tool_use', ?, ?)`
  ).run(sessionId, seq, JSON.stringify(payload), toolUseId);
  return payload;
}

export function appendToolResult(sessionId, toolUseId, content, isError) {
  const db = getDB();
  const seq = nextSequence(sessionId);
  const payload = {
    _t: 'tool_result',
    tool_use_id: toolUseId,
    content: String(content),
    is_error: !!isError
  };
  db.prepare(
    `INSERT INTO transcript_entries(session_id, sequence, entry_type, payload_json, tool_use_id)
     VALUES (?, ?, 'tool_result', ?, ?)`
  ).run(sessionId, seq, JSON.stringify(payload), toolUseId);
  return payload;
}

// §2.5 step 2 — build provider messages from transcript_entries
export function buildMessages(sessionId) {
  const db = getDB();
  const rows = db.prepare(
    `SELECT entry_type, payload_json FROM transcript_entries
     WHERE session_id = ? ORDER BY sequence`
  ).all(sessionId);

  const messages = [];
  for (const row of rows) {
    const p = JSON.parse(row.payload_json);
    switch (row.entry_type) {
      case 'user':
        messages.push({
          role: 'user',
          content: p.content.map(b => b.text).join('\n')
        });
        break;
      case 'assistant': {
        const msg = { role: 'assistant' };
        const textParts = p.content.filter(b => b.type === 'text');
        const toolParts = p.content.filter(b => b.type === 'tool_use');
        if (textParts.length) msg.content = textParts.map(b => b.text).join('\n');
        if (toolParts.length) {
          msg.tool_calls = toolParts.map(b => ({
            id: b.id,
            type: 'function',
            function: { name: b.name, arguments: JSON.stringify(b.input) }
          }));
        }
        messages.push(msg);
        break;
      }
      case 'tool_result':
        messages.push({
          role: 'tool',
          tool_call_id: p.tool_use_id,
          content: p.content
        });
        break;
    }
  }
  return messages;
}
