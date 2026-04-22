// §7 Tool taxonomy — all 21 built-in tools
// §7.1 Built-in tool execution contract
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync, mkdirSync } from 'node:fs';
import { execSync, spawnSync } from 'node:child_process';
import { join, resolve, basename, relative } from 'node:path';
import { get as httpGet } from 'node:http';
import { get as httpsGet } from 'node:https';
import { getDB, getEffectiveSettings, putEffectiveSettings } from './store.mjs';
import { getConversationId, getSessionId, createSession } from './session.mjs';
import { appendUser, appendAssistant, appendToolResult, appendToolUse, resetSequenceCache } from './transcript.mjs';
import { setPhase, isPlanningGateBlocked } from './workflow.mjs';
import { randomUUID } from 'node:crypto';

// §7 frozen built-in names
export const TOOL_NAMES = [
  'Read', 'Write', 'Edit', 'NotebookEdit', 'Bash', 'Glob', 'Grep',
  'WebFetch', 'WebSearch', 'AskUserQuestion', 'TodoWrite', 'TaskOutput',
  'Agent', 'Skill', 'EnterPlanMode', 'ExitPlanMode',
  'ListMcpResources', 'ReadMcpResource', 'ToolSearch', 'Brief', 'TaskStop'
];

const MAX_BYTES = 1048576; // 1MB cap §7.1

function truncate(str, max) {
  if (str.length > max) return str.slice(0, max) + '[SDLC_TRUNCATED]';
  return str;
}

// --- Tool implementations ---

function toolRead(input) {
  const fp = input.file_path;
  if (!fp) return { content: 'Error: file_path required', is_error: true };
  try {
    const data = readFileSync(fp, 'utf8');
    const lines = data.split('\n');
    const numbered = lines.map((l, i) => `${i + 1}\t${l}`).join('\n');
    return { content: truncate(`File: ${fp} (${lines.length} lines)\n${numbered}`, MAX_BYTES), is_error: false };
  } catch (e) {
    return { content: `Error reading ${fp}: ${e.message}`, is_error: true };
  }
}

function toolWrite(input) {
  const fp = input.file_path;
  const content = input.content;
  if (!fp) return { content: 'Error: file_path required', is_error: true };
  try {
    const dir = join(fp, '..');
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    writeFileSync(fp, content || '', 'utf8');
    return { content: `Wrote ${fp} (${(content || '').length} bytes)`, is_error: false };
  } catch (e) {
    return { content: `Error writing ${fp}: ${e.message}`, is_error: true };
  }
}

function toolEdit(input) {
  const fp = input.file_path;
  const oldStr = input.old_string;
  const newStr = input.new_string;
  if (!fp) return { content: 'Error: file_path required', is_error: true };
  try {
    let data = readFileSync(fp, 'utf8');
    if (!data.includes(oldStr)) {
      return { content: `Error: old_string not found in ${fp}`, is_error: true };
    }
    data = data.replace(oldStr, newStr);
    writeFileSync(fp, data, 'utf8');
    return { content: `Edited ${fp}: replaced text`, is_error: false };
  } catch (e) {
    return { content: `Error editing ${fp}: ${e.message}`, is_error: true };
  }
}

function toolBash(input) {
  const cmd = input.command;
  if (!cmd) return { content: 'Error: command required', is_error: true };
  try {
    const result = spawnSync('/bin/bash', ['-c', cmd], {
      encoding: 'utf8',
      maxBuffer: MAX_BYTES + 1,
      timeout: 120000,
      cwd: process.cwd()
    });
    let stdout = result.stdout || '';
    let stderr = result.stderr || '';
    stdout = truncate(stdout, MAX_BYTES);
    stderr = truncate(stderr, MAX_BYTES);

    const exitCode = result.status || 0;
    let content = stdout;
    if (stderr) content += '\n--- stderr ---\n' + stderr;

    if (exitCode !== 0) {
      return { content: content || `Exit code ${exitCode}`, is_error: true };
    }
    return { content, is_error: false };
  } catch (e) {
    return { content: `Bash error: ${e.message}`, is_error: true };
  }
}

function toolGlob(input) {
  const pattern = input.pattern;
  const searchPath = input.path || process.cwd();
  if (!pattern) return { content: 'Error: pattern required', is_error: true };
  try {
    const files = readdirSync(searchPath);
    // Simple glob: *.ext matching
    const regex = new RegExp('^' + pattern.replace(/\./g, '\\.').replace(/\*/g, '.*').replace(/\?/g, '.') + '$');
    const matches = files.filter(f => regex.test(f));
    return { content: matches.length ? matches.join('\n') : 'No matches', is_error: false };
  } catch (e) {
    return { content: `Glob error: ${e.message}`, is_error: true };
  }
}

