# Clean-room specification — SDLC production profile (SQLite transactions, deterministic hooks)

**Host doc role:** Normative **delta** against the Claude Code **reference product** (`SPEC_AUTHORING_RULES.md` **Framing**). **Operator authentication and credential UX** are **enumerated in §2.7–2.8** (closed list)—implementers **must** ship those capabilities; they **must not** infer them from memory or informal “parity.” Other operator chrome **not** listed in §2.7–2.8 or elsewhere in this doc **defaults to reference parity** per `SPEC_AUTHORING_RULES.md`. This document binds **persistence, hook plane, orchestration, hooks, tools, and cited contracts** for a one-shot implementer pass.

**Authoring rules:** `SPEC_AUTHORING_RULES.md`. **Closed decisions:** §17 (binding; no external phase purchases required to implement).

**Reference traceability (informative):** Hook stdin order cross-checked against `entrypoints/sdk/coreSchemas.ts` → `HookInputSchema` union (lines 767–796). **Normative authority:** this document, including §17. **Forks** from reference are labeled **fork policy** below.

**One-shot (binding):** Every **normative** section is complete as written—no guessing shapes, enums, DDL, or algorithms unless labeled **implementation-defined** with a **closed** set.

---

## 0. Normative interpretation — zero ambiguity (binding)

1. **Modality:** In this document, **must** / **shall** / **required** / **forbidden** denote **hard conformance**: implementers **must** be able to demonstrate each with an **observable** test (CLI action, stored row, API outcome, or logged hook row). **May** denotes **optional** behavior **only** in that sentence’s scope; absence of **may** on a capability does **not** make that capability optional if elsewhere required.
2. **No silent subsetting:** Per `SPEC_AUTHORING_RULES.md` **Spec as diff**, any UX, CLI flow, tool, or provider **not** explicitly **forked** in this document or **§17** **defaults to reference Claude Code parity**. **Forbidden:** treating spec silence as permission to ship a **smaller** command set, **fewer** §7 tools, or **fewer** §2.1 providers than reference unless **§17** records an explicit **omit** or **replace** row with a **closed** substitute.
3. **Forbidden delivery patterns:** **Forbidden** merging a one-shot labeled “complete” while any normative path returns **not implemented**, **TODO**, permanent **stub** throws, or unreachable code for a **must** in this spec. **Forbidden** “documentation-only” features (described in operator docs but not wired in the binary).
4. **Contracts are closed:** Where this spec cites “reference behavior,” acceptance **requires** behavioral match to the reference tree for that surface **unless** a **fork policy** paragraph or **§17** row states a **closed** delta. **Forbidden** ambiguous phrases such as “similar to reference,” “best effort,” or “eventually” for normative requirements.
5. **DELIVERED is binary:** The product state **DELIVERED** is **true** iff **Appendix F** is satisfied in full. **Forbidden** partial credit, “mostly done,” or “usable except …” for one-shot sign-off. If **Appendix F** is false, the build is **not DELIVERED**—regardless of subjective review.
6. **No post-shot construction:** **Forbidden** declaring **DELIVERED** if the operator **must** edit application **source** (runtime code paths), add missing modules, or follow **undocumented** steps to obtain behavior that this spec marks **must**. After **DELIVERED**, work is **defect repair**, **dependency updates**, or **explicit spec revision**—**not** completing normative features left unfinished at sign-off.

---

## Hard requirements (binding)

1. **Contracts complete:** Per `SPEC_AUTHORING_RULES.md` §2 and §3; **§2.7–2.8** operator auth; **§2.9–2.10** REPL + providers; unified DDL §4.3–§4.8; hook I/O §§5.11–5.12, §6, §§11–12; tools **§7** (including **§7.2**); algorithms §5–8; permissions **Appendix E**.  
2. **Hook plane:** Sequential, total order, deterministic merge (**fork policy** vs reference parallel/async patterns where applicable).  
3. **Transactional SQLite only:** All **transactional** data per §4; **forbidden** authoritative JSONL transcripts, authoritative plan directory scans, secrets in DB.  
4. **Functional completeness:** Every **must** in this document is **live** in the shipped binary for the one-shot; **§10** and **§18** are the **minimum** acceptance bar—**not** aspirational.  
5. **Operator usability:** The operator can **log in**, **select or change model in-session**, run **every** §2.1 provider that remains non-forked, and invoke **every** §7 built-in tool contract **without** undocumented manual file rituals as the sole path (**§2.9**, **§7.2**).  
6. **Traceability — machine closure:** **Appendix F** artefacts **must** exist in the implementation root (**§9**). CI **must** execute **`scripts/sdlc-acceptance.sh`** (or the **closed** equivalent named in the matrix) on every change intended for release; **forbidden** merge to the delivery branch if exit code ≠ **0**. **Forbidden** subjective sign-off (“LGTM”) as a substitute for **Appendix F**.

---

## 1. Goals and scope

| Goal | Mechanism |
|------|-----------|
| **Model orchestration (spine)** | §2: provider enums, per-provider model enums, env-only credentials, canonical turn loop (`internal/orchestration/`); **§2.7–2.8** auth + storage (`internal/auth/`) |
| Enforceable SDLC phases | Workflow KV + `plans` + PreToolUse / policy hooks |
| Auditability | `hook_invocations`, `transcript_entries`, `events` |
| Determinism | Sequential hooks, enumerated merges, single DB |

**Explicit fork (normative):** Session transcript authority is **SQLite** (`transcript_entries`), not filesystem JSONL. **Explicit fork:** Hook stdin base omits `transcript_path`; adds `conversation_id` and `runtime_db_path` (§6). **Explicit fork:** Valid stdout **`{"async":true}`** is **rejected** as control flow for SDLC profile (§5.8). **Explicit fork:** PreToolUse multi-hook exit code `2` and permission merge — **§5.6** (not reference last-wins race semantics).

---

## 2. Model providers, credentials, and turn loop (normative)

Orchestration **must** implement: resolve provider → load context from `transcript_entries` → model call → assistant output → tools through §5 → append results. Subagents: distinct `session_id`; **no** parallel model calls per `session_id`.

### 2.1 Provider enum (closed, case-sensitive)

| Value | Meaning |
|-------|---------|
| `claude_code_subscription` | Anthropic Messages API (or documented successor) with subscription/API credentials; official-class endpoints unless `ANTHROPIC_BASE_URL` overrides. |
| `openai_compatible` | Remote OpenAI Chat Completions–compatible HTTP API (tool-capable). |
| `lm_studio_local` | Local OpenAI-compatible server; LM Studio–style defaults in §2.3. |

### 2.2 `model_config` (in `settings_snapshot` scope `effective`)

```json
{
  "provider": "<§2.1>",
  "model_id": "<enum for that provider>"
}
```

**Forbidden keys in `model_config`:** any secret, token, or `Authorization` material. **Allowed:** `provider`, `model_id` only.

**`claude_code_subscription` — `ClaudeSubscriptionModelId`:**

| `model_id` | Wire `model` |
|------------|----------------|
| `claude_opus_4` | `claude-opus-4-20250514` |
| `claude_sonnet_4` | `claude-sonnet-4-20250514` |
| `claude_3_5_haiku` | `claude-3-5-haiku-20241022` |

**`openai_compatible` — `OpenAICompatModelId`:**

| `model_id` | Wire `model` |
|------------|----------------|
| `gpt_4o` | `gpt-4o` |
| `gpt_4o_mini` | `gpt-4o-mini` |
| `o3` | `o3` |
| `o3_mini` | `o3-mini` |

**`lm_studio_local` — `LmStudioModelId`:**

| `model_id` | Wire `model` |
|------------|----------------|
| `lm_studio_server_routed` | Value of env `LM_STUDIO_MODEL` (required non-empty when selected). |

Invalid `model_id` for `provider` → configuration error **before** network I/O.

### 2.3 Environment variables (credentials and endpoints)

| Provider | Variable | Required | Default |
|----------|----------|----------|---------|
| `claude_code_subscription` | `ANTHROPIC_API_KEY` | yes* | — |
| `claude_code_subscription` | `ANTHROPIC_AUTH_TOKEN` | yes* | — |
| `claude_code_subscription` | `ANTHROPIC_BASE_URL` | no | `https://api.anthropic.com` |

\*At least one of `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` non-empty.

| Provider | Variable | Required | Default |
|----------|----------|----------|---------|
| `openai_compatible` | `OPENAI_API_KEY` | yes | — |
| `openai_compatible` | `OPENAI_BASE_URL` | yes | — |

| Provider | Variable | Required | Default |
|----------|----------|----------|---------|
| `lm_studio_local` | `LM_STUDIO_BASE_URL` | no | `http://127.0.0.1:1234/v1` |
| `lm_studio_local` | `LM_STUDIO_API_KEY` | no | `lm-studio` |
| `lm_studio_local` | `LM_STUDIO_MODEL` | yes if `model_id` is `lm_studio_server_routed` | — |

### 2.4 Precedence

1. Env supplies endpoints and credential values per §2.3.  
2. `settings_snapshot.effective` supplies `model_config.provider` and `model_config.model_id`.  
3. Missing required env → **no** model call; record failure (`StopFailure`-class semantics / `events`).

### 2.5 Canonical turn loop

1. Load snapshot + env; validate §2.2–2.3.  
2. Build provider messages from `transcript_entries` for `session_id` ordered by `sequence` (deterministic mapping).  
3. On user submit: `UserPromptSubmit` hooks (§5); append `user` rows (Appendix C).  
4. Call model (streaming allowed); parse assistant content and tool calls.  
5. Append `assistant` rows (Appendix C); preserve tool declaration order.  
6. For each tool use in order: PreToolUse → permission → execute → PostToolUse (§5); append `tool_result`.  
7. If more tool results feed the model, repeat from step 4; else end turn.  
8. Commit `transcript_entries` and `hook_invocations` in SQLite transactions consistent with §4.

