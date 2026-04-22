// §5 Hook plane (normative, deterministic)
import { getDB, getEffectiveSettings } from './store.mjs';
import { getConversationId, getSessionId } from './session.mjs';
import { spawnSync } from 'node:child_process';

// §3 Hook events closed set
const HOOK_EVENTS = [
  'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'PermissionDenied',
  'Notification', 'UserPromptSubmit', 'SessionStart', 'SessionEnd',
  'Stop', 'StopFailure', 'SubagentStart', 'SubagentStop',
  'PreCompact', 'PostCompact', 'PermissionRequest', 'Setup',
  'TeammateIdle', 'TaskCreated', 'TaskCompleted',
  'Elicitation', 'ElicitationResult', 'ConfigChange',
  'InstructionsLoaded', 'WorktreeCreate', 'WorktreeRemove',
  'CwdChanged', 'FileChanged'
];

// §5.9 Timeouts
const DEFAULT_TIMEOUT_MS = 600000;
const SESSIONEND_TIMEOUT_MS = 1500;

function getTimeout(eventName) {
  if (eventName === 'SessionEnd') {
    return parseInt(process.env.SDLC_SESSIONEND_HOOK_TIMEOUT_MS || '', 10) || SESSIONEND_TIMEOUT_MS;
  }
  return parseInt(process.env.SDLC_HOOK_TIMEOUT_MS || '', 10) || DEFAULT_TIMEOUT_MS;
}

// §5.1 Matcher rules
function matchesHook(matcher, queryValue) {
  if (!matcher || matcher === '' || matcher === '*') return true;
  // pipe-separated exact match
  if (/^[a-zA-Z0-9_|]+$/.test(matcher) && matcher.includes('|')) {
    return matcher.split('|').includes(queryValue);
  }
  // Exact match
  if (/^[a-zA-Z0-9_]+$/.test(matcher)) {
    return matcher === queryValue;
  }
  // ECMAScript RegExp
  try {
    return new RegExp(matcher).test(queryValue || '');
  } catch {
    return false; // invalid regex → matches nothing
  }
}

// §5.1 Match query source per event
function getQueryValue(eventName, eventData) {
  switch (eventName) {
    case 'PreToolUse':
    case 'PostToolUse':
    case 'PostToolUseFailure':
    case 'PermissionRequest':
    case 'PermissionDenied':
      return eventData.tool_name || '';
    case 'SessionStart':
    case 'ConfigChange':
      return eventData.source || '';
    case 'Setup':
    case 'PreCompact':
    case 'PostCompact':
      return eventData.trigger || '';
    case 'Notification':
      return eventData.notification_type || '';
    case 'SessionEnd':
      return eventData.reason || '';
    case 'StopFailure':
      return String(eventData.error || '');
    case 'SubagentStart':
    case 'SubagentStop':
      return eventData.agent_type || '';
    case 'Elicitation':
    case 'ElicitationResult':
      return eventData.mcp_server_name || '';
    case 'InstructionsLoaded':
      return eventData.load_reason || '';
    case 'FileChanged':
      return eventData.file_path ? eventData.file_path.split('/').pop() : '';
    default:
      return '';
  }
}

// §6 Hook stdin base (fork policy)
function buildStdinPayload(eventName, eventData) {
  return {
    hook_event_name: eventName,
    session_id: getSessionId(),
    conversation_id: getConversationId(),
    runtime_db_path: process.env.AGENT_SDLC_DB || '',
    cwd: process.cwd(),
    ...eventData
  };
}

// Execute a single hook command
function executeHook(command, shell, stdinPayload, timeoutMs) {
  const stdinStr = JSON.stringify(stdinPayload) + '\n'; // §5.11 exactly one newline

  const env = { ...process.env };
  env.AGENT_SDLC_DB = process.env.AGENT_SDLC_DB || '';
  env.SDLC_HOOK = '1';
  if (!env.LANG && !env.LC_ALL) env.LANG = 'C.UTF-8';

  let argv;
  const sh = shell || 'bash';
  if (sh === 'bash') {
    argv = ['/bin/bash', '-lc', command];
  } else if (sh === 'sh') {
    argv = ['/bin/sh', '-c', command];
  } else {
    argv = ['/bin/bash', '-lc', command]; // fallback
  }

  const result = spawnSync(argv[0], argv.slice(1), {
    input: stdinStr,
    env,
    cwd: process.cwd(),
    timeout: timeoutMs,
    maxBuffer: 4194304, // §5.11 4MiB cap
    encoding: 'utf8'
  });

  let exitCode = result.status;
  let stdout = result.stdout || '';
  let stderr = result.stderr || '';
  let timedOut = false;

  if (result.error) {
    if (result.error.code === 'ETIMEDOUT') {
      timedOut = true;
      exitCode = null;
    }
  }

  // §5.11 truncation
  if (stdout.length > 4194304) {
    stdout = stdout.slice(0, 4194304) + '\n[SDLC_OUTPUT_TRUNCATED]\n';
  }
  if (stderr.length > 4194304) {
    stderr = stderr.slice(0, 4194304) + '\n[SDLC_OUTPUT_TRUNCATED]\n';
  }

  return { exitCode, stdout, stderr, timedOut };
}