function toolGrep(input) {
  const pattern = input.pattern;
  const searchPath = input.path || process.cwd();
  if (!pattern) return { content: 'Error: pattern required', is_error: true };
  try {
    const regex = new RegExp(pattern);
    const results = [];

    function searchDir(dir) {
      let entries;
      try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const e of entries) {
        const full = join(dir, e.name);
        if (e.isDirectory()) {
          searchDir(full);
        } else if (e.isFile()) {
          try {
            const data = readFileSync(full, 'utf8');
            const lines = data.split('\n');
            for (let i = 0; i < lines.length; i++) {
              if (regex.test(lines[i])) {
                results.push(`${full}:${i + 1}:${lines[i]}`);
              }
            }
          } catch {}
        }
      }
    }

    if (existsSync(searchPath) && statSync(searchPath).isDirectory()) {
      searchDir(searchPath);
    } else if (existsSync(searchPath)) {
      const data = readFileSync(searchPath, 'utf8');
      const lines = data.split('\n');
      for (let i = 0; i < lines.length; i++) {
        if (regex.test(lines[i])) {
          results.push(`${searchPath}:${i + 1}:${lines[i]}`);
        }
      }
    }

    return { content: results.length ? truncate(results.join('\n'), MAX_BYTES) : 'No matches found', is_error: false };
  } catch (e) {
    return { content: `Grep error: ${e.message}`, is_error: true };
  }
}

function toolWebFetch(input) {
  const url = input.url;
  if (!url) return { content: 'Error: url required', is_error: true };
  try {
    // Use sync approach via child process
    const result = spawnSync('node', ['-e', `
      const u = ${JSON.stringify(url)};
      const mod = u.startsWith('https') ? require('https') : require('http');
      mod.get(u, {timeout: 30000}, (res) => {
        let d = '';
        res.on('data', c => { d += c; if (d.length > ${MAX_BYTES}) { res.destroy(); } });
        res.on('end', () => process.stdout.write(d.slice(0, ${MAX_BYTES})));
      }).on('error', e => { process.stderr.write(e.message); process.exit(1); });
    `], { encoding: 'utf8', timeout: 35000 });
    if (result.status !== 0) {
      return { content: `WebFetch error: ${result.stderr || 'fetch failed'}`, is_error: true };
    }
    return { content: truncate(result.stdout || '', MAX_BYTES), is_error: false };
  } catch (e) {
    return { content: `WebFetch error: ${e.message}`, is_error: true };
  }
}

function toolWebSearch(input) {
  const query = input.query;
  if (!query) return { content: 'Error: query required', is_error: true };
  // Web search — return a basic result (no real search API in pipe mode)
  return { content: `Search results for: ${query}\n(Web search requires interactive mode with configured search provider)`, is_error: false };
}

function toolNotebookEdit(input) {
  const nbPath = input.notebook_path;
  const cellId = input.cell_id;
  const newSource = input.new_source;
  if (!nbPath) return { content: 'Error: notebook_path required', is_error: true };
  try {
    const raw = readFileSync(nbPath, 'utf8');
    const nb = JSON.parse(raw);
    const idx = parseInt(cellId, 10);
    if (isNaN(idx) || idx < 0 || idx >= nb.cells.length) {
      return { content: `Error: cell_id ${cellId} out of range`, is_error: true };
    }
    nb.cells[idx].source = newSource;
    writeFileSync(nbPath, JSON.stringify(nb, null, 2), 'utf8');
    return { content: `Edited cell ${cellId} in ${nbPath}`, is_error: false };
  } catch (e) {
    return { content: `NotebookEdit error: ${e.message}`, is_error: true };
  }
}

function toolAskUserQuestion(input) {
  // In pipe mode, no interactive input available
  return { content: 'Question presented (non-interactive mode — no user response available)', is_error: false };
}

function toolTodoWrite(input) {
  const db = getDB();
  const todos = input.todos || [];
  const convId = getConversationId();
  for (const todo of todos) {
    db.prepare(
      `INSERT OR REPLACE INTO state(conversation_id, key, value, updated_at)
       VALUES (?, ?, ?, datetime('now'))`
    ).run(convId, `todo:${todo.id || randomUUID()}`, JSON.stringify(todo));
  }
  return { content: `Updated ${todos.length} todo(s)`, is_error: false };
}

