#!/usr/bin/env node
/**
 * Verifies HookInputSchema() member order in entrypoints/sdk/coreSchemas.ts
 * matches the canonical SDLC spec (CLEAN_ROOM_SPEC.md Appendix A / §16 D1).
 * Run from repository root: node scripts/verify-sdlc-hook-order.mjs
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(__dirname, '..')
const coreSchemas = path.join(root, 'entrypoints/sdk/coreSchemas.ts')

/** Canonical order — must match CLEAN_ROOM_SPEC.md Appendix A and HookInputSchema union. */
const SPEC_ORDER = [
  'PreToolUse',
  'PostToolUse',
  'PostToolUseFailure',
  'PermissionDenied',
  'Notification',
  'UserPromptSubmit',
  'SessionStart',
  'SessionEnd',
  'Stop',
  'StopFailure',
  'SubagentStart',
  'SubagentStop',
  'PreCompact',
  'PostCompact',
  'PermissionRequest',
  'Setup',
  'TeammateIdle',
  'TaskCreated',
  'TaskCompleted',
  'Elicitation',
  'ElicitationResult',
  'ConfigChange',
  'InstructionsLoaded',
  'WorktreeCreate',
  'WorktreeRemove',
  'CwdChanged',
  'FileChanged',
]

function extractUnionOrder(src) {
  const marker = 'export const HookInputSchema = lazySchema(() =>'
  const i = src.indexOf(marker)
  if (i < 0) throw new Error('HookInputSchema not found')
  const sub = src.slice(i)
  const u = sub.indexOf('z.union([')
  if (u < 0) throw new Error('z.union not found after HookInputSchema')
  const start = i + u + 'z.union(['.length
  let depth = 1
  let j = start
  for (; j < src.length && depth > 0; j++) {
    const c = src[j]
    if (c === '[') depth++
    else if (c === ']') depth--
  }
  const inner = src.slice(start, j - 1)
  const re = /(\w+HookInputSchema)\(\)/g
  const out = []
  let m
  while ((m = re.exec(inner)) !== null) {
    const name = m[1].replace(/HookInputSchema$/, '')
    out.push(name)
  }
  return out
}

const src = fs.readFileSync(coreSchemas, 'utf8')
let fileOrder
try {
  fileOrder = extractUnionOrder(src)
} catch (e) {
  console.error('verify-sdlc-hook-order:', e.message)
  process.exit(1)
}

if (fileOrder.length !== SPEC_ORDER.length) {
  console.error(
    `Hook union length mismatch: file=${fileOrder.length} spec=${SPEC_ORDER.length}`,
  )
  console.error('file:', fileOrder.join(', '))
  process.exit(1)
}

for (let k = 0; k < SPEC_ORDER.length; k++) {
  if (fileOrder[k] !== SPEC_ORDER[k]) {
    console.error(
      `Mismatch at index ${k}: file=${fileOrder[k]} spec=${SPEC_ORDER[k]}`,
    )
    console.error('file order:', fileOrder.join(', '))
    console.error('spec order:', SPEC_ORDER.join(', '))
    process.exit(1)
  }
}

console.log(
  'verify-sdlc-hook-order: OK (',
  SPEC_ORDER.length,
  'HookInputSchema union members)',
)
