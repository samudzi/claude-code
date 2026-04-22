# Acceptance Script Spec — `scripts/sdlc-acceptance.sh`

## Cursor Prompt

You are implementing `scripts/sdlc-acceptance.sh` for the ona-code project. Read `/Users/shingi/Workbench/claude-code/CLEAN_ROOM_SPEC.md` — that is the normative spec. This document is your implementation contract. Do not read any implementation source under `ona-code/lib/` or `ona-code/bin/`. You are epistemically isolated from the implementation. Write only `scripts/sdlc-acceptance.sh`. Every test invokes the `ona` binary or `sqlite3` as an external black box. No importing Node modules. No reading implementation source. If a test cannot be written as an external CLI check, flag it and skip — do not fake it.

---

## Purpose

Bash script that verifies every normative `must` in CLEAN_ROOM_SPEC.md through external black-box checks. Invokes the `ona` CLI binary and `sqlite3` only. Never imports implementation modules. Exits 0 iff all rows pass. Exits non-zero on first failure, printing the row ID to stderr.

## Environment

- `AGENT_SDLC_DB` — set to a temp file per run, cleaned up on exit via trap
- `ONA` — path to the ona binary (default: `$(dirname $0)/../bin/agent.mjs`)
- `TMPDIR` / temp directory for test fixtures (files, dirs), cleaned up on exit
- Script sets `set -euo pipefail`
- Every `sqlite3` call targets `$AGENT_SDLC_DB` directly — no Node, no module imports

## Test mechanics

Each row:
1. Prints `[ROW-XX] description`
2. Sets up fixtures if needed (temp files, env vars, DB seed via `sqlite3 $DB "INSERT..."`)
3. Invokes `ona` via pipe (`echo "input" | node $ONA`) or `sqlite3` for DB assertions
4. Asserts against stdout, stderr, exit code, or DB state queried via `sqlite3`
5. On pass: prints `  PASS: ROW-XX`
6. On fail: prints `  FAIL: ROW-XX` to stderr and exits 1 immediately

Summary line at end: `=== Results: N passed, 0 failed ===`

## Helper pattern

```bash
run_check() {
  local row_id="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1)); echo "  PASS: $row_id"
  else
    echo "  FAIL: $row_id" >&2; exit 1
  fi
}
```

All `ona` invocations: `echo "commands" | node "$ONA" 2>&1` — piped input, captured output. Never interactive.

---

## Row inventory

Every row below is required. Row IDs are stable identifiers. Rows map to CLEAN_ROOM_SPEC.md sections per the `Spec` column.

---

### §4 — Storage