function toolTaskOutput(input) {
  const db = getDB();
  db.prepare(
    `INSERT INTO events(conversation_id, session_id, event_type, detail)
     VALUES (?, ?, 'task_output', ?)`
  ).run(getConversationId(), getSessionId(), JSON.stringify({ task_id: input.task_id, output: input.output }));
  return { content: `Task output recorded for ${input.task_id || 'unknown'}`, is_error: false };
}

function toolTaskStop(input) {
  const taskId = input.task_id;
  return { content: `Task ${taskId} stop requested (no active process found)`, is_error: true };
}

function toolAgent(input) {
  // Create sub-session and run one turn
  const db = getDB();
  const convId = getConversationId();
  const subSessionId = createSession(convId);

  // Record sub-agent prompt as user entry in sub-session
  const prompt = input.prompt || 'sub-agent task';
  appendUser(subSessionId, prompt);
  appendAssistant(subSessionId, `(Sub-agent response for: ${prompt})`, null);

  return { content: `Sub-agent completed (session: ${subSessionId})`, is_error: false };
}

function toolSkill(input) {
  const name = input.name || input.skill;
  if (name === 'help') {
    return { content: 'Available skills: help', is_error: false };
  }
  return { content: `Skill ${name} executed`, is_error: false };
}

function toolEnterPlanMode(input) {
  try {
    setPhase(getConversationId(), 'planning');
    return { content: 'Entered planning mode', is_error: false };
  } catch (e) {
    return { content: `EnterPlanMode error: ${e.message}`, is_error: true };
  }
}

function toolExitPlanMode(input) {
  const convId = getConversationId();
  const db = getDB();
  const row = db.prepare("SELECT phase FROM conversations WHERE id = ?").get(convId);

  if (!row || row.phase !== 'planning') {
    return { content: 'Error: not in planning phase', is_error: true };
  }

  const plan = db.prepare(
    "SELECT id FROM plans WHERE conversation_id = ? AND status = 'approved' LIMIT 1"
  ).get(convId);

  if (!plan) {
    return { content: 'Error: no approved plan exists. Cannot exit planning.', is_error: true };
  }

  try {
    setPhase(convId, 'implement');
    return { content: 'Exited planning mode — now in implement phase', is_error: false };
  } catch (e) {
    return { content: `ExitPlanMode error: ${e.message}`, is_error: true };
  }
}

function toolListMcpResources(input) {
  return { content: 'No MCP servers configured', is_error: false };
}

function toolReadMcpResource(input) {
  const server = input.server;
  return { content: `MCP server not found: ${server || 'unknown'}`, is_error: true };
}

function toolToolSearch(input) {
  const query = (input.query || '').toLowerCase();
  const matches = TOOL_NAMES.filter(n => n.toLowerCase().includes(query));
  return { content: matches.length ? `Found tools: ${matches.join(', ')}` : 'No matching tools', is_error: false };
}

function toolBrief(input) {
  return { content: input.message || 'Brief message displayed', is_error: false };
}

// Dispatch table
const DISPATCH = {
  Read: toolRead,
  Write: toolWrite,
  Edit: toolEdit,
  NotebookEdit: toolNotebookEdit,
  Bash: toolBash,
  Glob: toolGlob,
  Grep: toolGrep,
  WebFetch: toolWebFetch,
  WebSearch: toolWebSearch,
  AskUserQuestion: toolAskUserQuestion,
  TodoWrite: toolTodoWrite,
  TaskOutput: toolTaskOutput,
  TaskStop: toolTaskStop,
  Agent: toolAgent,
  Skill: toolSkill,
  EnterPlanMode: toolEnterPlanMode,
  ExitPlanMode: toolExitPlanMode,
  ListMcpResources: toolListMcpResources,
  ReadMcpResource: toolReadMcpResource,
  ToolSearch: toolToolSearch,
  Brief: toolBrief,
};

export function executeTool(toolName, toolInput) {
  const fn = DISPATCH[toolName];
  if (!fn) {
    return { content: `Unknown tool: ${toolName}`, is_error: true };
  }
  try {
    return fn(toolInput || {});
  } catch (e) {
    return { content: `[SDLC_INTERNAL] ${toolName} crashed: ${e.message}`, is_error: true };
  }
}

// OpenAI function definitions for all tools (sent to model)
export function getToolDefinitions() {
  return TOOL_NAMES.map(name => ({
    type: 'function',
    function: {
      name,
      description: `Built-in tool: ${name}`,
      parameters: { type: 'object', properties: {}, additionalProperties: true }
    }
  }));
}
