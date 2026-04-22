// §2 Model providers, credentials, and turn loop
// §2.5 Canonical turn loop
import { spawnSync } from 'node:child_process';
import { getDB, getEffectiveSettings } from './store.mjs';
import { getConversationId, getSessionId } from './session.mjs';
import { appendUser, appendAssistant, appendToolUse, appendToolResult, buildMessages } from './transcript.mjs';
import { fireHooks } from './hookplane.mjs';
import { evaluatePermission, logPermission } from './permissions.mjs';
import { executeTool, getToolDefinitions, TOOL_NAMES } from './tools.mjs';
import { getAnthropicAuth, getOpenAIAuth, getLMStudioAuth } from './auth.mjs';
import { isPlanningGateBlocked } from './workflow.mjs';
import { randomUUID } from 'node:crypto';

// §2.2 model_config wire mapping
export const WIRE_MODELS = {
  claude_code_subscription: {
    claude_opus_4: 'claude-opus-4-20250514',
    claude_sonnet_4: 'claude-sonnet-4-20250514',
    claude_3_5_haiku: 'claude-3-5-haiku-20241022',
  },
  openai_compatible: {
    gpt_4o: 'gpt-4o',
    gpt_4o_mini: 'gpt-4o-mini',
    o3: 'o3',
    o3_mini: 'o3-mini',
  },
  lm_studio_local: {
    lm_studio_server_routed: null, // resolved from LM_STUDIO_MODEL env
  }
};

// §2.1 Provider enum
const PROVIDERS = ['claude_code_subscription', 'openai_compatible', 'lm_studio_local'];

export function resolveWireModel(provider, modelId) {
  const map = WIRE_MODELS[provider];
  if (!map) return modelId;
  if (provider === 'lm_studio_local' && modelId === 'lm_studio_server_routed') {
    return process.env.LM_STUDIO_MODEL || 'default';
  }
  return map[modelId] || modelId;
}

// Resolve provider + model_id from a user-supplied model name
export function resolveModelSpec(name) {
  // Check known enum values across all providers
  for (const provider of PROVIDERS) {
    const map = WIRE_MODELS[provider];
    if (map && name in map) {
      return { provider, model_id: name };
    }
  }
  // Unknown name → treat as lm_studio_local with custom model
  process.env.LM_STUDIO_MODEL = name;
  return { provider: 'lm_studio_local', model_id: 'lm_studio_server_routed' };
}

function getProviderEndpoint(provider) {
  switch (provider) {
    case 'claude_code_subscription': {
      const auth = getAnthropicAuth();
      const baseUrl = process.env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com';
      return {
        url: `${baseUrl}/v1/chat/completions`,
        headers: auth.kind === 'bearer'
          ? { 'Authorization': `Bearer ${auth.value}` }
          : { 'x-api-key': auth.value || '' },
        auth
      };
    }
    case 'openai_compatible': {
      const oa = getOpenAIAuth();
      if (!oa.baseUrl) throw new Error('OPENAI_BASE_URL required for openai_compatible');
      return {
        url: `${oa.baseUrl}/chat/completions`,
        headers: { 'Authorization': `Bearer ${oa.apiKey || ''}` },
        auth: oa
      };
    }
    case 'lm_studio_local': {
      const lm = getLMStudioAuth();
      return {
        url: `${lm.baseUrl}/chat/completions`,
        headers: { 'Authorization': `Bearer ${lm.apiKey}` },
        auth: lm
      };
    }
    default:
      throw new Error(`Unknown provider: ${provider}`);
  }
}

// HTTP POST (sync via child_process subprocess for simplicity)
function httpPostSync(urlStr, headers, body) {
  const bodyJson = JSON.stringify(body);
  const script = `
    const url = new (require('url').URL)(${JSON.stringify(urlStr)});
    const mod = url.protocol === 'https:' ? require('https') : require('http');
    const bodyData = ${JSON.stringify(bodyJson)};
    const opts = {
      hostname: url.hostname,
      port: url.port || (url.protocol === 'https:' ? 443 : 80),
      path: url.pathname + url.search,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(bodyData),
        ...${JSON.stringify(headers)}
      },
      timeout: 60000
    };
    const req = mod.request(opts, (res) => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => {
        process.stdout.write(JSON.stringify({ status: res.statusCode, body: d }));
      });
    });
    req.on('error', e => {
      process.stdout.write(JSON.stringify({ status: 0, error: e.message }));
    });
    req.write(bodyData);
    req.end();
  `;
  const result = spawnSync('node', ['-e', script], { encoding: 'utf8', timeout: 65000 });

  if (result.error) {
    return { status: 0, error: result.error.message };
  }
  try {
    return JSON.parse(result.stdout);
  } catch {
    return { status: 0, error: result.stderr || 'Parse error' };
  }
}