**Fork policy:** No `Promise.all` / parallel pools for model response or PreToolUse **outcomes** on the same `session_id`.

### 2.6 `SessionStart` hook field `model`

**Should** echo resolved wire model string (§2.2) for audit.

### 2.7 Operator authentication & credential UX (normative — **closed capability set**)

The product **must** expose the following **without** the implementer guessing. **Reference trace** (informative, for behavior parity tests): `utils/auth.ts` (`getAuthTokenSource`, `getAnthropicApiKeyWithSource`), `commands/login/`, `commands/logout/`, `services/oauth/*`, `utils/secureStorage/*`, `utils/authPortable.ts`.

#### 2.7.1 Anthropic / `claude_code_subscription` paths

| ID | Capability | Normative requirement |
|----|------------|------------------------|
| **A1** | **API key via environment** | Operator can run the product with **`ANTHROPIC_API_KEY`** set in the process environment before startup (CI, shell export, process manager). Runtime **must** use it for Messages API auth when no higher-precedence bearer source is active per §2.7.4. |
| **A2** | **Bearer via environment** | Operator can run with **`ANTHROPIC_AUTH_TOKEN`** set (OAuth access token or other bearer accepted by Anthropic’s API for the configured endpoint). |
| **A3** | **Interactive Claude.ai OAuth** | Operator can invoke a **login flow** (reference: slash command **`/login`**) that completes **browser- or device-style OAuth** against Claude.ai / Anthropic’s OAuth endpoints, obtains tokens, and **activates** subscription-class API access **without** writing those secrets into SQLite or `settings_snapshot`. Tokens **may** reside in OS secure storage or equivalent (keychain, credential manager, encrypted file outside `AGENT_SDLC_DB`). |
| **A4** | **Logout** | Operator can invoke **logout** (reference: **`/logout`**) that clears **Claude.ai–sourced** OAuth session material from secure storage / process caches so the next run does not silently reuse the prior account unless re-authenticated. |
| **A5** | **Auth status** | Operator can inspect **whether** the process has usable Anthropic-class credentials and **which class** (e.g. env API key vs OAuth vs none)—reference: **`/status`** or equivalent **must** exist and **must not** print full secrets. |
| **A6** | **apiKey helper script** | If settings support **`apiKeyHelper`** (reference: configured helper that prints a key to stdout), runtime **may** invoke it **only** before model calls, **must not** persist returned material to SQLite, and **must** treat failure as `authentication_failed` / configuration error. **Forbidden** running helper before workspace trust if reference forbids it. |
| **A7** | **Bare / hermetic mode** | If product supports **`--bare`** (reference), in that mode **only** `ANTHROPIC_API_KEY` and/or **`apiKeyHelper`** (from designated settings path) **may** supply Anthropic credentials; OAuth and keychain paths **must** be disabled as in reference `isBareMode()` semantics. |

#### 2.7.2 `openai_compatible`

| ID | Capability | Normative requirement |
|----|------------|------------------------|
| **O1** | **API key + base URL** | Operator can set **`OPENAI_API_KEY`** and **`OPENAI_BASE_URL`** via environment (or platform equivalent that injects env **before** turn boundary). **Forbidden** storing values in SQLite. |

#### 2.7.3 `lm_studio_local`

| ID | Capability | Normative requirement |
|----|------------|------------------------|
| **L1** | **Local endpoint + model id** | Operator can set **`LM_STUDIO_BASE_URL`**, **`LM_STUDIO_API_KEY`** (optional), **`LM_STUDIO_MODEL`** per §2.3 via environment (or env injection only). |

#### 2.7.4 Precedence among Anthropic-class sources (normative)

When **multiple** sources could apply, resolution **must** match reference **`getAuthTokenSource()`** / **`getAnthropicApiKeyWithSource()`** ordering unless this document explicitly forks a step. **SDLC fork:** whatever source wins **must** expose the effective credential to the HTTP client **only** via memory / env for the request; **never** persist the secret into `AGENT_SDLC_DB`.

#### 2.7.5 Features that require Claude.ai OAuth (informative binding)

If the product ships **teleport / bridge / claude.ai web session** features (reference: `utils/teleport/*`), those code paths **must** refuse to proceed with API-key-only auth where reference requires OAuth—error text **must** direct the operator to **`/login`** (or product’s equivalent of **A3**).

### 2.8 Credential storage & prohibition (normative)

1. **Forbidden:** `INSERT` or `UPDATE` of API keys, OAuth access/refresh tokens, raw `Authorization` headers, or `apiKeyHelper` output into **`AGENT_SDLC_DB`**, **`settings_snapshot`**, **`transcript_entries`**, hook stdin, or hook stdout persistence.  
2. **Allowed:** OS secure storage, env vars, short-lived process memory, file-descriptor handoff from parent (reference: `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`), and managed-launcher injection (`CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_UNIX_SOCKET` proxy)—**provided** secrets never land in §4 transactional tables.  
3. **Refresh:** If OAuth refresh is implemented, refresh tokens **must** stay in secure storage only; refreshed access token **may** replace process/session memory until exit.  
4. **Logging:** Telemetry **must not** emit full keys or bearer tokens (reference safeguards apply).

### 2.9 REPL operator surface — reference command parity (normative)

Per `SPEC_AUTHORING_RULES.md`, operator chrome **not** enumerated in **§2.7–2.8** **defaults to reference parity** with Claude Code. The interactive REPL **must** implement the **built-in slash commands** from reference (trace: `code.claude.com/docs/en/commands` and reference `commands/` / dispatch), **including** discovery (**`/`** menu, filter-as-you-type if reference does), **unless** a command is **explicitly forked or omitted** in **§17** with a **closed** row (**omit** | **replace with …**).

**Minimum commands that must be fully functional on first delivery (non-exhaustive; full set = reference parity minus §17 forks):**

| Command | Requirement |
|---------|----------------|
| **`/help`** | Lists or filters available commands per reference. |
| **`/model [model]`** | Changes **active wire model** (and provider when applicable) **without** process restart; effect timing **matches reference** (immediate). |
| **`/login`**, **`/logout`**, **`/status`** | Satisfy **§2.7 A3–A5**; **must not** print full secrets (**A5**). |
| **`/config`** and/or **`/settings`** | Operator can change model and other **session-relevant** preferences per reference (**alias rules** per reference). |
| **`/clear`** (and aliases **`/reset`**, **`/new`** if reference) | Clears conversation per reference; emits hooks (**SessionEnd** / **SessionStart** or reference-equivalent) consistent with §3. |

**Forbidden:** Project JSON under a dot-directory as the **only** supported way to switch **model** or **provider** when reference exposes **`/model`** or equivalent in-session control.

### 2.10 Provider backends — each enum is live (normative)

Each **`provider`** value in **§2.1** **must** be **fully operational** in the one-shot binary: with valid **§2.3** env (and **§2.2** `model_id`), the operator completes **at least one** full turn (user → model → optional tools → persisted transcript) **without** undocumented side channels.

**Forbidden:** shipping a **§2.1** enum value that **cannot** be selected and exercised end-to-end.

---

## 3. Hook events (closed set, case-sensitive)

**Set** of event names (same as reference `HOOK_EVENTS` in `coreSchemas.ts`; order in source array may differ):

`PreToolUse` | `PostToolUse` | `PostToolUseFailure` | `PermissionDenied` | `Notification` | `UserPromptSubmit` | `SessionStart` | `SessionEnd` | `Stop` | `StopFailure` | `SubagentStart` | `SubagentStop` | `PreCompact` | `PostCompact` | `PermissionRequest` | `Setup` | `TeammateIdle` | `TaskCreated` | `TaskCompleted` | `Elicitation` | `ElicitationResult` | `ConfigChange` | `InstructionsLoaded` | `WorktreeCreate` | `WorktreeRemove` | `CwdChanged` | `FileChanged`

**Normative `HookInputSchema` union order** (Appendix A, stdin, and `scripts/verify-sdlc-hook-order.mjs`) is the **`z.union([...])` order** under `HookInputSchema`, not the `HOOK_EVENTS` array order.

---

## 4. Storage: single SQLite database

### 4.1 Location

- **Env:** `AGENT_SDLC_DB` — absolute path to the SQLite file.  
- **Required:** `PRAGMA foreign_keys = ON;` on every connection.  
- **Journal:** `PRAGMA journal_mode = WAL;`

### 4.2 Schema version

```sql
CREATE TABLE IF NOT EXISTS schema_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- Init: INSERT INTO schema_meta(key,value) VALUES ('schema_version','1');
```

### 4.3 Unified DDL (normative)