| Row | Spec | What to check | How |
|-----|------|---------------|-----|
| ROW-01 | §4.3 | All 13 DDL tables exist | `sqlite3 $DB ".tables"` output contains: `schema_meta`, `conversations`, `sessions`, `state`, `plans`, `summaries`, `events`, `task_ratings`, `memories`, `transcript_entries`, `hook_invocations`, `tool_permission_log`, `settings_snapshot` |
| ROW-02 | §4.2 | Schema version is 1 | `sqlite3 $DB "SELECT value FROM schema_meta WHERE key='schema_version'"` outputs `1` |
| ROW-03 | §4.8 | foreign_keys ON | `sqlite3 $DB "PRAGMA foreign_keys"` outputs `1` |
| ROW-04 | §4.8 | WAL mode | `sqlite3 $DB "PRAGMA journal_mode"` outputs `wal` |
| ROW-05 | §4.8 | busy_timeout 30000 | `sqlite3 $DB "PRAGMA busy_timeout"` outputs `30000` |
| ROW-06 | §4.5 | Transcript sequences start at 0, increment by 1 | After a turn via piped input, query `SELECT sequence FROM transcript_entries ORDER BY sequence` — values must be `0, 1, 2, ...` with no gaps |
| ROW-07 | §4.5 | entry_type values are in closed set | After a turn, query `SELECT DISTINCT entry_type FROM transcript_entries` — every value must be one of: `user`, `assistant`, `system`, `tool_use`, `tool_result`, `progress`, `attachment`, `internal_hook`, `content_replacement`, `collapse_commit`, `file_history_snapshot`, `attribution_snapshot`, `queue_operation`, `speculation_accept`, `ai_title` |
| ROW-08 | §4.6 | Plans table has correct status enum | `sqlite3 $DB "INSERT INTO plans(conversation_id,content,hash,status) VALUES ('test','test','abc','invalid')"` — should succeed (SQLite doesn't enforce enums) but query plans and check only spec values accepted by the application: `draft`, `approved`, `completed`, `superseded` |

### §2 — Providers and models

| Row | Spec | What to check | How |
|-----|------|---------------|-----|
| ROW-10 | §2.10 | lm_studio_local provider is live | Start a mock HTTP server (`python3 -m http.server` or inline, returns valid SSE chat completion response on `/v1/chat/completions`). Set model via piped `/model test-model`, then send a message. Verify `sqlite3 $DB "SELECT COUNT(*) FROM transcript_entries WHERE entry_type='assistant'"` ≥ 1 |
| ROW-11 | §2.10 | claude_code_subscription rejects bad auth gracefully | `ANTHROPIC_API_KEY=sk-ant-invalid` + piped `/model claude_sonnet_4` + message. Stdout/stderr must contain auth/error text, NOT `unknown provider` or unhandled crash. Exit code is non-zero or output indicates failure. |
| ROW-12 | §2.10 | openai_compatible rejects bad endpoint gracefully | `OPENAI_BASE_URL=http://127.0.0.1:1/v1 OPENAI_API_KEY=test` + piped `/model gpt_4o` + message. Output must contain connection error text, NOT crash. |
| ROW-13 | §2.2 | Wire model strings correct | Seed `settings_snapshot` via `sqlite3` with each provider/model_id pair, then query. Check: `claude_sonnet_4` → boot output contains `claude-sonnet-4-20250514`; `gpt_4o` → output contains `gpt-4o`. |
| ROW-14 | §2.3 | LM Studio defaults | With no `LM_STUDIO_BASE_URL` set, the default `http://127.0.0.1:1234/v1` is used. Verify by attempting a connection (will fail if no server, but error message must reference `127.0.0.1:1234`). |

### §2.7 — Auth capabilities

| Row | Spec | What to check | How |
|-----|------|---------------|-----|
| ROW-20 | A1 | API key from env used | `ANTHROPIC_API_KEY=sk-ant-testkey` + piped `/status`. Output contains `api_key` as kind/source. |
| ROW-21 | A2 | Bearer from env used | `ANTHROPIC_AUTH_TOKEN=test-bearer` + piped `/model claude_sonnet_4` + `/status`. Output contains `bearer` or `oauth`. |
| ROW-22 | A4 | Logout clears credentials | Pipe `/login` sequence to store a test key, then `/logout`. Verify `~/.ona/secure/anthropic.json` does not exist OR is empty. Use a temp `$ONAHOME` to isolate. |
| ROW-23 | A5 | Status never prints secrets | Set `ANTHROPIC_API_KEY=sk-ant-secret99`. Pipe `/status`. Grep output for `sk-ant-secret99` — must NOT appear. |
| ROW-24 | A7 | Bare mode disables bearer | `ANTHROPIC_AUTH_TOKEN=test-bearer` + `ona --bare` + `/status`. Output must NOT show bearer/oauth — only API key or none. |
| ROW-25 | §2.8 | No secrets in any DB table | Set `ANTHROPIC_API_KEY=sk-ant-secret42`, run a turn (will fail, fine). Dump all tables: `sqlite3 $DB ".dump"`. Grep for `sk-ant-secret42` — zero matches. |

### §2.9 — REPL commands

| Row | Spec | What to check | How |
|-----|------|---------------|-----|
| ROW-30 | /help | /help lists commands | `echo "/help" \| node $ONA`. Output contains strings: `model`, `login`, `logout`, `status`, `config` or `settings`, `clear`, `exit`. |
| ROW-31 | /model (show) | /model with no arg shows current and available | `echo "/model" \| node $ONA`. Output contains `Available` or lists provider names. |
| ROW-32 | /model (switch) | /model changes model immediately | `printf "/model test-qwen\n/model\n" \| node $ONA`. Second /model output contains `test-qwen`. |
| ROW-33 | /model (enum) | /model accepts spec enum IDs | `printf "/model claude_sonnet_4\n/model\n" \| node $ONA`. Output contains `claude_code_subscription` and `claude_sonnet_4`. |
| ROW-34 | /clear | /clear creates new session | `printf "hello\n/clear\n/exit\n" \| node $ONA`. Then `sqlite3 $DB "SELECT COUNT(DISTINCT session_id) FROM sessions"` ≥ 2. |
| ROW-35 | /clear hooks | /clear emits SessionEnd + SessionStart | After /clear with hooks configured, `sqlite3 $DB "SELECT hook_event FROM hook_invocations"` contains both `SessionEnd` and `SessionStart`. (Requires seeding a hook in settings_snapshot.) |
| ROW-36 | /config | /config shows settings | `echo "/config" \| node $ONA`. Output contains `model_config` or `provider`. |
| ROW-37 | /status | /status produces output | `echo "/status" \| node $ONA`. Output contains `ok` or `kind` or `source` (JSON fields). |
| ROW-38 | /exit | /exit terminates | `echo "/exit" \| node $ONA`. Exit code 0. |

### §5 — Hook plane

| Row | Spec | What to check | How |
|-----|------|---------------|-----|
| ROW-40 | §3 | Hook event union order (27 members) | Run `node scripts/verify-sdlc-hook-order.mjs`. Exit code 0. |
| ROW-41 | §5.3 | Hooks execute sequentially with ordinals | Seed settings_snapshot with 2 SessionStart hooks (each writes a marker file with `$SDLC_HOOK` set). Run ona. Query `sqlite3 $DB "SELECT hook_ordinal FROM hook_invocations WHERE hook_event='SessionStart' ORDER BY hook_ordinal"` — values are `0, 1`. |
| ROW-42 | §5.4 | Exit code 2 blocks (PreToolUse) | Seed a PreToolUse hook for `Bash` that does `exit 2`. Pipe a message that triggers Bash. Query `sqlite3 $DB "SELECT exit_code FROM hook_invocations WHERE hook_event='PreToolUse'"` — contains `2`. Query transcript_entries for tool_result with `is_error` true. |
| ROW-43 | §5.8 | async:true rejected | Seed a hook that outputs `{"async":true}`. Run it. Stderr or DB must show rejection. The hook result must NOT be treated as valid control. |
| ROW-44 | §5.9 | SessionEnd timeout default 1500ms | Seed a SessionEnd hook that sleeps 5s. Pipe `/exit`. The process must exit within ~3s (hook killed by timeout), not hang for 5s. |
| ROW-45 | §5.6 | Permission merge deny > ask > allow | Seed two PreToolUse hooks: first outputs `{"hookSpecificOutput":{"permissionDecision":"allow"}}`, second outputs `{"hookSpecificOutput":{"permissionDecision":"deny"}}`. Invoke a tool. Query hook_invocations — second hook may be skipped. Tool result must show denied. |
| ROW-46 | §5.11 | Hook stdin has required fields | Seed a hook that writes stdin to a file. Run ona with a message. Read the file, parse JSON. Verify fields: `hook_event_name`, `session_id`, `conversation_id`, `runtime_db_path`, `cwd`. Verify NO `transcript_path` field (fork). |
| ROW-47 | §5.11 | Hook stdin ends with newline | Same hook as ROW-46. Verify the raw file ends with `}\n` (JSON + exactly one newline). |
| ROW-48 | §5.11 | Hook env includes AGENT_SDLC_DB and SDLC_HOOK | Seed a hook: `env > /tmp/test_hook_env.txt`. Verify file contains `AGENT_SDLC_DB=` and `SDLC_HOOK=1`. |
| ROW-49 | §5.10 | SDLC_DISABLE_ALL_HOOKS=1 skips hooks | Seed hooks. Run with `SDLC_DISABLE_ALL_HOOKS=1`. Query `sqlite3 $DB "SELECT COUNT(*) FROM hook_invocations"` — must be 0. |

### §5.12 — Permissions

| Row | Spec | What to check | How |
|-----|------|---------------|-----|
| ROW-50 | §5.12 | deny > ask > allow precedence | Seed settings_snapshot with `{"permissions":{"deny":["Bash"],"allow":["Read"],"defaultMode":"default"}}`. Invoke Bash tool — must be denied (tool_result is_error true, or tool_permission_log has deny). Invoke Read — must be allowed. |
| ROW-51 | §5.12 | defaultMode bypassPermissions | Seed `{"permissions":{"defaultMode":"bypassPermissions"}}`. Invoke any tool — no ask prompt, tool executes. |
| ROW-52 | §5.12 | defaultMode plan denies mutating | Seed `{"permissions":{"defaultMode":"plan"}}`. Invoke Write — denied. Invoke Read — allowed (ask, but in pipe mode defaults to deny since no interactive). Verify via tool_permission_log or tool_result. |
| ROW-53 | §5.12 | defaultMode dontAsk denies all | Seed `{"permissions":{"defaultMode":"dontAsk"}}`. Invoke Read — denied. |

### §7 — Tools (one row per tool)

Each tool is tested by piping a message to `ona` that causes the model to invoke the tool, OR by seeding transcript_entries to simulate a tool call and checking the result. For tools that require model cooperation, seed the DB directly and invoke the tool dispatch externally via a minimal harness script that imports ONLY the binary entry point.

**Practical approach:** Create a test helper `test_tool.sh` that:
1. Seeds a conversation + session via `sqlite3`
2. Sends a crafted message through `ona` that triggers the specific tool
3. Queries transcript_entries for the tool_result row
4. Checks `payload_json` for `is_error` and `content`

For deterministic tools (Read, Write, Edit, Glob, Grep, Bash), create known fixtures and verify exact output.

| Row | Tool | What to check | How |
|-----|------|---------------|-----|
| ROW-60 | Read | Reads a known file | Create `/tmp/ona_test_read.txt` with `line1\nline2\nline3`. Trigger Read tool on it. tool_result content contains `line1` and `3 lines` (or similar). `is_error` false. |
| ROW-61 | Read (missing) | Missing file returns error | Trigger Read on `/tmp/nonexistent_ona_test`. `is_error` true. |
| ROW-62 | Write | Creates a file | Trigger Write to `/tmp/ona_test_write.txt` with content `hello`. Verify file exists and contains `hello`. `is_error` false. |
| ROW-63 | Edit | Replaces text in file | Create file with `old_text`. Trigger Edit with old_string=`old_text`, new_string=`new_text`. Read file, verify contains `new_text` not `old_text`. `is_error` false. |
| ROW-64 | Glob | Finds files | Create `/tmp/ona_glob_test/a.txt` and `/tmp/ona_glob_test/b.js`. Trigger Glob with pattern `*.txt` in that dir. Content contains `a.txt`, does not contain `b.js`. `is_error` false. |
| ROW-65 | Grep | Searches content | Create files with known text. Trigger Grep for a pattern. Content lists matching file. `is_error` false. |
| ROW-66 | Grep (no match) | Empty result is not error | Trigger Grep for pattern that matches nothing. `is_error` false. Content indicates no matches. |
| ROW-67 | Bash | Runs command | Trigger `echo hello_ona_test`. Content contains `hello_ona_test`. `is_error` false. |
| ROW-68 | Bash (fail) | Non-zero exit is error | Trigger `exit 42`. `is_error` true. |
| ROW-69 | Bash (stderr) | stderr captured | Trigger `echo err >&2`. Content contains `--- stderr ---` and `err`. |
| ROW-70 | Bash (truncation) | Output capped at 1MB | Trigger `dd if=/dev/zero bs=1048577 count=1 2>/dev/null \| base64`. Content contains `[SDLC_TRUNCATED]`. |
| ROW-71 | NotebookEdit | Edits .ipynb | Create a minimal valid .ipynb. Trigger NotebookEdit with new_source. Read file back, verify cell source changed. |
| ROW-72 | WebFetch | Fetches URL | Trigger WebFetch on a known URL (e.g. `http://example.com` or local test server). `is_error` false if reachable, true on transport failure. Content contains response text or error. |
| ROW-73 | WebSearch | Returns results | Trigger WebSearch with query `test`. `is_error` false. Content contains result text (not empty). |
| ROW-74 | EnterPlanMode | Sets phase to planning | Trigger EnterPlanMode. `sqlite3 $DB "SELECT phase FROM conversations WHERE id='...'"` = `planning`. `is_error` false. |
| ROW-75 | ExitPlanMode (no plan) | Rejects without approved plan | In planning phase, trigger ExitPlanMode with no approved plan row. `is_error` true. Content references "no approved plan". |
| ROW-76 | ExitPlanMode (with plan) | Transitions to implement | Insert an approved plan row. Trigger ExitPlanMode. Phase = `implement`. `is_error` false. |
| ROW-77 | AskUserQuestion | Returns user input | Pipe input that triggers AskUserQuestion. Since non-interactive, verify it returns something (error or the piped response). `is_error` depends on whether input available. |
| ROW-78 | Brief | Displays message | Trigger Brief with a message. `is_error` false. Content confirms display. |
| ROW-79 | TodoWrite | Saves to state table | Trigger TodoWrite. `sqlite3 $DB "SELECT COUNT(*) FROM state WHERE key LIKE 'todo:%'"` ≥ 1. |
| ROW-80 | TaskOutput | Records to events | Trigger TaskOutput. `sqlite3 $DB "SELECT COUNT(*) FROM events WHERE event_type='task_output'"` ≥ 1. |
| ROW-81 | TaskStop | Doesn't crash | Trigger TaskStop with a fake task_id. `is_error` may be true (no such process) but must not crash with unhandled exception. |
| ROW-82 | Agent | Runs sub-session | Trigger Agent with a simple prompt. `sqlite3 $DB "SELECT COUNT(DISTINCT session_id) FROM sessions"` ≥ 2 (sub-session created). |
| ROW-83 | Skill | Returns result | Trigger Skill with name `help`. `is_error` false. |
| ROW-84 | ToolSearch | Finds tools | Trigger ToolSearch with query `Read`. Content contains `Read`. |
| ROW-85 | ListMcpResources | Handles no servers | Trigger with no MCP servers configured. `is_error` false. Content indicates no servers. |
| ROW-86 | ReadMcpResource | Handles missing server | Trigger with server name `nonexistent`. `is_error` true. |

### §8 — Workflow

| Row | Spec | What to check | How |
|-----|------|---------------|-----|
| ROW-90 | §8.1 | Phase enum has 6 values | Verify by testing transitions. Seed conversation in each phase, attempt valid and invalid transitions. |
| ROW-91 | §8.2 | implement→verify blocked | Seed conversation in `implement` phase. Attempt to set phase to `verify` (via tool or direct). Must fail — must go through `test` first. |
| ROW-92 | §8.2 | implement→test allowed | Seed conversation in `implement`. Transition to `test`. `sqlite3` confirms phase = `test`. |
| ROW-93 | §8.2 | test→verify allowed | Seed conversation in `test`. Transition to `verify`. Confirm. |
| ROW-94 | §8.2 | planning→implement requires approved plan | Seed conversation in `planning` with no approved plan. ExitPlanMode must fail. Insert approved plan, retry — must succeed, phase = `implement`. |
| ROW-95 | §8.3 | Planning gate blocks mutating tools | Seed conversation in `planning`, no approved plan. Trigger Write — denied with `§8.3` reference. Trigger Read — allowed. |
| ROW-96 | §8.3 | Planning gate allows non-mutating | Same setup as ROW-95. Trigger Glob, Grep, Read — all allowed. |

### §0 — Forbidden patterns

| Row | Spec | What to check | How |
|-----|------|---------------|-----|
| ROW-100 | §0.3 | No "not implemented" responses | For each of the 21 tool names: trigger the tool with minimal/empty input. Grep all tool_result content for `not implemented` (case-insensitive). Zero matches. |
| ROW-101 | §0.3 | No "TODO" responses | Same scan for `TODO` in tool_result content. Zero matches. |
| ROW-102 | §0.2 | All 21 tool names have dispatch | For each name in the §7 list: trigger it. The response must NOT be `Unknown tool`. |

### §13 — Transcript payloads

| Row | Spec | What to check | How |
|-----|------|---------------|-----|
| ROW-110 | Appendix C | User payload has _t discriminator | After a turn, `sqlite3 $DB "SELECT payload_json FROM transcript_entries WHERE entry_type='user' LIMIT 1"` — parse JSON, verify `_t` = `user`, has `content` array. |
| ROW-111 | Appendix C | Assistant payload has _t discriminator | Same for `entry_type='assistant'` — `_t` = `assistant`, has `content` array. |
| ROW-112 | Appendix C | Tool result payload shape | For `entry_type='tool_result'` — `_t` = `tool_result`, has `tool_use_id`, `content`, `is_error`. |

---

## Total: ~60 rows

Covers: §4 storage (8), §2 providers (5), §2.7 auth (6), §2.9 commands (9), §5 hooks (10), §5.12 permissions (4), §7 tools (27), §8 workflow (7), §0 forbidden (3), §13 payloads (3).

## What this script does NOT test

- Full end-to-end model turns with real LLM APIs (requires live credentials/servers)
- OAuth browser flow (A3) — requires browser interaction
- MCP server integration with a real MCP server
- Reference UX parity for visual/interactive elements (filter-as-you-type, etc.)
- §8.5-8.8 behavioral test generation (product feature, not acceptance check)

These must be verified manually per the acceptance matrix manual rows.
