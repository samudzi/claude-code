#!/usr/bin/env node
// ona — SDLC clean-room agent per CLEAN_ROOM_SPEC.md
// Entry point: bin/agent.mjs
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { openDB, bootstrapSchema, getEffectiveSettings, putEffectiveSettings } from '../lib/store.mjs';
import { createOrResumeConversation, createSession, getSessionId, getConversationId } from '../lib/session.mjs';
import { fireHooks } from '../lib/hookplane.mjs';
import { dispatchCommand } from '../lib/commands.mjs';
import { runTurn } from '../lib/orchestration.mjs';
import { setBareMode } from '../lib/auth.mjs';

// Parse CLI args
const args = process.argv.slice(2);
const bareMode = args.includes('--bare');
setBareMode(bareMode);

// §4.1 DB path from env
const dbPath = process.env.AGENT_SDLC_DB;
if (!dbPath) {
  process.stderr.write('ona: AGENT_SDLC_DB environment variable required\n');
  process.exit(1);
}

// §4 Open DB and bootstrap schema
openDB(resolve(dbPath));
bootstrapSchema();

// §4.4 Bootstrap default settings if none exist
const existingSettings = getEffectiveSettings();
if (!existingSettings.model_config) {
  // Default: lm_studio_local
  putEffectiveSettings({
    ...existingSettings,
    model_config: {
      provider: 'lm_studio_local',
      model_id: 'lm_studio_server_routed'
    }
  });
}

// Create or resume conversation + create session
createOrResumeConversation(process.cwd());
createSession();

// §5.10 SessionStart hooks
fireHooks('SessionStart', { source: 'startup' });

// REPL loop — read stdin line by line
const rl = createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false,
  prompt: ''
});

let exiting = false;

rl.on('line', (line) => {
  if (exiting) return;
  const trimmed = line.trim();
  if (!trimmed) return;

  if (trimmed.startsWith('/')) {
    const shouldExit = dispatchCommand(trimmed);
    if (shouldExit) {
      exiting = true;
      shutdown();
    }
  } else {
    // Regular message → LLM turn
    runTurn(trimmed);
  }
});

rl.on('close', () => {
  if (!exiting) {
    exiting = true;
    shutdown();
  }
});

function shutdown() {
  fireHooks('SessionEnd', { reason: 'prompt_input_exit' });
  process.exit(0);
}