```sql
PRAGMA journal_mode = WAL;

CREATE TABLE schema_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE conversations (
    id              TEXT PRIMARY KEY,
    project_dir     TEXT NOT NULL,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    last_active     TEXT NOT NULL DEFAULT (datetime('now')),
    phase           TEXT NOT NULL DEFAULT 'idle'
);

CREATE TABLE sessions (
    session_id      TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id),
    started_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE state (
    conversation_id TEXT NOT NULL,
    key             TEXT NOT NULL,
    value           TEXT,
    updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (conversation_id, key)
);

CREATE TABLE plans (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT NOT NULL,
    file_path       TEXT,
    content         TEXT NOT NULL,
    hash            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'draft',
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    approved_at     TEXT,
    completed_at    TEXT
);

CREATE TABLE summaries (
    conversation_id TEXT PRIMARY KEY REFERENCES conversations(id),
    content         TEXT NOT NULL,
    word_count      INTEGER NOT NULL,
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT NOT NULL,
    session_id      TEXT,
    timestamp       TEXT NOT NULL DEFAULT (datetime('now')),
    event_type      TEXT NOT NULL,
    detail          TEXT
);

CREATE TABLE task_ratings (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT NOT NULL,
    rating          INTEGER NOT NULL,
    objective       TEXT,
    timestamp       TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE memories (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    title TEXT NOT NULL,
    content TEXT,
    keywords TEXT,
    anticipated_queries TEXT,
    concept_tags TEXT,
    project_scope TEXT,
    correction_count INTEGER DEFAULT 1,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    last_accessed INTEGER,
    access_count INTEGER DEFAULT 0,
    attention_score REAL DEFAULT 0.5
);

CREATE VIRTUAL TABLE memories_fts USING fts5(
    title, content, keywords, anticipated_queries,
    tokenize='porter unicode61'
);

CREATE TABLE transcript_entries (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      TEXT NOT NULL REFERENCES sessions(session_id),
    sequence        INTEGER NOT NULL,
    parent_entry_id INTEGER REFERENCES transcript_entries(id),
    entry_type      TEXT NOT NULL,
    payload_json    TEXT NOT NULL,
    tool_use_id     TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(session_id, sequence)
);

CREATE INDEX idx_transcript_session ON transcript_entries(session_id, sequence);

CREATE TABLE hook_invocations (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id     TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    hook_event     TEXT NOT NULL,
    hook_ordinal   INTEGER NOT NULL,
    matcher        TEXT NOT NULL,
    command        TEXT NOT NULL,
    tool_use_id    TEXT,
    tool_name      TEXT,
    input_json     TEXT NOT NULL,
    exit_code      INTEGER,
    stdout_text    TEXT,
    stderr_text    TEXT,
    started_at     TEXT NOT NULL,
    completed_at   TEXT,
    skipped_reason TEXT
);

CREATE INDEX idx_hook_inv_session ON hook_invocations(session_id, hook_ordinal);

CREATE TABLE tool_permission_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      TEXT NOT NULL,
    tool_use_id     TEXT NOT NULL,
    tool_name       TEXT NOT NULL,
    decision        TEXT NOT NULL,
    reason_json     TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE settings_snapshot (
    scope      TEXT PRIMARY KEY,
    json       TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
```

**FTS (normative):** After any `memories` write in a transaction:

```sql
DELETE FROM memories_fts;
INSERT INTO memories_fts(title, content, keywords, anticipated_queries)
SELECT title, content, keywords, anticipated_queries FROM memories;
```

### 4.4 Bootstrap import

At process start **only**, **may** read `settings.json` (or equivalent) once, then `INSERT OR REPLACE INTO settings_snapshot(scope,json,updated_at) VALUES ('effective', :json, datetime('now'))`. Effective JSON **may** include `model_config` (§2.2) **without** secrets. **Forbidden:** mid-turn re-read of project settings file. During a turn, hooks and permissions read **`settings_snapshot`** only.

### 4.5 Transcript

- One row per logical message/record in `transcript_entries`.  
- `sequence`: integer ≥ 0, strictly increasing per `session_id`, step 1.  
- `entry_type` closed set: `user` | `assistant` | `system` | `tool_use` | `tool_result` | `progress` | `attachment` | `internal_hook` | `content_replacement` | `collapse_commit` | `file_history_snapshot` | `attribution_snapshot` | `queue_operation` | `speculation_accept` | `ai_title`  
- `payload_json`: UTF-8 JSON per Appendix C.

### 4.6 Plans

Authoritative plan body: `plans.content`. **Forbidden:** authoritative plan text from filesystem glob of `plans/` or `~/.claude/plans/`. `plans.file_path` is non-authoritative hint only.

`plans.status` **closed enum:** `draft` | `approved` | `completed` | `superseded`. **§8** transition to `implement` requires `status = 'approved'`.

**Plan approval gate (mechanical):** Before setting `status = 'approved'`, the runtime **must** parse the plan's success criteria section and verify that **every** criterion includes a `[template: tool_contract|phase_transition|hook_contract|e2e_workflow]` tag. Plans with any untagged criterion **must** be rejected with a descriptive error. This is **not** a human review step — it is a machine validation that runs before the plan can be approved.

### 4.7 Memories

Ranking/import rules: align with operator `ARCHITECTURE.md` where cited. **Forbidden:** runtime authoritative reads from `shared-memory/*.md`; offline import into `memories` allowed.

### 4.8 Concurrency and transaction boundaries (normative)

**Writer model:** At most **one** in-process writer transaction against `AGENT_SDLC_DB` at a time (mutex or single connection with exclusive write). **Forbidden:** two concurrent writers without explicit locking.

**Reader connections:** **May** be multiple **read** connections **only if** writers use `BEGIN IMMEDIATE` (or equivalent) so readers see consistent snapshots; **recommended** single connection for simplicity.

**Pragmas:** Every connection: `PRAGMA foreign_keys=ON;`, `PRAGMA journal_mode=WAL;`, `PRAGMA busy_timeout=30000;` (milliseconds, **closed** default).

**Normative `COMMIT` groupings:**

| Operation | Must be atomic in one transaction |
|-----------|-----------------------------------|
| Single hook tool turn | All `hook_invocations` rows for that tool fire + related `transcript_entries` (`tool_result`, etc.) the runtime appends for that `tool_use_id` before any other session observes the next model step. |
| Orchestration iteration §2.5 | After step 6–7, commit before step 4’s next model call all transcript rows and hook rows from that iteration. |
| `memories` + FTS | §4.3 rebuild in **same** transaction as triggering `memories` write. |
| Phase change §8 | `UPDATE conversations` for `phase` + any related `events` / `plans` rows required by the transition rule, **one** `COMMIT`. |

**Isolation:** Rely on SQLite single-writer + WAL; **no** `BEGIN` nesting required beyond savepoints for internal helpers.

---

## 5. Hook plane (normative, deterministic)

### 5.1 Matcher → query (reference behavior)

