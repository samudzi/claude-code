// §2.9 REPL operator surface — slash commands
import { getEffectiveSettings, putEffectiveSettings } from './store.mjs';
import { getConversationId, getSessionId, newSession } from './session.mjs';
import { resetSequenceCache } from './transcript.mjs';
import { fireHooks } from './hookplane.mjs';
import { getAuthStatus, logout as authLogout, login as authLogin } from './auth.mjs';
import { resolveModelSpec, resolveWireModel, WIRE_MODELS } from './orchestration.mjs';
import { TOOL_NAMES } from './tools.mjs';

const COMMANDS = {
  '/help': cmdHelp,
  '/model': cmdModel,
  '/clear': cmdClear,
  '/reset': cmdClear,
  '/new': cmdClear,
  '/config': cmdConfig,
  '/settings': cmdConfig,
  '/status': cmdStatus,
  '/login': cmdLogin,
  '/logout': cmdLogout,
  '/exit': cmdExit,
  '/quit': cmdExit,
};

export function dispatchCommand(line) {
  const trimmed = line.trim();
  const spaceIdx = trimmed.indexOf(' ');
  const cmd = spaceIdx === -1 ? trimmed : trimmed.slice(0, spaceIdx);
  const arg = spaceIdx === -1 ? '' : trimmed.slice(spaceIdx + 1).trim();

  const handler = COMMANDS[cmd.toLowerCase()];
  if (!handler) {
    process.stdout.write(`Unknown command: ${cmd}. Type /help for available commands.\n`);
    return false; // not exit
  }
  return handler(arg);
}

function cmdHelp() {
  process.stdout.write(`Available commands:
  /help              Show this help
  /model [name]      Show or change the active model
  /login             Authenticate with Anthropic
  /logout            Clear stored credentials
  /status            Show auth and config status
  /config            Show current settings
  /clear             Clear conversation (new session)
  /exit              Exit the REPL
`);
  return false;
}

function cmdModel(arg) {
  const settings = getEffectiveSettings();

  if (!arg) {
    // Show current model and available models
    const mc = settings.model_config || { provider: 'lm_studio_local', model_id: 'lm_studio_server_routed' };
    const wire = resolveWireModel(mc.provider, mc.model_id);
    process.stdout.write(`Current model:
  provider: ${mc.provider}
  model_id: ${mc.model_id}
  wire: ${wire}

Available models:
  claude_code_subscription:
    claude_opus_4 (claude-opus-4-20250514)
    claude_sonnet_4 (claude-sonnet-4-20250514)
    claude_3_5_haiku (claude-3-5-haiku-20241022)
  openai_compatible:
    gpt_4o (gpt-4o)
    gpt_4o_mini (gpt-4o-mini)
    o3 (o3)
    o3_mini (o3-mini)
  lm_studio_local:
    lm_studio_server_routed (LM_STUDIO_MODEL=${process.env.LM_STUDIO_MODEL || '<not set>'})
`);
    return false;
  }

  // Switch model
  const spec = resolveModelSpec(arg);
  settings.model_config = spec;
  putEffectiveSettings(settings);
  const wire = resolveWireModel(spec.provider, spec.model_id);
  let endpoint = '';
  if (spec.provider === 'lm_studio_local') {
    endpoint = ` endpoint: ${process.env.LM_STUDIO_BASE_URL || 'http://127.0.0.1:1234/v1'}`;
  } else if (spec.provider === 'openai_compatible') {
    endpoint = ` endpoint: ${process.env.OPENAI_BASE_URL || '<not set>'}`;
  } else if (spec.provider === 'claude_code_subscription') {
    endpoint = ` endpoint: ${process.env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com'}`;
  }
  process.stdout.write(`Model set: ${spec.provider} / ${spec.model_id} (wire: ${wire})${endpoint}\n`);
  return false;
}

function cmdClear() {
  // Fire SessionEnd hooks
  fireHooks('SessionEnd', { reason: 'clear' });

  // Create new session
  const newSid = newSession();

  // Fire SessionStart hooks
  fireHooks('SessionStart', { source: 'clear' });

  process.stdout.write(`Session cleared. New session: ${newSid}\n`);
  return false;
}

function cmdConfig() {
  const settings = getEffectiveSettings();
  process.stdout.write(`Settings (settings_snapshot effective):\n${JSON.stringify(settings, null, 2)}\n`);
  return false;
}

function cmdStatus() {
  const status = getAuthStatus();
  process.stdout.write(`Auth status:\n${JSON.stringify(status, null, 2)}\n`);
  return false;
}

function cmdLogin() {
  const msg = authLogin();
  process.stdout.write(`${msg}\n`);
  return false;
}

function cmdLogout() {
  authLogout();
  process.stdout.write(`Logged out. Credentials cleared.\n`);
  return false;
}

function cmdExit() {
  return true; // signal exit
}
