// §8 SDLC workflow state and tool gating
import { getDB } from './store.mjs';

// §8.1 conversations.phase closed enum
const PHASES = ['idle', 'planning', 'implement', 'test', 'verify', 'done'];

// §8.2 Phase transitions
const TRANSITIONS = {
  idle:       ['planning'],
  planning:   ['implement'],  // requires approved plan
  implement:  ['test'],       // forbidden: implement→verify
  test:       ['verify'],
  verify:     ['done'],
  done:       ['planning'],
};

export function setPhase(conversationId, newPhase) {
  if (!PHASES.includes(newPhase)) {
    throw new Error(`Invalid phase: ${newPhase}. Must be one of: ${PHASES.join(', ')}`);
  }

  const db = getDB();
  const row = db.prepare("SELECT phase FROM conversations WHERE id = ?").get(conversationId);
  if (!row) throw new Error(`Conversation not found: ${conversationId}`);

  const currentPhase = row.phase;

  // any → planning is always allowed (EnterPlanMode)
  if (newPhase === 'planning') {
    db.prepare(
      "UPDATE conversations SET phase = ?, last_active = datetime('now') WHERE id = ?"
    ).run(newPhase, conversationId);
    return;
  }

  // planning → implement requires approved plan
  if (currentPhase === 'planning' && newPhase === 'implement') {
    const plan = db.prepare(
      "SELECT id FROM plans WHERE conversation_id = ? AND status = 'approved' LIMIT 1"
    ).get(conversationId);
    if (!plan) {
      throw new Error('Cannot transition to implement: no approved plan exists');
    }
  }

  // Check allowed transitions
  const allowed = TRANSITIONS[currentPhase] || [];
  if (!allowed.includes(newPhase) && newPhase !== 'planning') {
    throw new Error(`Cannot transition from ${currentPhase} to ${newPhase}`);
  }

  db.prepare(
    "UPDATE conversations SET phase = ?, last_active = datetime('now') WHERE id = ?"
  ).run(newPhase, conversationId);
}

// §8.3 Planning gate — deny mutating tools during planning without approved plan
const MUTATING_TOOLS = new Set(['Write', 'Edit', 'Bash', 'NotebookEdit']);

export function isPlanningGateBlocked(conversationId, toolName) {
  if (!MUTATING_TOOLS.has(toolName)) return false;

  const db = getDB();
  const row = db.prepare("SELECT phase FROM conversations WHERE id = ?").get(conversationId);
  if (!row || row.phase !== 'planning') return false;

  const plan = db.prepare(
    "SELECT id FROM plans WHERE conversation_id = ? AND status = 'approved' LIMIT 1"
  ).get(conversationId);

  return !plan; // blocked if no approved plan
}