| `hook_event_name` | Match query source |
|-------------------|-------------------|
| `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `PermissionDenied` | `tool_name` |
| `SessionStart` | `source` |
| `Setup`, `PreCompact`, `PostCompact` | `trigger` |
| `Notification` | `notification_type` |
| `SessionEnd` | `reason` |
| `StopFailure` | string form of `error` |
| `SubagentStart`, `SubagentStop` | `agent_type` |
| `Elicitation`, `ElicitationResult` | `mcp_server_name` |
| `ConfigChange` | `source` |
| `InstructionsLoaded` | `load_reason` |
| `FileChanged` | basename of `file_path` |
| `TeammateIdle`, `TaskCreated`, `TaskCompleted` | *(empty — only `""` / `*` matchers)* |

**Matcher rules:** `""` or `*` → any. If matcher matches `^[a-zA-Z0-9_|]+$` and contains `|` → split on `|`, exact match set. Else **ECMAScript `RegExp`** (not PCRE); invalid regex → matches nothing.

### 5.2 Hook ordinal (total order)

Starting at **0**: (1) snapshot matchers — JSON array order in `settings_snapshot`; per matcher, `hooks[]` order. (2) Plugins — `plugin_id` ascending Unicode; same inner order. (3) Session-scoped — insertion order with monotonic counter.

**Dedup:** Collapse adjacent identical `(hook_event, matcher, command, shell, if_condition)` keeping first. `shell` default `bash`; `if_condition` default `""`.

### 5.3 Sequential execution

Hooks run one at a time ascending `hook_ordinal`. **Fork policy:** no parallel hook **outcome** aggregation for PreToolUse blocking semantics.

### 5.4 Exit codes (command hooks)

| Code | Meaning |
|------|---------|
| `0` | Success; if stdout starts with `{`, parse JSON; else plain success |
| `2` | Blocking (PreToolUse / `UserPromptSubmit` where applicable) — §5.6 |
| other | Non-blocking failure — log, continue chain |

### 5.5 JSON stdout validation

Must be one JSON value matching Appendix B. **`async: true` → invalid control** for SDLC (§5.8).

### 5.6 Blocking and permission merge (**fork policy**)

`agg_permission` ∈ `unset` | `allow` | `ask` | `deny` — merge: `deny` > `ask` > `allow` > `unset`.  
`agg_blocks`: list of `{ ordinal, stderr_text }` for exit `2`.

1. Apply `hookSpecificOutput.permissionDecision` for `PreToolUse` into `agg_permission`.  
2. On exit `2`, append `agg_blocks`.  
3. **PreToolUse:** if `agg_permission == deny` or `agg_blocks` non-empty → skip remaining hooks for this tool; `skipped_reason = 'prior_block_or_deny'`.  
4. **Final:** if `agg_blocks` non-empty → deny; message = lines `"[ordinal] " + stderr` sorted by ordinal. If `deny` without block → use hook `reason` or empty.  
5. **PostToolUse / PostToolUseFailure:** never skip remainder; concatenate exit-2 messages in ordinal order.

### 5.7 PreToolUse then permission dialog

1. PreToolUse chain §5.6.  
2. **§5.12** permission rules from `settings_snapshot` only.  
3. On `ask`, human dialog + `tool_permission_log` row.

### 5.8 Async hooks (**fork policy**)

**Forbidden:** treating `{"async":true}` as valid control flow. Log validation error; exit `2` still blocks where applicable.

### 5.9 Timeouts

Default **600000 ms** for `PreToolUse` / `PostToolUse` / `PostToolUseFailure` / `UserPromptSubmit`; **1500 ms** for `SessionEnd`. Overrides: `SDLC_HOOK_TIMEOUT_MS`, `SDLC_SESSIONEND_HOOK_TIMEOUT_MS`. Timeout on PreToolUse/UserPromptSubmit → treat as exit `2`; PostToolUse timeout → non-blocking, log.

### 5.10 Trust gates

`SDLC_DISABLE_ALL_HOOKS=1` → skip hooks. Untrusted workspace / managed-only rules per operator policy.

### 5.11 Hook command execution environment (normative)

**`shell` field (closed):** `bash` (default per §5.2 dedup) | `sh` | `powershell`.

**Working directory:** Child process **`cwd` must** equal hook stdin **`cwd`** (§6). Missing directory → hook **non-blocking failure** (log, `exit_code` null, `stderr_text` explains); **do not** spawn.

**Invocation:**

| `shell` | Spawn shape (POSIX) |
|---------|---------------------|
| `bash` | `argv = ['/bin/bash', '-lc', <commandString>]` — if `/bin/bash` missing, try `/usr/bin/bash`, then invoke `bash` from `PATH`. `<commandString>` = hook `command` after any implementation-defined template substitution. |
| `sh` | `argv = ['/bin/sh', '-c', <commandString>]` with same fallbacks mutatis mutandis. |
| `powershell` | `argv = [<pwshOrPowershell>, '-NoProfile', '-NonInteractive', '-Command', <commandString>]` where executable is first found of `pwsh`, `powershell` on `PATH`. Missing → non-blocking hook failure. |

**Windows:** Implementations **must** either (a) document and implement **reference** spawn rules in `utils/hooks.ts` (`execCommandHook`, Git Bash / PowerShell split) for parity, or (b) **refuse** `bash` hooks on Windows with a clear startup error (**closed** declaration in operator docs).

**Stdin:** UTF-8, **no BOM**. Payload = JSON object for hook (common prefix §6 + event fields) serialized without extra whitespace variants requirement — **must** append **exactly one** ASCII newline `\n` after the closing `}` before `stdin.end()` (reference: `jsonInput + '\n'`).

**Stdout/stderr:** Decode as **UTF-8**; invalid bytes → U+FFFD replacement per WHATWG **UTF-8 decode** (closed). **Max capture** per stream: **4194304** bytes; if exceeded, stop reading, append `\n[SDLC_OUTPUT_TRUNCATED]\n` to stored stream text and complete process.

**Environment:** Copy **entire** host process environment at spawn. **Set or override:** `AGENT_SDLC_DB` (absolute path), `SDLC_HOOK=1`. If `LANG` or `LC_ALL` unset, set `LANG=C.UTF-8` (or implementation-defined **closed** UTF-8 locale string). **Optional reference-parity:** `CLAUDE_PROJECT_DIR` when project root is known (absolute path).

**Timeouts:** §5.9.

### 5.12 Permission rules after PreToolUse (normative)

**Config shape:** `settings_snapshot` JSON for scope `effective` **must** include optional key **`permissions`** conforming to **Appendix E**. If absent, treat as `{ "defaultMode": "default" }`.

**When evaluated:** **After** §5.6 PreToolUse hook chain yields **allow** (no deny, no exit-2 block), **and after** §8.3 planning hard gate passes, **before** starting tool execution **and before** showing the human permission dialog.

**Matching semantics (reference behavior):** Rule strings in `allow`, `deny`, `ask` **must** be validated at ingest with the same rules as `utils/settings/validation.ts` `filterInvalidPermissionRules` / `validatePermissionRule`. A candidate tool call **`ruleMatches(rule, tool_name, tool_input)`** **must** match reference outcomes for built-ins in §7 and `mcp__*` names when compared against **`utils/permissions/permissions.ts`** + per-tool `checkPermissions` in `services/tools/` (same `permissions` object, same parsed input), **with ML/auto classifier paths disabled** (`defaultMode` **must not** rely on `auto` — not in SDLC `defaultMode` enum).

**Aggregate precedence (normative fork — tie-break):** If reference and this clause disagree, **this** order applies: **(1)** any **deny** list match → **deny**; **(2)** else any **ask** list match → **ask**; **(3)** else any **allow** list match → **allow**; **(4)** else **`defaultMode`:** `bypassPermissions`→allow; `dontAsk`→deny; `default`→ask; `acceptEdits`→allow for `Read`|`Write`|`Edit` only, else ask; `plan`→deny for `Write`|`Edit`|`Bash`|`NotebookEdit`, else follow `default` behavior for others. *(Implementers **should** diff against reference for `acceptEdits`/`plan` edge cases; report as fork if changed.)*

**Persistence:** Any **ask** → user decision → row in `tool_permission_log` (§4.3).

---

## 6. Hook stdin — SDLC base (**fork policy**)

**Every** stdin object **must** include:

| Field | Type | Notes |
|-------|------|-------|
| `hook_event_name` | string | §3 |
| `session_id` | string | |
| `conversation_id` | string | FK `conversations.id` |
| `runtime_db_path` | string | equals `AGENT_SDLC_DB` |
| `cwd` | string | |
| `permission_mode` | string? | |
| `agent_id` | string? | subagent |
| `agent_type` | string? | |

**Reference field omitted (fork):** `transcript_path` — **must not** be sent or required. **Reference:** `BaseHookInputSchema` in `coreSchemas.ts`.

---

## 7. Tool taxonomy (frozen built-in names for matchers)

`Read` | `Write` | `Edit` | `NotebookEdit` | `Bash` | `Glob` | `Grep` | `WebFetch` | `WebSearch` | `AskUserQuestion` | `TodoWrite` | `TaskOutput` | `Agent` | `Skill` | `EnterPlanMode` | `ExitPlanMode` | `ListMcpResources` | `ReadMcpResource` | `ToolSearch` | `Brief` | `TaskStop`

**MCP:** `mcp__<server>__<tool>` (lowercase server slug).

### 7.1 Built-in tool execution contract (normative)

**Inputs:** Each tool receives `tool_name` (§7) and `tool_input` (JSON object). Schemas **reference behavior:** same required/optional keys as reference `tools/*` Zod/schema for that tool **unless** this spec lists a **fork**.

**Outputs:** Map to `transcript_entries` `tool_result` (Appendix C): **`content`** UTF-8 string (model-visible), **`is_error`** boolean.

**Error classification (closed):**

| Class | `is_error` | When |
|-------|------------|------|
| `success` | `false` | Tool completed its contract (file read OK, exit 0 for Bash, HTTP 2xx for fetch where applicable). |
| `tool_rejected` | `true` | Validation failed, path missing, HTTP 4xx/5xx, **Bash exit code ≠ 0**, MCP error response, subprocess signal. |
| `internal_failure` | `true` | Host crash, timeout, IPC broken — `content` **must** include prefix `[SDLC_INTERNAL]`. |

**Streams (fork caps):** For **Bash**, capture **stdout** and **stderr** separately; concatenate for `content` as `stdout + (stderr ? "\n--- stderr ---\n" + stderr : "")` capped at **1048576** bytes **each**; if truncated suffix `[SDLC_TRUNCATED]`.

**Read/Write/Edit:** `content` = short summary (path, line count, or error text). Binary files — reference behavior (encoding detection / hex).

**Glob/Grep:** `content` = UTF-8 listing; empty result `is_error: false`.

**WebFetch/WebSearch:** `is_error: true` on transport failure; success body capped at **1048576** bytes in `content` with `[SDLC_TRUNCATED]` if cut.

**MCP `mcp__*`:** JSON-RPC to server; timeout **120000** ms default (**closed**); `is_error` on timeout or error payload.

**NotebookEdit, AskUserQuestion, TodoWrite, TaskOutput, Agent, Skill, EnterPlanMode, ExitPlanMode, ListMcpResources, ReadMcpResource, ToolSearch, Brief, TaskStop:** **Reference behavior** for payloads and side effects; transcript `content` = user-visible summary string.

**Logging:** Tool internal debug **must not** write authoritative state outside §4; **may** append `events` rows.

### 7.2 Built-in tools — no partial implementations (normative)

Every name in the **§7** built-in list (pipe-separated) **must** have a **complete** implementation: for valid `tool_input` per reference schema, the runtime **must** execute the full contract and return **`tool_result`** per Appendix C and §7.1 error classes—**not** `not implemented`, **not** empty stub, **not** permanent **TODO**.

**MCP `mcp__*`:** For each MCP server **registered in effective settings** (reference configuration shape), invocations **must** complete JSON-RPC per §7.1 (**timeout 120000 ms** default) and map success/failure to **`is_error`** per §7.1.

**Interpretation of “reference behavior” in §7.1:** For a given tool, outputs and side effects **must** match reference `services/tools/*` (and related) for the same parsed input **unless** **§17** states a **fork** for that tool. **Forbidden** using “reference behavior” to justify **partial** parity.

---

## 8. SDLC workflow state and tool gating (normative **fork**)

Reference Claude Code plan/implement flows **default** for UX; this section binds **persistence and hard gates** so implementers do not invent policy.

### 8.1 `conversations.phase` (closed enum)

`conversations.phase` **must** be exactly one of:

`idle` | `planning` | `implement` | `test` | `verify` | `done`

### 8.2 Phase transitions (normative)

**Authoritative field:** **`conversations.phase` only.** **Forbidden:** treating `state` KV `phase` / `sdlc_phase` as authoritative unless kept strictly in sync; SDLC profile **does not** require a duplicate phase key in `state`.

**Persistence mechanism:** Every transition **must** execute `UPDATE conversations SET phase = :new, last_active = datetime('now') WHERE id = :conversation_id` (same column names as §4.3) in the **same** `COMMIT` as any rows that transition depends on (e.g. `plans.status`, `events`).

| From | To | Condition |
|------|-----|-----------|
| any | `planning` | Successful **EnterPlanMode** (or reference-parity equivalent). |
| `planning` | `implement` | **ExitPlanMode** (or equivalent) **and** EXISTS `plans` row for this `conversation_id` with `status = 'approved'`. |
| `implement` | `test` | Implementation complete; behavioral tests generated per **§8.5** and executed per **§8.6**. **Must** be same transaction as any `events` row recording the “implementation complete” signal. |
| `test` | `verify` | All plan-traced behavioral tests pass (**§8.6** coverage gate satisfied). |
| `verify` | `done` | Operator approves coverage report and test results (**§8.7**). |
| `done` / `idle` | `planning` | New plan cycle allowed per operator policy. |

**Forbidden:** setting `implement` from `planning` without an **approved** plan row.

**Forbidden:** transitioning directly from `implement` to `verify` or `done` — the `test` phase **must not** be bypassed.

### 8.3 Built-in tool denial during planning (normative)

When `conversations.phase = 'planning'` **and** there is **no** `plans` row for this `conversation_id` with `status = 'approved'`, the runtime **must deny** (before tool execution, same user-visible class as hook deny) the following built-in tools:

`Write` | `Edit` | `Bash` | `NotebookEdit`

**All other** built-in names in §7 and all `mcp__*` tools **may** run subject to hooks and permission rules. *(Hooks **may** further restrict; this clause is the **minimum** hard gate.)*

### 8.4 Operator workflow hooks

Policy shell hooks **should** read/write **only** `AGENT_SDLC_DB` for workflow state (**fork** vs reference MEMORY.md as authoritative store).

### 8.5 Behavioral test generation — epistemic isolation (normative)

When the product enters the `test` phase, it **must** generate behavioral tests that verify the implementation against the approved plan. The test generation process is **mechanically constrained** to prevent smoke tests, mock-the-implementation tests, and tautological assertions.

#### 8.5.1 Test generator input (closed — epistemic isolation)

The test generator **must** receive **only** the following inputs when constructing test cases:

| Allowed | Source |
|---------|--------|
| Approved plan text | `plans.content` where `status = 'approved'` for the active `conversation_id` |
| Plan success criteria | Extracted from the plan's success criteria section |
| Public interface contracts | CLI entry points, tool contracts (§7), DB schema (§4.3) |
| Project public API | Entry point signatures, documented CLI flags, published schemas |

**Forbidden inputs** for test generation context:

- Implementation source files (contents of files created or modified during `implement` phase)
- Internal function signatures, module structure, or import paths
- Git diffs, code review context, or implementation commit messages
- Runtime debug output or intermediate state from the implementation process

**Enforcement:** The test generation context **must** be constructed **without** implementation source. This is a mechanical requirement — the product **must not** feed implementation file contents into the prompt, context, or retrieval scope used to generate test cases. **Forbidden:** generating tests in the same agent context that wrote the implementation, unless that context is provably stripped of implementation source before test generation begins.

**Template requirement:** The test generator **must** select a template from the product's `templates/` directory (§8.8) and fill in the labeled slots. Freeform test scripts that do not conform to a shipped template are **forbidden**. This is the primary enforcement mechanism — epistemic isolation constrains what the generator *sees*; templates constrain what it *outputs*.

**Template selection (deterministic):** Each success criterion in the approved plan **must** include a tag in the format `[template: tool_contract|phase_transition|hook_contract|e2e_workflow]`. For each criterion, the test generator **must** read the tag and load the corresponding template file from `templates/test_<category>.sh`, then fill in the labeled slots using only the allowed inputs above. **Forbidden:** the test generator selecting a template category different from the one tagged in the plan criterion.

**Mechanical enforcement:** Plan approval (ExitPlanMode or equivalent) **must** parse the plan's success criteria and **reject** the plan if any criterion lacks a `[template: <category>]` tag. This is a machine gate, not a human review step. **Forbidden:** approving a plan where any success criterion is missing a template tag.

#### 8.5.2 Observable-only assertions (normative)

Every test assertion **must** target one of these **observable surfaces** (closed set):

| Surface | Example assertion |
|---------|-------------------|
| **DB state** | SQL query against `AGENT_SDLC_DB` returns expected rows/values |
| **File state** | File exists at expected path, contains expected content, has expected permissions |
| **Process output** | stdout/stderr of CLI invocation matches expected patterns; exit code equals expected value |
| **Tool result contract** | `{content, is_error}` per §7.1 for a given `tool_name` + `tool_input` |
| **Hook invocation record** | `hook_invocations` row exists with expected `hook_event`, `exit_code`, `tool_name` fields |

**Forbidden assertion targets:**

- Internal function return values (requires importing implementation modules)
- Object shapes or types defined in implementation source
- Private state not observable through DB, filesystem, or process output
- In-memory runtime state (variable values, object properties, closure captures)

#### 8.5.3 Anti-mock rule (normative)

The system under test **must** run its real code paths. Tests **may**:

- Set up controlled input fixtures (files, env vars, DB seed data)
- Invoke the product through its public entry points (CLI, tool dispatch)
- Inspect output through observable surfaces (§8.5.2)

Tests **must not**:

- Replace, mock, stub, or monkey-patch implementation modules or functions
- Intercept internal function calls or inject test doubles
- Use dependency injection to swap real behavior for fake behavior within the product
- Override or shadow runtime modules with test-specific replacements

**External dependency exception:** Network APIs and third-party services **may** use recorded fixtures or local test servers, but the product's own code paths **must** execute without substitution.

### 8.6 Plan traceability and coverage gate (normative)

#### 8.6.1 Plan-traced test cases

Each behavioral test case **must** reference a specific requirement from the approved plan's success criteria. The product **must** record this mapping (implementation-defined persistence — `events` rows, dedicated table, or structured test output).

Untraceable tests (setup utilities, teardown helpers, infrastructure checks) are permitted but **do not** count toward the coverage gate.

#### 8.6.2 Coverage gate (`test → verify` transition)

The transition from `test` to `verify` **must** be blocked until **all** of the following are satisfied:

1. **Every** success criterion in the approved plan has **≥ 1** plan-traced test case.
2. **All** plan-traced test cases have been executed and **pass** (exit code 0).
3. Test results are **persisted** for the `verify` phase to display (§8.7).

Missing coverage for **any** plan requirement **blocks** the transition. **Forbidden:** transitioning to `verify` with uncovered plan requirements.

### 8.7 Verify phase — coverage reporting (normative)

The `verify` phase is a **reporting surface**, not a testing gate. Test quality was enforced mechanically by §8.5; the operator reviews **results**, not test source.

The product **must** display to the operator:

1. **Coverage matrix:** plan requirement → test case(s) → pass/fail status per case.
2. **Test output:** stdout/stderr for each test case (actual results, not summaries).
3. **Uncovered requirements:** any plan success criteria without a passing traced test (should be zero if §8.6.2 gate passed; shown for transparency).
4. **Aggregate pass rate:** total traced tests, passed, failed.

Transition `verify → done` requires **operator approval** of the report.

### 8.8 Behavioral test templates (mandatory — **binding**)

The product **must** ship template files under `templates/` that the test generator fills in during the `test` phase. **Forbidden:** freeform test scripts that do not conform to a shipped template. **Forbidden:** tests that use `import`, `require`, `jest`, `vitest`, `mocha`, or any test framework.

Every generated test file **must** pass `templates/validate_test.sh` which checks: **(1)** file starts with a recognized `# TEMPLATE:` header, **(2)** `PLAN_REQ` is non-empty, **(3)** `EXERCISE` section contains an `ona` CLI invocation, **(4)** no `import`/`require`/test-framework keywords appear anywhere in the file.

#### 8.8.1 Common template structure (binding)

All templates **must** follow this skeleton:

```bash
#!/usr/bin/env bash
set -euo pipefail
# TEMPLATE: <category — one of: tool_contract | phase_transition | hook_contract | e2e_workflow>
# PLAN_REQ: <filled by generator — exact text from plan success criteria>
# SURFACE: <filled by generator — one of: db_state | file_state | process_output | tool_result | hook_record>

export AGENT_SDLC_DB="${AGENT_SDLC_DB:-/tmp/sdlc_test_$$.db}"
trap 'rm -f "$AGENT_SDLC_DB" "$AGENT_SDLC_DB-wal" "$AGENT_SDLC_DB-shm"' EXIT

# ══ SETUP ══
# <filled by generator — create fixtures, seed DB, set env vars>
# Allowed: echo/cat to create files, sqlite3 to seed DB, export for env

# ══ EXERCISE ══
# <filled by generator — invoke ona through its public CLI interface>
# Allowed: ona --eval '{"tool":"...","input":{...}}'
#          ona --transition <phase> --conversation <id>
#          echo "user input" | ona
# Forbidden: node -e "import ...", direct function calls

# ══ ASSERT ══
# <filled by generator — check observable outcome>
# Allowed: sqlite3 "$AGENT_SDLC_DB" "SELECT ...", grep, test, diff
# Forbidden: import, require, assert.equal on internal return values
# Must exit 1 with descriptive message on failure.
```

**Structural rules (mechanically enforced by `validate_test.sh`):**

| Rule | Check |
|------|-------|
| Template header present | First non-shebang comment matches `# TEMPLATE: (tool_contract\|phase_transition\|hook_contract\|e2e_workflow)` |
| Plan traceability | `# PLAN_REQ:` line is non-empty |
| CLI-only exercise | `EXERCISE` section contains `ona ` (the CLI binary) |
| No internal imports | File contains no `import `, `require(`, `from '`, `from "` |
| No test frameworks | File contains no `jest`, `vitest`, `mocha`, `describe(`, `it(`, `expect(` |
| Observable assertions | `ASSERT` section uses `sqlite3`, `grep`, `test`, or `diff` |

#### 8.8.2 Template: `tool_contract` (file: `templates/test_tool.sh`)

Tests a single built-in tool's behavioral contract per §7.1.

```bash
#!/usr/bin/env bash
set -euo pipefail
# TEMPLATE: tool_contract
# PLAN_REQ: <plan success criterion>
# SURFACE: tool_result

export AGENT_SDLC_DB="${AGENT_SDLC_DB:-/tmp/sdlc_test_$$.db}"
trap 'rm -f "$AGENT_SDLC_DB" "$AGENT_SDLC_DB-wal" "$AGENT_SDLC_DB-shm"' EXIT

# ══ SETUP ══
# <create input fixtures — files, directories, env vars>

# ══ EXERCISE ══
ona --eval '{"tool": "<TOOL_NAME>", "input": {<TOOL_INPUT_JSON>}}'

# ══ ASSERT ══
RESULT=$(sqlite3 "$AGENT_SDLC_DB" \
  "SELECT payload_json FROM transcript_entries
   WHERE entry_type='tool_result' ORDER BY sequence DESC LIMIT 1")

# Assert is_error matches expected
echo "$RESULT" | grep '"is_error":<true|false>' || { echo "FAIL: wrong is_error"; exit 1; }

# Assert content matches expected behavioral outcome
echo "$RESULT" | grep '<EXPECTED_CONTENT_PATTERN>' || { echo "FAIL: content mismatch"; exit 1; }
```

#### 8.8.3 Template: `phase_transition` (file: `templates/test_phase.sh`)

Tests a workflow phase gate per §8.2.

```bash
#!/usr/bin/env bash
set -euo pipefail
# TEMPLATE: phase_transition
# PLAN_REQ: <plan success criterion>
# SURFACE: db_state

export AGENT_SDLC_DB="${AGENT_SDLC_DB:-/tmp/sdlc_test_$$.db}"
trap 'rm -f "$AGENT_SDLC_DB" "$AGENT_SDLC_DB-wal" "$AGENT_SDLC_DB-shm"' EXIT

# ══ SETUP ══
# Initialize DB and seed conversation at starting phase
ona --init-db
sqlite3 "$AGENT_SDLC_DB" \
  "INSERT INTO conversations(id, project_dir, phase) VALUES ('<CONV_ID>', '/tmp', '<FROM_PHASE>')"

# ══ EXERCISE ══
ona --transition <TO_PHASE> --conversation <CONV_ID> 2>&1 || true

# ══ ASSERT ══
PHASE=$(sqlite3 "$AGENT_SDLC_DB" "SELECT phase FROM conversations WHERE id='<CONV_ID>'")
test "$PHASE" = "<EXPECTED_PHASE>" || { echo "FAIL: expected <EXPECTED_PHASE>, got $PHASE"; exit 1; }
```

#### 8.8.4 Template: `hook_contract` (file: `templates/test_hook.sh`)

Tests a hook event's firing and persistence per §5.

```bash
#!/usr/bin/env bash
set -euo pipefail
# TEMPLATE: hook_contract
# PLAN_REQ: <plan success criterion>
# SURFACE: hook_record

export AGENT_SDLC_DB="${AGENT_SDLC_DB:-/tmp/sdlc_test_$$.db}"
trap 'rm -f "$AGENT_SDLC_DB" "$AGENT_SDLC_DB-wal" "$AGENT_SDLC_DB-shm"' EXIT

# ══ SETUP ══
# Configure hook via settings_snapshot
ona --init-db
sqlite3 "$AGENT_SDLC_DB" \
  "INSERT OR REPLACE INTO settings_snapshot(scope, json, updated_at)
   VALUES ('effective',
   '{\"hooks\":[{\"hook_event_name\":\"<EVENT>\",\"matcher\":\"<MATCHER>\",\"command\":\"<COMMAND>\"}]}',
   datetime('now'))"

# ══ EXERCISE ══
# Trigger the hook event
<ona CLI command that triggers the event>

# ══ ASSERT ══
ROW=$(sqlite3 "$AGENT_SDLC_DB" \
  "SELECT exit_code FROM hook_invocations
   WHERE hook_event='<EVENT>' ORDER BY id DESC LIMIT 1")
test "$ROW" = "<EXPECTED_EXIT_CODE>" || { echo "FAIL: hook exit_code=$ROW, expected <EXPECTED_EXIT_CODE>"; exit 1; }
```

#### 8.8.5 Template: `e2e_workflow` (file: `templates/test_e2e.sh`)

Tests a full user journey through SDLC phases.

```bash
#!/usr/bin/env bash
set -euo pipefail
# TEMPLATE: e2e_workflow
# PLAN_REQ: <plan success criterion>
# SURFACE: db_state

export AGENT_SDLC_DB="${AGENT_SDLC_DB:-/tmp/sdlc_test_$$.db}"
trap 'rm -f "$AGENT_SDLC_DB" "$AGENT_SDLC_DB-wal" "$AGENT_SDLC_DB-shm"' EXIT

# ══ SETUP ══
ona --init-db

# ══ EXERCISE ══
# Step through workflow phases via CLI
# <sequence of ona commands — plan, implement, test, verify>

# ══ ASSERT ══
# Verify final phase
PHASE=$(sqlite3 "$AGENT_SDLC_DB" \
  "SELECT phase FROM conversations ORDER BY created_at DESC LIMIT 1")
test "$PHASE" = "<EXPECTED_FINAL_PHASE>" || { echo "FAIL: expected <EXPECTED_FINAL_PHASE>, got $PHASE"; exit 1; }

# Verify intermediate phases were recorded
PHASES=$(sqlite3 "$AGENT_SDLC_DB" \
  "SELECT detail FROM events WHERE event_type='phase' ORDER BY id")
echo "$PHASES" | grep '<EXPECTED_INTERMEDIATE_PHASE>' || { echo "FAIL: missing phase transition"; exit 1; }
```

#### 8.8.6 Non-compliant patterns (FORBIDDEN — for reference only)

```javascript
// FORBIDDEN: imports implementation module
import { toolRead } from '../lib/tools.mjs'
const result = await toolRead('/tmp/test', { file_path: 'foo.txt' })
assert.equal(result.is_error, false)
```

```bash
# FORBIDDEN: smoke test — only checks "doesn't crash"
ona --eval '{"tool": "Read", "input": {"file_path": "/tmp/anything.txt"}}'
test $? -eq 0  # passes even if tool returned wrong content
```

```bash
# FORBIDDEN: tests internal function directly
node -e "import { canTransition } from './lib/workflow.mjs'; ..."
```

---

## 9. Target repository layout

```text
agent-sdlc-runtime/
├── cmd/agent/
├── internal/
│   ├── store/
│   ├── orchestration/   # §2 turn loop
│   ├── auth/            # §2.7–2.8 login/logout/status, secure storage adapters
│   ├── hookplane/       # §5
│   ├── transcript/
│   ├── trust/
│   ├── permissions/
│   ├── workflow/        # §8 phase transitions + planning gate
│   └── session/
├── pkg/api/
├── schema.sql           # canonical DDL copy of §4.3 (optional but recommended)
└── docs/
```

**Implementation root (this repo):** `agent-sdlc-runtime/` **must** exist as the working tree for the SDLC runtime. **Forbidden:** checking in or labeling a release **complete** while the tree contains **stub** implementations for any **must** in this spec (**§0**, **§7.2**, **§18**). The leaked `claude-code` tree remains **reference only** for traceability per `SPEC_AUTHORING_RULES.md`—not a substitute for shipping the runtime.

---

## 10. Acceptance checklist

- [ ] Single DB; §4.3 tables present.  
- [ ] No authoritative session `.jsonl`.  
- [ ] No authoritative plan directory scan.  
- [ ] Hooks sequential; ordinals + skip reasons logged.  
- [ ] No valid `async:true` control path (§5.8).  
- [ ] stdin/stdout match §§6, 11–12.  
- [ ] §2 model enums + env-only secrets.  
- [ ] §2.7 **A1–A7**, **O1**, **L1** (login/logout/status/OAuth + env keys) implemented; §2.8 never persists secrets in SQLite.  
- [ ] `HookInputSchema` union order matches Appendix A event order.  
- [ ] §8 phase transitions and planning-phase mutating-tool denial enforced.  
- [ ] §8.5 behavioral test generation: epistemic isolation enforced (test generator cannot access implementation source).  
- [ ] §8.5.2 observable-only assertions: tests assert against DB state, file state, process output, tool results, or hook records only.  
- [ ] §8.5.3 anti-mock: tests exercise real code paths through public interfaces; no mocking, stubbing, or patching of implementation internals.  
- [ ] §8.6.1 plan traceability: every test case traces to a plan success criterion.  
- [ ] §8.6.2 coverage gate: `test → verify` blocked until all plan requirements have ≥1 passing traced test.  
- [ ] §8.7 verify-as-reporting: coverage matrix, test output, uncovered requirements, and aggregate pass rate displayed before `done`.  
- [ ] §8.2 no bypass: direct `implement → verify` transition forbidden; `test` phase mandatory.  
- [ ] `pnpm exec node ../scripts/verify-sdlc-hook-order.mjs` passes (or equivalent invocation from repo root).  
- [ ] §5.11 hook spawn, stdin newline, UTF-8, env, 4 MiB cap.  
- [ ] §5.12 + Appendix E permission evaluation order.  
- [ ] §7.1 tool outcomes + caps.  
- [ ] §4.8 transaction groupings + single-writer rule.  
- [ ] **§0** — no stub/TODO/`not implemented` on any normative **must**; no silent subsetting vs reference.  
- [ ] **§2.9** — `/model`, `/help`, `/login`, `/logout`, `/status`, `/config` or `/settings`, `/clear` (and reference aliases) **functional**; **not** model-switch-via-hand-edited JSON only.  
- [ ] **§2.10** — every **§2.1** provider value end-to-end invokable with **§2.2–2.3**.  
- [ ] **§7.2** — every **§7** built-in tool + configured MCP tools **functional** per §7.1.  
- [ ] **Appendix F** — `docs/ACCEPTANCE_MATRIX.md`, `docs/OPERATOR_COLD_START.md`, `scripts/sdlc-acceptance.sh` present; **all** matrix rows **PASS**; CI runs acceptance script on delivery branch.

---

## 11. Appendix A — Hook stdin JSON (every event)

**Common prefix (all events):** §6 fields, plus event-specific fields below.  
**Union order** matches `HookInputSchema` in `coreSchemas.ts`.

### PreToolUse

`tool_name` string; `tool_input` unknown JSON; `tool_use_id` string.

### PostToolUse

`tool_name`; `tool_input`; `tool_response` unknown; `tool_use_id`.

### PostToolUseFailure

`tool_name`; `tool_input`; `tool_use_id`; `error` string; `is_interrupt` boolean optional.

### PermissionDenied

`tool_name`; `tool_input`; `tool_use_id`; `reason` string.

### Notification

`message` string; `title` string optional; `notification_type` string.

### UserPromptSubmit

`prompt` string.

### SessionStart

`source` enum: `startup` | `resume` | `clear` | `compact`; `agent_type` string optional; `model` string optional.

### SessionEnd

`reason` enum: `clear` | `resume` | `logout` | `prompt_input_exit` | `other` | `bypass_permissions_disabled`.

### Stop

`stop_hook_active` boolean; `last_assistant_message` string optional.

### StopFailure

`error` enum: `authentication_failed` | `billing_error` | `rate_limit` | `invalid_request` | `server_error` | `unknown` | `max_output_tokens`; `error_details` string optional; `last_assistant_message` string optional.

### SubagentStart

`agent_id` string; `agent_type` string.

### SubagentStop

`stop_hook_active` boolean; `agent_id` string; `agent_transcript_path` string — **SDLC:** send **`""`** (empty); reference required path; runtime ignores for authority. `agent_type` string; `last_assistant_message` string optional.

### PreCompact

`trigger` enum: `manual` | `auto`; `custom_instructions` string nullable.

### PostCompact

`trigger` enum: `manual` | `auto`; `compact_summary` string.

### PermissionRequest

`tool_name` string; `tool_input` unknown; `permission_suggestions` array optional (elements: **PermissionUpdate**, Appendix B).

### Setup

`trigger` enum: `init` | `maintenance`.

### TeammateIdle

`teammate_name` string; `team_name` string.

### TaskCreated

`task_id` string; `task_subject` string; `task_description` string optional; `teammate_name` string optional; `team_name` string optional.

### TaskCompleted

Same fields as TaskCreated.

### Elicitation

`mcp_server_name` string; `message` string; `mode` enum optional: `form` | `url`; `url` string optional; `elicitation_id` string optional; `requested_schema` object optional (string keys, JSON values).

### ElicitationResult

`mcp_server_name`; `elicitation_id` optional; `mode` optional `form`|`url`; `action` enum: `accept`|`decline`|`cancel`; `content` object optional (string keys, JSON values).

### ConfigChange

`source` enum: `user_settings`|`project_settings`|`local_settings`|`policy_settings`|`skills`; `file_path` string optional.

### InstructionsLoaded

`file_path` string; `memory_type` enum: `User`|`Project`|`Local`|`Managed`; `load_reason` enum: `session_start`|`nested_traversal`|`path_glob_match`|`include`|`compact`; `globs` string array optional; `trigger_file_path` string optional; `parent_file_path` string optional.

### WorktreeCreate

`name` string.

### WorktreeRemove

`worktree_path` string.

### CwdChanged

`old_cwd` string; `new_cwd` string.

### FileChanged

`file_path` string; `event` enum: `change`|`add`|`unlink`.

---

## 12. Appendix B — Hook stdout JSON

**Top-level union:**

1. **Async stub (reference shape; SDLC invalid as control):** `{ "async": true, "asyncTimeout": <number optional> }` — **must** be rejected for SDLC control flow (§5.8).  
2. **Sync object** — optional fields: `continue` boolean; `suppressOutput` boolean; `stopReason` string; `decision` enum `approve`|`block`; `systemMessage` string; `reason` string; `hookSpecificOutput` object.

**`hookSpecificOutput` union order** (reference `SyncHookJSONOutputSchema` in `coreSchemas.ts`) — exactly one arm or omit:

### PreToolUse

`hookEventName`: `PreToolUse`; `permissionDecision` optional enum `allow`|`deny`|`ask`; `permissionDecisionReason` string optional; `updatedInput` object optional; `additionalContext` string optional.

### UserPromptSubmit

`hookEventName`: `UserPromptSubmit`; `additionalContext` string optional.

### SessionStart

`hookEventName`: `SessionStart`; `additionalContext` string optional; `initialUserMessage` string optional; `watchPaths` string array optional.

### Setup

`hookEventName`: `Setup`; `additionalContext` string optional.

### SubagentStart

`hookEventName`: `SubagentStart`; `additionalContext` string optional.

### PostToolUse

`hookEventName`: `PostToolUse`; `additionalContext` string optional; `updatedMCPToolOutput` any optional.

### PostToolUseFailure

`hookEventName`: `PostToolUseFailure`; `additionalContext` string optional.

### PermissionDenied

`hookEventName`: `PermissionDenied`; `retry` boolean optional.

### Notification

`hookEventName`: `Notification`; `additionalContext` string optional.

### PermissionRequest

`hookEventName`: `PermissionRequest`; `decision` object — either `{ "behavior": "allow", "updatedInput": {...}?, "updatedPermissions": [ PermissionUpdate, ... ]? }` or `{ "behavior": "deny", "message"?: string, "interrupt"?: boolean }`.

### Elicitation

`hookEventName`: `Elicitation`; `action` optional `accept`|`decline`|`cancel`; `content` object optional.

### ElicitationResult

Same discriminator fields as Elicitation.

### CwdChanged

`hookEventName`: `CwdChanged`; `watchPaths` string array optional.

### FileChanged

`hookEventName`: `FileChanged`; `watchPaths` string array optional.

### WorktreeCreate

`hookEventName`: `WorktreeCreate`; `worktreePath` string **required**.

### All other events in §3

`hookSpecificOutput` **omitted**; only top-level sync fields apply.

---

### PermissionUpdate (discriminated union `type`)

**`destination` enum:** `userSettings` | `projectSettings` | `localSettings` | `session` | `cliArg`

- `{ "type": "addRules", "rules": [ { "toolName": string, "ruleContent"?: string } ], "behavior": "allow"|"deny"|"ask", "destination": <destination> }`  
- `{ "type": "replaceRules", "rules": [...], "behavior": "allow"|"deny"|"ask", "destination": <destination> }`  
- `{ "type": "removeRules", "rules": [...], "behavior": "allow"|"deny"|"ask", "destination": <destination> }`  
- `{ "type": "setMode", "mode": "acceptEdits"|"bypassPermissions"|"default"|"dontAsk"|"plan", "destination": <destination> }`  
- `{ "type": "addDirectories", "directories": string[], "destination": <destination> }`  
- `{ "type": "removeDirectories", "directories": string[], "destination": <destination> }`  

*(Aligned with `PermissionUpdateSchema` in `coreSchemas.ts` / `permissionUpdateSchema` in `utils/permissions/PermissionUpdateSchema.ts`.)*

---

## 13. Appendix C — `transcript_entries.payload_json`

Include discriminator `"_t"` equal to `entry_type` (recommended).

| `entry_type` | Shape |
|--------------|--------|
| `user` | `{ "_t":"user", "uuid", "content": [ blocks ] }` |
| `assistant` | `{ "_t":"assistant", "uuid", "content": [ blocks ] }` |
| `tool_use` | `{ "_t":"tool_use", "id", "name", "input": {...} }` |
| `tool_result` | `{ "_t":"tool_result", "tool_use_id", "content", "is_error": boolean }` |
| `system` | `{ "_t":"system", "subtype", ... }` |
| `progress` | `{ "_t":"progress", "data": {...} }` |
| `attachment` | `{ "_t":"attachment", "attachment": {...} }` |
| others | `{ "_t": <entry_type>, ... }` |

**Content blocks (closed):**

- `{ "type": "text", "text": string }`  
- `{ "type": "tool_use", "id": string, "name": string, "input": object }`  
- `{ "type": "tool_result", "tool_use_id": string, "content": string, "is_error": boolean }`

---

## 14. Appendix D — Reference engine (non-normative)

Leaked tree locations (informative): `utils/hooks.ts`, `entrypoints/sdk/coreSchemas.ts`, `services/tools/toolExecution.ts`, `types/hooks.ts`. **Do not** reintroduce parallel hook races, JSONL transcript authority, or async hook completion as SDLC **normative** behavior.

---

## 15. Appendix E — `settings_snapshot.permissions` (normative)

Embedded under `settings_snapshot.json` for scope `effective`, key **`permissions`**. All listed fields **optional** unless noted. Extra keys **may** be ignored (forward compatibility) or rejected — **implementation-defined closed** choice documented in operator runbook.

```json
{
  "allow": [ "<ruleString>", "..." ],
  "deny": [ "<ruleString>", "..." ],
  "ask": [ "<ruleString>", "..." ],
  "defaultMode": "default | acceptEdits | bypassPermissions | plan | dontAsk",
  "additionalDirectories": [ "<absoluteOrProjectRelativePath>", "..." ],
  "disableBypassPermissionsMode": "disable",
  "allowManagedPermissionRulesOnly": true
}
```

**`ruleString`:** Non-empty UTF-8 string. **Validation:** Each element **must** pass reference `validatePermissionRule` in `utils/settings/permissionValidation.ts` at load time; invalid entries **dropped** (same spirit as `filterInvalidPermissionRules` in `utils/settings/validation.ts`).

**`defaultMode` (closed):** `default` | `acceptEdits` | `bypassPermissions` | `plan` | `dontAsk`. **Forbidden in SDLC profile:** `auto` (classifier mode — not supported normatively).

**`additionalDirectories`:** Used with reference path permission logic when resolving filesystem tools — **reference behavior** for interpretation.

**Evaluation:** **§5.12**.

---

## 16. Revision authority

Edits follow **`SPEC_AUTHORING_RULES.md`** and SEP-027 **Phase 0** (process for **future** changes only). **§17** is already closed—implementers **do not** wait on SEP rows to build.

---

## 17. Closed architectural decisions (normative — **complete contract**)

These replace any “open decision” placeholders elsewhere. **Implementers SHALL follow this table.**

| ID | Decision | Binding choice |
|----|----------|----------------|
| **D1** | Authority for hook JSON vs reference Zod | **`CLEAN_ROOM_SPEC.md` is canonical** for the SDLC profile. `entrypoints/sdk/coreSchemas.ts` and `types/hooks.ts` in this repository are **reference trace** only. On conflict, **this spec wins** on items marked **fork policy**; on all other hook fields, **this spec matches** reference union order and shapes. CI **should** run `scripts/verify-sdlc-hook-order.mjs`. |
| **D2** | Multi-hook PreToolUse exit `2` / permission merge vs reference | **Fork:** **§5.6** (skip remainder on deny/block; concatenate block messages; dominance merge). **Not** reference race / last-hook-wins. |
| **D3** | Transcript one-shot level | **Fork:** Authoritative transcript is **`transcript_entries` + Appendix C** only. **No** authoritative session JSONL. `entry_type` and content blocks listed in Appendix C are the **closed** persistence set for those rows; additional `entry_type` values in the table are **opaque envelope** `payload_json` with `_t` discriminator. |
| **D4** | Workflow policy document | **Fork:** **§8** is the **normative** workflow and planning gate for this profile. There is **no** separate required `ARCHITECTURE.md` import. Operator hooks **may** add stricter policy via DB only. |
| **D5** | One-shot = usable product | **Binding:** A one-shot pass **must** yield an **operator-usable** agent (login, in-session **model change**, full §7 tool surface, all §2.1 providers live). **Forbidden** claiming “spec complete” with partial REPL commands, missing **`/model`**, or stub tools (**§0**, **§2.9–2.10**, **§7.2**). |
| **D6** | Ambiguity & silence | **Forbidden** using undefined “MVP,” “phase 2,” or spec silence to omit reference UX or §7 tools. **Only** explicit **fork policy** paragraphs or **§17** rows may waive parity; waiver **must** name the **closed** replacement or **omit** with testable acceptance. |
| **D7** | DELIVERED vs interpretation | **DELIVERED** **iff** **Appendix F** is satisfied. **Forbidden** claiming delivery when any matrix row fails, when cold-start steps exceed **§F.3**, or when open **spec-must** items remain (**§F.4**). Reviewer discretion **must not** override failed automated acceptance. |
| **D8** | `/vim`, `/terminal-setup`, `/listen` | **Omit.** UI preferences not relevant to SDLC workflow. No closed substitute. |
| **D9** | `/bug`, `/issue`, `/share` | **Omit.** Claude Code–specific feedback mechanisms. Not applicable to ona SDLC profile. |
| **D10** | `/memory` | **Omit.** Agent memories managed via Ona.md project instructions (§8.4 fork). |

---

## 18. Implementation entry (single checklist)

**Environment:** `AGENT_SDLC_DB` (required), provider env per §2.3, optional `SDLC_*` timeouts §5.9.

**Build order (all in `agent-sdlc-runtime/` unless noted):**

1. **`store`** — apply §4.3 DDL (`schema.sql` copy optional); migrations + `schema_meta`; **§4.8** pragmas + writer mutex.  
2. **`transcript`** — append/read `transcript_entries` per §4.5, Appendix C.  
3. **`session` / `workflow`** — conversations, sessions, §8 `UPDATE conversations.phase` + planning gate §8.3 before mutating tools.  
4. **`hookplane`** — §5 through **§5.11** + persist `hook_invocations`.  
5. **`orchestration`** — §2 turn loop + **§7.1** tool runner.  
6. **`permissions` / `trust`** — **Appendix E** ingest, **§5.12**, §5.7, §5.10.  
7. **`cmd/agent`** — wire **reference-parity** interactive REPL: **§2.9** slash-command surface (including **`/model`**, **`/help`**, **`/clear`**, **`/config`/`/settings`**) plus **§2.7–2.8** auth; **forbidden** shipping only a minimal slash subset. Substrate above **must** be live.  
8. **Acceptance artefacts** — implement **Appendix F** files under the implementation root; wire CI per **Hard requirements item 6**.

**Definition of done:** **DELIVERED** per **§0.5** and **Appendix F**. Concretely: **§10** **100%** checked; **`scripts/sdlc-acceptance.sh` exits 0**; operator can follow **`docs/OPERATOR_COLD_START.md`** (≤ **12** steps, **§F.3**) from clean checkout to first successful model turn **without** patching runtime source. **Forbidden:** calling the build “done” if any matrix row fails, any **must** is stubbed, or continued implementation is **required** for normative behavior.

---

## Appendix F — DELIVERED predicate (binding; **no interpretation slack**)

This appendix defines the **only** admissible sign-off for one-shot delivery. **If any clause below is unsatisfied, DELIVERED is false.**

### F.1 Artefacts (normative paths under implementation root §9)

| Artefact | Purpose |
|----------|---------|
| **`docs/ACCEPTANCE_MATRIX.md`** | **Closed** mapping: spec obligation → **objective** **PASS** criterion (script + args + **expected exit 0**, or **exact** SQL/file assertion). **Forbidden** cells: “manual review,” “TBD,” “smoke test,” “nightly only.” |
| **`docs/OPERATOR_COLD_START.md`** | **Numbered** steps only (see **§F.3**). Each step is **one** shell command or **one** UI action—**forbidden** “configure your environment” without the **exact** env keys listed. |
| **`scripts/sdlc-acceptance.sh`** | Runs **every** matrix row in a **documented order**; exits **0** iff **all** **PASS**; exits **non-zero** on first **FAIL** with **stderr** naming the matrix row id. |

**Forbidden — script sprawl:** **No** additional acceptance, “workflow,” or “smoke” **shell** drivers under `scripts/` (or elsewhere in the implementation root) that **duplicate or subset** the obligations exercised by **`scripts/sdlc-acceptance.sh`**, unless **Appendix F** and **`docs/ACCEPTANCE_MATRIX.md`** are **revised in the same change** to name the **closed** substitute script and map **every** row it replaces. **Normative automation path** for one-shot delivery is **`scripts/sdlc-acceptance.sh`** plus **`scripts/verify-sdlc-hook-order.mjs`** where **§10** / **§17 D1** require it—not ad-hoc parallel scripts.

### F.2 Minimum matrix coverage (normative — **incomplete matrix ⇒ not DELIVERED**)

`docs/ACCEPTANCE_MATRIX.md` **must** contain at least one **PASS** row (each with unique **row id**) for:

1. **Every** item in **§10** (checklist id = matrix row or explicit **closed** rollup row referencing sub-scripts).  
2. **Every** built-in name in **§7** (one row per tool).  
3. **Every** `provider` enum in **§2.1**.  
4. **Every** minimum slash command in **§2.9** table (including **`/model`**).  
5. **Every** capability id **A1–A7**, **O1**, **L1** in **§2.7**.  
6. **Every** **forbidden** in **§0** and **§2.8** that is machine-checkable (e.g. grep for secrets in DB dumps)—or a **closed** row stating **N/A** with **objective** justification (e.g. “static analysis script X proves no INSERT into transcript for api key pattern”).  
7. **Every** behavioral test requirement in **§8.5–8.7**: one row proving epistemic isolation (test generator context excludes implementation source), one row proving anti-mock (tests use no internal imports/stubs), one row proving plan traceability (each test maps to a plan requirement), one row proving the `test → verify` gate blocks on failure, one row proving `implement → verify` direct transition is rejected.  
8. **Additional rule:** Any **must** / **shall** / **forbidden** added to this spec in future revisions **must** gain a matrix row **before** **DELIVERED** may be claimed for that revision.

### F.3 Cold start bound (normative)

`docs/OPERATOR_COLD_START.md` **must** contain **≤ 12** numbered steps from **clean clone** of the implementation root through **first successful end-to-end model turn** (user input → assistant output persisted in **`transcript_entries`**). Steps **must not** require editing files under `internal/`, `cmd/`, or equivalent runtime source—only **env**, **auth**, **documented CLI**, and **one-time** schema apply if applicable.

### F.4 Open work ban (normative)

**Forbidden** tagging the build **DELIVERED** while the issue tracker (or **closed** equivalent process named in the matrix) contains **any** open item of type **`spec-must`** (or the **closed** label named in the matrix header) that maps to a **must** in this spec. **Merge / release gates must block** on failed **§F.1** script or open **`spec-must`**.

### F.5 Reviewer authority (normative)

Human review **may** reject on policy grounds **in addition to** automation; human review **must not** waive a **failed** **`sdlc-acceptance.sh`** run or a missing **§F.2** row. **DELIVERED** is a **logical AND** of automation and artefact completeness—not a vote.

---

*End of specification.*