// §5.5 Parse JSON stdout
function parseHookStdout(stdout) {
  if (!stdout || !stdout.trim()) return null;
  const trimmed = stdout.trim();
  if (!trimmed.startsWith('{')) return null;
  try {
    return JSON.parse(trimmed);
  } catch {
    return null;
  }
}

// Main hook dispatch
// Returns { blocked, blockMessages, aggPermission, hookOutputs }
export function fireHooks(eventName, eventData = {}) {
  // §5.10 SDLC_DISABLE_ALL_HOOKS=1
  if (process.env.SDLC_DISABLE_ALL_HOOKS === '1') {
    return { blocked: false, blockMessages: [], aggPermission: 'unset', hookOutputs: [] };
  }

  const db = getDB();
  const settings = getEffectiveSettings();
  const hooks = settings.hooks || [];

  const queryValue = getQueryValue(eventName, eventData);
  const stdinPayload = buildStdinPayload(eventName, eventData);
  const timeoutMs = getTimeout(eventName);

  // §5.2 Collect matching hooks with ordinals
  let ordinal = 0;
  const matchingHooks = [];
  for (const h of hooks) {
    if (h.hook_event_name === eventName && matchesHook(h.matcher || '', queryValue)) {
      matchingHooks.push({ ...h, ordinal: ordinal++ });
    }
  }

  // §5.6 Blocking and permission merge
  let aggPermission = 'unset'; // unset | allow | ask | deny
  const blockMessages = [];
  const hookOutputs = [];
  let blocked = false;

  for (const h of matchingHooks) {
    // Check if should skip due to prior block/deny (§5.6.3 PreToolUse only)
    if (blocked && (eventName === 'PreToolUse')) {
      // Record skipped
      db.prepare(
        `INSERT INTO hook_invocations(session_id, conversation_id, hook_event, hook_ordinal,
         matcher, command, tool_use_id, tool_name, input_json, exit_code, stdout_text, stderr_text,
         started_at, completed_at, skipped_reason)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, datetime('now'), datetime('now'), 'prior_block_or_deny')`
      ).run(
        getSessionId(), getConversationId(), eventName, h.ordinal,
        h.matcher || '', h.command,
        eventData.tool_use_id || null, eventData.tool_name || null,
        JSON.stringify(stdinPayload)
      );
      continue;
    }

    // Execute
    const result = executeHook(h.command, h.shell, stdinPayload, timeoutMs);

    // Record invocation
    db.prepare(
      `INSERT INTO hook_invocations(session_id, conversation_id, hook_event, hook_ordinal,
       matcher, command, tool_use_id, tool_name, input_json, exit_code, stdout_text, stderr_text,
       started_at, completed_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))`
    ).run(
      getSessionId(), getConversationId(), eventName, h.ordinal,
      h.matcher || '', h.command,
      eventData.tool_use_id || null, eventData.tool_name || null,
      JSON.stringify(stdinPayload),
      result.exitCode, result.stdout, result.stderr
    );

    // Parse stdout JSON
    const jsonOut = parseHookStdout(result.stdout);

    // §5.8 Reject async:true
    if (jsonOut && jsonOut.async === true) {
      process.stderr.write(`[ona] Hook async:true rejected (§5.8): ${h.command}\n`);
      // Don't treat as valid control
    } else if (!jsonOut && result.stdout && /async.*true|"async"\s*:\s*true/i.test(result.stdout)) {
      // Catch async:true even in malformed JSON (e.g. bash strips quotes)
      process.stderr.write(`[ona] Hook async:true rejected — invalid JSON (§5.8): ${h.command}\n`);
    }

    // §5.6 Permission merge from hookSpecificOutput
    if (jsonOut && jsonOut.hookSpecificOutput && jsonOut.hookSpecificOutput.permissionDecision) {
      const pd = jsonOut.hookSpecificOutput.permissionDecision;
      // merge: deny > ask > allow > unset
      if (pd === 'deny') aggPermission = 'deny';
      else if (pd === 'ask' && aggPermission !== 'deny') aggPermission = 'ask';
      else if (pd === 'allow' && aggPermission === 'unset') aggPermission = 'allow';
    }

    hookOutputs.push(jsonOut);

    // §5.4 Exit code 2 = blocking
    if (result.exitCode === 2) {
      blockMessages.push({ ordinal: h.ordinal, stderr_text: result.stderr });
      if (eventName === 'PreToolUse' || eventName === 'UserPromptSubmit') {
        blocked = true;
      }
    }

    // Timeout on PreToolUse/UserPromptSubmit → treat as exit 2
    if (result.timedOut && (eventName === 'PreToolUse' || eventName === 'UserPromptSubmit')) {
      blockMessages.push({ ordinal: h.ordinal, stderr_text: 'Hook timed out' });
      blocked = true;
    }

    // §5.6.3 PreToolUse: deny also blocks remaining
    if (aggPermission === 'deny' && eventName === 'PreToolUse') {
      blocked = true;
    }
  }

  return { blocked, blockMessages, aggPermission, hookOutputs };
}