// §2.5 Full turn
export function runTurn(userText) {
  const sessionId = getSessionId();
  const convId = getConversationId();

  // Step 3: UserPromptSubmit hooks
  fireHooks('UserPromptSubmit', { prompt: userText });

  // Append user entry
  appendUser(sessionId, userText);

  // Get model config
  const settings = getEffectiveSettings();
  const mc = settings.model_config || { provider: 'lm_studio_local', model_id: 'lm_studio_server_routed' };
  const provider = mc.provider;
  const wireModel = resolveWireModel(provider, mc.model_id);

  // Get endpoint
  let endpoint;
  try {
    endpoint = getProviderEndpoint(provider);
  } catch (e) {
    process.stderr.write(`[ona] Provider error: ${e.message}\n`);
    appendAssistant(sessionId, `Error: ${e.message}`, null);
    return;
  }

  // Build messages
  const messages = buildMessages(sessionId);

  // Step 4: Call model
  const reqBody = {
    model: wireModel,
    messages,
    tools: getToolDefinitions(),
    stream: false
  };

  const resp = httpPostSync(endpoint.url, endpoint.headers, reqBody);

  if (resp.error) {
    const errMsg = `Connection error (${endpoint.url}): ${resp.error}`;
    process.stderr.write(`[ona] ${errMsg}\n`);
    process.stdout.write(`${errMsg}\n`);
    appendAssistant(sessionId, errMsg, null);
    return;
  }

  if (resp.status && resp.status >= 400) {
    let errDetail = '';
    try { errDetail = JSON.parse(resp.body).error?.message || resp.body; } catch { errDetail = resp.body; }
    const errMsg = `Error ${resp.status} from ${endpoint.url}: ${errDetail}`;
    process.stderr.write(`[ona] Auth/API error: ${errMsg}\n`);
    process.stdout.write(`${errMsg}\n`);
    appendAssistant(sessionId, errMsg, null);
    return;
  }

  let parsed;
  try {
    parsed = JSON.parse(resp.body);
  } catch {
    process.stderr.write(`[ona] Invalid response from model\n`);
    appendAssistant(sessionId, 'Error: invalid model response', null);
    return;
  }

  const choice = parsed.choices?.[0];
  if (!choice) {
    appendAssistant(sessionId, 'Error: no choices in response', null);
    return;
  }

  const msg = choice.message;
  const textContent = msg.content || null;
  const toolCalls = msg.tool_calls || null;

  // Step 5: Append assistant entry
  appendAssistant(sessionId, textContent, toolCalls);

  if (textContent) {
    process.stdout.write(`${textContent}\n`);
  }

  // Step 6: Execute tool calls
  if (toolCalls && toolCalls.length > 0) {
    for (const tc of toolCalls) {
      const toolName = tc.function.name;
      let toolInput;
      try { toolInput = JSON.parse(tc.function.arguments || '{}'); } catch { toolInput = {}; }
      const toolUseId = tc.id || randomUUID();

      // Record tool_use
      appendToolUse(sessionId, toolUseId, toolName, toolInput);

      // §8.3 Planning gate
      if (isPlanningGateBlocked(convId, toolName)) {
        appendToolResult(sessionId, toolUseId,
          `Tool ${toolName} denied: §8.3 planning gate — no approved plan`, true);
        fireHooks('PermissionDenied', { tool_name: toolName, tool_input: toolInput, tool_use_id: toolUseId, reason: '§8.3 planning gate' });
        continue;
      }

      // PreToolUse hooks
      const hookResult = fireHooks('PreToolUse', {
        tool_name: toolName,
        tool_input: toolInput,
        tool_use_id: toolUseId
      });

      if (hookResult.blocked) {
        const blockMsg = hookResult.blockMessages.map(b => `[${b.ordinal}] ${b.stderr_text}`).join('\n') || 'Blocked by hook';
        appendToolResult(sessionId, toolUseId, `Tool ${toolName} denied by PreToolUse hook: ${blockMsg}`, true);
        continue;
      }

      // §5.12 Permission check
      const permDecision = evaluatePermission(toolName, toolInput, hookResult.aggPermission);
      if (permDecision === 'deny') {
        logPermission(getDB(), sessionId, toolUseId, toolName, 'deny', { source: 'permission_rules' });
        appendToolResult(sessionId, toolUseId,
          `Tool ${toolName} denied by permission rules (${toolName})`, true);
        fireHooks('PermissionDenied', { tool_name: toolName, tool_input: toolInput, tool_use_id: toolUseId, reason: 'permission denied' });
        continue;
      }

      // Execute tool
      const result = executeTool(toolName, toolInput);

      // Record tool_result
      appendToolResult(sessionId, toolUseId, result.content, result.is_error);

      // PostToolUse or PostToolUseFailure hooks
      if (result.is_error) {
        fireHooks('PostToolUseFailure', {
          tool_name: toolName,
          tool_input: toolInput,
          tool_use_id: toolUseId,
          error: result.content
        });
      } else {
        fireHooks('PostToolUse', {
          tool_name: toolName,
          tool_input: toolInput,
          tool_response: result.content,
          tool_use_id: toolUseId
        });
      }
    }
  }
}
