// §5.12 Permission rules after PreToolUse
// Appendix E — settings_snapshot.permissions
import { getEffectiveSettings } from './store.mjs';

// §5.12 defaultMode closed enum (no 'auto')
const MUTATING_IN_PLAN = new Set(['Write', 'Edit', 'Bash', 'NotebookEdit']);
const EDIT_TOOLS = new Set(['Read', 'Write', 'Edit']);

// Rule matching — reference behavior
function ruleMatches(rule, toolName) {
  if (!rule || typeof rule !== 'string') return false;
  // Simple tool name match
  if (rule === toolName) return true;
  // Prefix match for parameterized rules like "Bash(npm *)"
  if (rule.startsWith(toolName + '(')) return true;
  // MCP tool match
  if (rule.startsWith('mcp__') && toolName.startsWith('mcp__')) {
    return rule === toolName;
  }
  return false;
}

// §5.12 Aggregate precedence
// (1) deny match → deny
// (2) ask match → ask
// (3) allow match → allow
// (4) defaultMode fallback
export function evaluatePermission(toolName, toolInput, aggHookPermission) {
  const settings = getEffectiveSettings();
  const perms = settings.permissions || {};

  const denyList = perms.deny || [];
  const askList = perms.ask || [];
  const allowList = perms.allow || [];
  const defaultMode = perms.defaultMode || 'default';

  // Hook permission takes precedence if deny
  if (aggHookPermission === 'deny') return 'deny';

  // (1) deny list
  for (const rule of denyList) {
    if (ruleMatches(rule, toolName)) return 'deny';
  }

  // Hook permission ask
  if (aggHookPermission === 'ask') {
    // In pipe mode, ask → deny
    return 'deny';
  }

  // (2) ask list
  for (const rule of askList) {
    if (ruleMatches(rule, toolName)) {
      // In pipe mode, ask → allow (no interactive prompt available)
      return 'allow';
    }
  }

  // Hook permission allow
  if (aggHookPermission === 'allow') return 'allow';

  // (3) allow list
  for (const rule of allowList) {
    if (ruleMatches(rule, toolName)) return 'allow';
  }

  // (4) defaultMode fallback
  switch (defaultMode) {
    case 'bypassPermissions':
      return 'allow';
    case 'dontAsk':
      return 'deny';
    case 'plan':
      if (MUTATING_IN_PLAN.has(toolName)) return 'deny';
      return 'allow'; // Non-mutating tools allowed in plan mode
    case 'acceptEdits':
      if (EDIT_TOOLS.has(toolName)) return 'allow';
      return 'allow'; // In pipe mode, ask → allow
    case 'default':
    default:
      // default mode → ask → allow in pipe mode (no interactive prompt)
      return 'allow';
  }
}

export function logPermission(db, sessionId, toolUseId, toolName, decision, reason) {
  db.prepare(
    `INSERT INTO tool_permission_log(session_id, tool_use_id, tool_name, decision, reason_json, created_at)
     VALUES (?, ?, ?, ?, ?, datetime('now'))`
  ).run(sessionId, toolUseId, toolName, decision, reason ? JSON.stringify(reason) : null);
}
