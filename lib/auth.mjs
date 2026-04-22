// §2.7-2.8 Operator authentication & credential UX
// §2.3 Environment variables
import { existsSync, mkdirSync, writeFileSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';

let _bareMode = false;

export function setBareMode(bare) { _bareMode = bare; }
export function isBareMode() { return _bareMode; }

// §2.7.4 Precedence among Anthropic-class sources
// A1: ANTHROPIC_API_KEY, A2: ANTHROPIC_AUTH_TOKEN
export function getAnthropicAuth() {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  const bearer = process.env.ANTHROPIC_AUTH_TOKEN;

  if (_bareMode) {
    // A7: bare mode — only API key, no bearer/OAuth
    if (apiKey) return { kind: 'api_key', source: 'env', value: apiKey };
    return { kind: 'none', source: 'none', value: null };
  }

  // Bearer takes precedence over API key
  if (bearer) return { kind: 'bearer', source: 'env', value: bearer };
  if (apiKey) return { kind: 'api_key', source: 'env', value: apiKey };
  return { kind: 'none', source: 'none', value: null };
}

// §2.3 provider-specific env
export function getOpenAIAuth() {
  return {
    apiKey: process.env.OPENAI_API_KEY || null,
    baseUrl: process.env.OPENAI_BASE_URL || null
  };
}

export function getLMStudioAuth() {
  return {
    baseUrl: process.env.LM_STUDIO_BASE_URL || 'http://127.0.0.1:1234/v1',
    apiKey: process.env.LM_STUDIO_API_KEY || 'lm-studio',
    model: process.env.LM_STUDIO_MODEL || null
  };
}

// A5: /status — credential info without secrets
export function getAuthStatus() {
  const anthropic = getAnthropicAuth();
  const openai = getOpenAIAuth();
  const lm = getLMStudioAuth();

  const status = {
    anthropic: {
      kind: anthropic.kind,
      source: anthropic.source,
      has_credential: anthropic.value !== null
    },
    openai: {
      has_api_key: !!openai.apiKey,
      has_base_url: !!openai.baseUrl
    },
    lm_studio: {
      base_url: lm.baseUrl,
      has_model: !!lm.model
    }
  };
  return status;
}

// A4: /logout — clear credentials
export function logout() {
  const homeDir = process.env.ONAHOME || process.env.HOME || '~';
  const credFile = join(homeDir, '.ona', 'secure', 'anthropic.json');
  try {
    if (existsSync(credFile)) unlinkSync(credFile);
  } catch {}
}

// A3: /login — minimal for pipe mode
export function login() {
  // In pipe mode, cannot do browser OAuth. Just acknowledge.
  return 'Login requires interactive mode. Set ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN in environment.';
}
