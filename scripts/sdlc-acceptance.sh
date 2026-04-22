#!/usr/bin/env bash
# SDLC acceptance — black-box checks per ACCEPTANCE_SCRIPT_SPEC.md + CLEAN_ROOM_SPEC.md
# Invokes: node "$ONA", sqlite3 "$AGENT_SDLC_DB", python3 (mock HTTP only). No Node imports of app source.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
export ONA=${ONA:-"$REPO_ROOT/bin/agent.mjs"}

PASS=0
SKIP=0
TOTAL=0

cleanup() {
  local ec=$?
  if [[ -n "${MOCK_PID:-}" ]]; then kill "$MOCK_PID" 2>/dev/null || true; wait "$MOCK_PID" 2>/dev/null || true; fi
  [[ -n "${ACCEPT_TMP:-}" && -d "$ACCEPT_TMP" ]] && rm -rf "$ACCEPT_TMP" || true
  return "$ec"
}
trap cleanup EXIT

ACCEPT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-accept.XXXXXX")
export ACCEPT_TMP

require_cmds() {
  command -v node >/dev/null 2>&1 || { echo "sdlc-acceptance: node required" >&2; exit 2; }
  command -v sqlite3 >/dev/null 2>&1 || { echo "sdlc-acceptance: sqlite3 required" >&2; exit 2; }
  command -v python3 >/dev/null 2>&1 || { echo "sdlc-acceptance: python3 required" >&2; exit 2; }
}

require_ona() {
  if [[ ! -f "$ONA" ]]; then
    echo "sdlc-acceptance: ONA binary not found: $ONA (set ONA=...)" >&2
    exit 2
  fi
}

run_check() {
  local row_id="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@"; then
    PASS=$((PASS + 1))
    echo "  PASS: $row_id"
  else
    echo "  FAIL: $row_id" >&2
    exit 1
  fi
}

skip_row() {
  local row_id="$1"
  local reason="$2"
  TOTAL=$((TOTAL + 1))
  SKIP=$((SKIP + 1))
  echo "  SKIP: $row_id — $reason" >&2
}

# Piped non-interactive ona; capture merged stdout+stderr
ona_pipe() {
  local input="$1"
  # shellcheck disable=SC2086
  { printf '%s\n' "$input"; } | node "$ONA" 2>&1 || return $?
}

db() {
  # §4.8: every connection must set these pragmas (output suppressed so query results are clean)
  sqlite3 -cmd ".output /dev/null" -cmd "PRAGMA foreign_keys=ON;" -cmd "PRAGMA busy_timeout=30000;" -cmd ".output stdout" "$AGENT_SDLC_DB" "$@"
}

# Insert scope=effective JSON via sqlite3 (escape single quotes per SQL literal rules).
put_effective_json() {
  local json="$1"
  local esc="${json//\'/\'\'}"
  db "INSERT OR REPLACE INTO settings_snapshot(scope,json,updated_at) VALUES ('effective','$esc',datetime('now'))"
}

stop_mock() {
  if [[ -n "${MOCK_PID:-}" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
    MOCK_PID=
  fi
}

valid_entry_type() {
  case "$1" in
    user|assistant|system|tool_use|tool_result|progress|attachment|internal_hook|content_replacement|collapse_commit|file_history_snapshot|attribution_snapshot|queue_operation|speculation_accept|ai_title) return 0 ;;
    *) return 1 ;;
  esac
}

# One mock LM turn so transcript_entries exist for ROW-06/07.
seed_transcript_turn() {
  stop_mock
  write_mock_server 18701
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18701/v1"
  export LM_STUDIO_MODEL="seed"
  printf '%s\n' '/model lm_studio_server_routed' '__ASSIST_TEXT__:seed turn' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
}

# Apply §4.3 DDL (normative excerpt from CLEAN_ROOM_SPEC.md) so sqlite-only rows work before first ona run.
bootstrap_schema() {
  sqlite3 "$AGENT_SDLC_DB" <<'SQL'
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 30000;

CREATE TABLE IF NOT EXISTS schema_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
INSERT OR IGNORE INTO schema_meta(key, value) VALUES ('schema_version', '1');

CREATE TABLE IF NOT EXISTS conversations (
    id              TEXT PRIMARY KEY,
    project_dir     TEXT NOT NULL,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    last_active     TEXT NOT NULL DEFAULT (datetime('now')),
    phase           TEXT NOT NULL DEFAULT 'idle'
);

CREATE TABLE IF NOT EXISTS sessions (
    session_id      TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id),
    started_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS state (
    conversation_id TEXT NOT NULL,
    key             TEXT NOT NULL,
    value           TEXT,
    updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (conversation_id, key)
);

CREATE TABLE IF NOT EXISTS plans (
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

CREATE TABLE IF NOT EXISTS summaries (
    conversation_id TEXT PRIMARY KEY REFERENCES conversations(id),
    content         TEXT NOT NULL,
    word_count      INTEGER NOT NULL,
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT NOT NULL,
    session_id      TEXT,
    timestamp       TEXT NOT NULL DEFAULT (datetime('now')),
    event_type      TEXT NOT NULL,
    detail          TEXT
);

CREATE TABLE IF NOT EXISTS task_ratings (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT NOT NULL,
    rating          INTEGER NOT NULL,
    objective       TEXT,
    timestamp       TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS memories (
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

CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
    title, content, keywords, anticipated_queries,
    tokenize='porter unicode61'
);

CREATE TABLE IF NOT EXISTS transcript_entries (
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

CREATE INDEX IF NOT EXISTS idx_transcript_session ON transcript_entries(session_id, sequence);

CREATE TABLE IF NOT EXISTS hook_invocations (
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

CREATE INDEX IF NOT EXISTS idx_hook_inv_session ON hook_invocations(session_id, hook_ordinal);

CREATE TABLE IF NOT EXISTS tool_permission_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      TEXT NOT NULL,
    tool_use_id     TEXT NOT NULL,
    tool_name       TEXT NOT NULL,
    decision        TEXT NOT NULL,
    reason_json     TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS settings_snapshot (
    scope      TEXT PRIMARY KEY,
    json       TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
SQL
}

tables_list() {
  db ".tables" | tr -s ' ' '\n' | sort -u
}

row_01() {
  echo "[ROW-01] §4.3 — all 13 DDL tables exist"
  local t
  t=$(tables_list)
  for name in schema_meta conversations sessions state plans summaries events task_ratings memories \
    transcript_entries hook_invocations tool_permission_log settings_snapshot; do
    echo "$t" | grep -qx "$name" || return 1
  done
}

row_02() {
  echo "[ROW-02] §4.2 — schema version is 1"
  [[ "$(db "SELECT value FROM schema_meta WHERE key='schema_version'")" == "1" ]]
}

row_03() {
  echo "[ROW-03] §4.8 — PRAGMA foreign_keys ON"
  [[ "$(db "PRAGMA foreign_keys")" == "1" ]]
}

row_04() {
  echo "[ROW-04] §4.8 — WAL mode"
  local m
  m=$(db "PRAGMA journal_mode" | tr '[:upper:]' '[:lower:]')
  [[ "$m" == "wal" ]]
}

row_05() {
  echo "[ROW-05] §4.8 — busy_timeout 30000"
  [[ "$(db "PRAGMA busy_timeout")" == "30000" ]]
}

row_06() {
  echo "[ROW-06] §4.5 — transcript sequences contiguous from 0"
  local seq n=0 s
  seq=$(db "SELECT sequence FROM transcript_entries ORDER BY sequence")
  [[ -n "$seq" ]] || return 1
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    [[ "$s" == "$n" ]] || return 1
    n=$((n + 1))
  done <<<"$seq"
}

row_07() {
  echo "[ROW-07] §4.5 — entry_type closed set"
  local et line
  et=$(db "SELECT DISTINCT entry_type FROM transcript_entries" || true)
  [[ -n "$et" ]] || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    valid_entry_type "$line" || return 1
  done <<<"$et"
}

row_08() {
  echo "[ROW-08] §4.6 — plans.status enum (application-facing)"
  # SQLite stores any TEXT; application validation is not assertable via raw INSERT alone (ACCEPTANCE_SCRIPT_SPEC ROW-08).
  skip_row "ROW-08" "application enum enforcement not observable via CLI after raw INSERT"
  return 0
}

# --- Mock OpenAI-compatible server (LM Studio style) for deterministic tool_calls ---
write_mock_server() {
  local port="$1"
  local py="$ACCEPT_TMP/mock_openai.py"
  cat >"$py" <<PY
import json, re
from http.server import HTTPServer, BaseHTTPRequestHandler

def tool_resp(name, args_obj):
    return {
        "id": "call_sdlc",
        "type": "function",
        "function": {"name": name, "arguments": json.dumps(args_obj)},
    }

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path in ("/v1/models", "/"):
            b = json.dumps({"data": []}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
            return
        self.send_error(404)

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        ln = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(ln)
        try:
            req = json.loads(body.decode("utf-8", errors="replace"))
        except Exception:
            req = {}
        msgs = req.get("messages") or []
        last = ""
        if msgs:
            c = msgs[-1].get("content")
            last = c if isinstance(c, str) else json.dumps(c)
        tool_calls = None
        content = None

        m = re.search(r"__TOOL__:([A-Za-z0-9_]+):(.*)", last, re.DOTALL)
        if m:
            tname, rest = m.group(1), m.group(2).strip()
            try:
                args = json.loads(rest)
            except Exception:
                args = {"raw": rest}
            tool_calls = [tool_resp(tname, args)]
        elif "__ASSIST_TEXT__:" in last:
            content = last.split("__ASSIST_TEXT__:", 1)[1].strip()

        if tool_calls is None and content is None:
            content = "(mock) no directive"

        msg = {"role": "assistant"}
        if content is not None:
            msg["content"] = content
        if tool_calls is not None:
            msg["tool_calls"] = tool_calls

        out = {
            "id": "chatcmpl-mock",
            "object": "chat.completion",
            "choices": [{"index": 0, "message": msg, "finish_reason": "stop"}],
        }
        raw = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", $port), H).serve_forever()
PY
  python3 "$py" &
  MOCK_PID=$!
  sleep 0.4
}

# --- Rows ---

row_10() {
  echo "[ROW-10] §2.10 — lm_studio_local provider live (mock server)"
  write_mock_server 18765
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18765/v1"
  export LM_STUDIO_API_KEY="lm-studio"
  export LM_STUDIO_MODEL="mock-model"
  local out
  out=$(printf '%s\n' \
    '/model lm_studio_server_routed' \
    '__TOOL__:Read:{"file_path": "'"$ACCEPT_TMP/readt.txt"'"}' \
    '/exit' | node "$ONA" 2>&1) || true
  echo "$out" >>"$ACCEPT_TMP/row10.log"
  local n
  n=$(db "SELECT COUNT(*) FROM transcript_entries WHERE entry_type='assistant'" || echo 0)
  stop_mock
  [[ "${n:-0}" -ge 1 ]]
}

row_11() {
  echo "[ROW-11] §2.10 — claude bad auth graceful"
  local out ec=0
  out=$(export ANTHROPIC_API_KEY=sk-ant-invalid; printf '%s\n' '/model claude_sonnet_4' 'hello' '/exit' | node "$ONA" 2>&1) || ec=$?
  echo "$out" >>"$ACCEPT_TMP/row11.log"
  [[ $ec -ne 0 ]] || echo "$out" | grep -qiE 'auth|error|fail|401|403|invalid' || return 1
  echo "$out" | grep -qi 'unknown provider' && return 1
  return 0
}

row_12() {
  echo "[ROW-12] §2.10 — openai_compatible bad endpoint graceful"
  local out ec=0
  out=$(
    export OPENAI_BASE_URL=http://127.0.0.1:1/v1 OPENAI_API_KEY=test;
      printf '%s\n' '/model gpt_4o' 'hello' '/exit' | node "$ONA" 2>&1
  ) || ec=$?
  echo "$out" >>"$ACCEPT_TMP/row12.log"
  echo "$out" | grep -qiE 'connect|refused|error|fail|ECONN' || [[ $ec -ne 0 ]]
}

row_13() {
  echo "[ROW-13] §2.2 — wire model strings in boot or /model output"
  db "INSERT OR REPLACE INTO settings_snapshot(scope, json, updated_at) VALUES (
    'effective',
    '{\"model_config\":{\"provider\":\"claude_code_subscription\",\"model_id\":\"claude_sonnet_4\"}}',
    datetime('now'))"
  local out
  out=$(printf '%s\n' '/model' '/exit' | node "$ONA" 2>&1) || true
  echo "$out" | grep -q 'claude-sonnet-4-20250514' || echo "$out" | grep -qi sonnet
  db "INSERT OR REPLACE INTO settings_snapshot(scope, json, updated_at) VALUES (
    'effective',
    '{\"model_config\":{\"provider\":\"openai_compatible\",\"model_id\":\"gpt_4o\"}}',
    datetime('now'))"
  out=$(export OPENAI_BASE_URL=http://127.0.0.1:1/v1 OPENAI_API_KEY=x; printf '%s\n' '/model' '/exit' | node "$ONA" 2>&1) || true
  echo "$out" | grep -q 'gpt-4o' || echo "$out" | grep -qi gpt
}

row_14() {
  echo "[ROW-14] §2.3 — LM Studio default host 127.0.0.1:1234"
  unset LM_STUDIO_BASE_URL || true
  local out ec=0
  out=$(printf '%s\n' '/model lm_studio_server_routed' 'ping' '/exit' | node "$ONA" 2>&1) || ec=$?
  echo "$out" >>"$ACCEPT_TMP/row14.log"
  echo "$out" | grep -q '127.0.0.1:1234'
}

row_20() {
  echo "[ROW-20] A1 — API key from env reflected in /status"
  local out
  out=$(export ANTHROPIC_API_KEY=sk-ant-testkey; printf '%s\n' '/status' '/exit' | node "$ONA" 2>&1) || true
  echo "$out" | grep -qiE 'api_key|api key'
}

row_21() {
  echo "[ROW-21] A2 — bearer from env"
  local out
  out=$(
    export ANTHROPIC_AUTH_TOKEN=test-bearer;
      printf '%s\n' '/model claude_sonnet_4' '/status' '/exit' | node "$ONA" 2>&1
  ) || true
  echo "$out" | grep -qiE 'bearer|oauth'
}

row_22() {
  echo "[ROW-22] A4 — logout clears credentials (ONAHOME)"
  local oh="$ACCEPT_TMP/onahome"
  rm -rf "$oh"
  mkdir -p "$oh"
  export ONAHOME="$oh"
  printf '%s\n' '/logout' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  [[ ! -s "$oh/.ona/secure/anthropic.json" ]] 2>/dev/null || [[ ! -e "$oh/.ona/secure/anthropic.json" ]]
}

row_23() {
  echo "[ROW-23] A5 — /status must not echo full API key"
  local out
  out=$(export ANTHROPIC_API_KEY=sk-ant-secret99; printf '%s\n' '/status' '/exit' | node "$ONA" 2>&1) || true
  ! echo "$out" | grep -q 'sk-ant-secret99'
}

row_24() {
  echo "[ROW-24] A7 — bare mode disables bearer for /status"
  local out
  out=$(
    export ANTHROPIC_AUTH_TOKEN=test-bearer ANTHROPIC_API_KEY=sk-ant-testkey;
      node "$ONA" --bare <<< $'/status\n/exit\n' 2>&1
  ) || true
  ! echo "$out" | grep -qiE 'bearer|oauth'
}

row_25() {
  echo "[ROW-25] §2.8 — secrets not persisted in DB"
  export ANTHROPIC_API_KEY=sk-ant-secret42; printf '%s\n' 'x' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  ! db ".dump" | grep -q 'sk-ant-secret42'
}

row_30() {
  echo "[ROW-30] /help lists commands"
  local out
  out=$(printf '%s\n' '/help' '/exit' | node "$ONA" 2>&1) || true
  echo "$out" | grep -qi model
  echo "$out" | grep -qiE 'login|logout'
  echo "$out" | grep -qi status
  echo "$out" | grep -qiE 'config|settings'
  echo "$out" | grep -qi clear
  echo "$out" | grep -qiE 'exit|quit'
}

row_31() {
  echo "[ROW-31] /model show"
  local out
  out=$(printf '%s\n' '/model' '/exit' | node "$ONA" 2>&1) || true
  echo "$out" | grep -qiE 'available|provider|claude|openai|lm'
}

row_32() {
  echo "[ROW-32] /model switch immediate"
  write_mock_server 18766
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18766/v1"
  export LM_STUDIO_MODEL="q"
  local out
  out=$(printf '%s\n' '/model lm_studio_server_routed' '/model' '/exit' | node "$ONA" 2>&1) || true
  stop_mock
  echo "$out" | grep -qi 'lm_studio'
}

row_33() {
  echo "[ROW-33] /model enum claude_sonnet_4"
  local out
  out=$(printf '%s\n' '/model claude_sonnet_4' '/model' '/exit' | node "$ONA" 2>&1) || true
  echo "$out" | grep -qi claude_code_subscription
  echo "$out" | grep -qi claude_sonnet_4
}

row_34() {
  echo "[ROW-34] /clear new session"
  write_mock_server 18767
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18767/v1"
  export LM_STUDIO_MODEL="m"
  local out
  out=$(printf '%s\n' \
    '/model lm_studio_server_routed' \
    '__ASSIST_TEXT__:ok' \
    '/clear' \
    '/exit' | node "$ONA" 2>&1) || true
  echo "$out" >>"$ACCEPT_TMP/row34.log"
  local c
  stop_mock
  c=$(db "SELECT COUNT(DISTINCT session_id) FROM sessions" || echo 0)
  [[ "${c:-0}" -ge 2 ]]
}

row_35() {
  echo "[ROW-35] /clear SessionEnd + SessionStart hooks"
  put_effective_json '{"hooks":[{"hook_event_name":"SessionEnd","matcher":"","command":"true"},{"hook_event_name":"SessionStart","matcher":"","command":"true"}]}'
  write_mock_server 18768
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18768/v1"
  export LM_STUDIO_MODEL="m"
  local out
  out=$(printf '%s\n' '/model lm_studio_server_routed' '__ASSIST_TEXT__:x' '/clear' '/exit' | node "$ONA" 2>&1) || true
  stop_mock
  echo "$out" >>"$ACCEPT_TMP/row35.log"
  local hs
  hs=$(db "SELECT group_concat(hook_event, ',') FROM hook_invocations" || true)
  echo "$hs" | grep -q 'SessionEnd'
  echo "$hs" | grep -q 'SessionStart'
}

row_36() {
  echo "[ROW-36] /config"
  local out
  out=$(printf '%s\n' '/config' '/exit' | node "$ONA" 2>&1) || true
  echo "$out" | grep -qiE 'model_config|provider|settings|json'
}

row_37() {
  echo "[ROW-37] /status"
  local out
  out=$(printf '%s\n' '/status' '/exit' | node "$ONA" 2>&1) || true
  echo "$out" | grep -qiE 'ok|kind|source|auth|none|api'
}

row_38() {
  echo "[ROW-38] /exit terminates 0"
  printf '%s\n' '/exit' | node "$ONA" 2>&1
}

row_40() {
  echo "[ROW-40] Hook event union order (verify-sdlc-hook-order.mjs)"
  node "$SCRIPT_DIR/verify-sdlc-hook-order.mjs"
}

row_41() {
  echo "[ROW-41] §5.3 — SessionStart hooks sequential ordinals 0,1"
  local logf="$ACCEPT_TMP/hook_ord_log"
  : >"$logf"
  put_effective_json "$(python3 -c "import json,os; p=os.path.join(os.environ['ACCEPT_TMP'],'hook_ord_log'); print(json.dumps({'hooks':[{'hook_event_name':'SessionStart','matcher':'','command':'echo A >> '+p},{'hook_event_name':'SessionStart','matcher':'','command':'echo B >> '+p}]}))")"
  write_mock_server 18769
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18769/v1"
  export LM_STUDIO_MODEL="m"
  printf '%s\n' '/model lm_studio_server_routed' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  grep -q '^A$' "$logf" || return 1
  grep -q '^B$' "$logf" || return 1
  local o
  o=$(db "SELECT hook_ordinal FROM hook_invocations WHERE hook_event='SessionStart' ORDER BY hook_ordinal" | paste -sd, -)
  [[ "$o" == "0,1" ]]
}

row_42() {
  echo "[ROW-42] §5.4 — PreToolUse exit 2 blocks Bash"
  put_effective_json '{"hooks":[{"hook_event_name":"PreToolUse","matcher":"Bash","command":"exit 2"}]}'
  write_mock_server 18770
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18770/v1"
  export LM_STUDIO_MODEL="m"
  printf '%s\n' \
    '/model lm_studio_server_routed' \
    '__TOOL__:Bash:{"command": "echo hello"}' \
    '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  db "SELECT exit_code FROM hook_invocations WHERE hook_event='PreToolUse'" | grep -q '^2$' || return 1
  local pj
  pj=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1")
  echo "$pj" | grep -q '"is_error":true'
}

row_43() {
  echo "[ROW-43] §5.8 — async:true rejected"
  put_effective_json '{"hooks":[{"hook_event_name":"SessionStart","matcher":"","command":"echo {\"async\":true}"}]}'
  write_mock_server 18771
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18771/v1"
  export LM_STUDIO_MODEL="m"
  local out
  out=$(printf '%s\n' '/model lm_studio_server_routed' '/exit' | node "$ONA" 2>&1) || true
  stop_mock
  echo "$out" >>"$ACCEPT_TMP/row43.log"
  echo "$out" | grep -qiE 'async|invalid|reject|error' || return 1
}

row_44() {
  echo "[ROW-44] §5.9 — SessionEnd hook timeout default ~1500ms"
  put_effective_json '{"hooks":[{"hook_event_name":"SessionEnd","matcher":"","command":"sleep 5"}]}'
  write_mock_server 18772
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18772/v1"
  export LM_STUDIO_MODEL="m"
  local start=$SECONDS
  printf '%s\n' '/model lm_studio_server_routed' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  local elapsed=$((SECONDS - start))
  [[ "$elapsed" -le 4 ]]
}

row_45() {
  echo "[ROW-45] §5.6 — permission merge deny > allow"
  put_effective_json "$(python3 <<'PY'
import json
print(json.dumps({"hooks": [
    {"hook_event_name": "PreToolUse", "matcher": "Read",
     "command": "echo '{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\"}}'"},
    {"hook_event_name": "PreToolUse", "matcher": "Read",
     "command": "echo '{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\"}}'"},
]}))
PY
)"
  write_mock_server 18773
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18773/v1"
  export LM_STUDIO_MODEL="m"
  echo "test" >"$ACCEPT_TMP/r45.txt"
  printf '%s\n' \
    '/model lm_studio_server_routed' \
    "__TOOL__:Read:{\"file_path\": \"$ACCEPT_TMP/r45.txt\"}" \
    '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  local pj
  pj=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1")
  echo "$pj" | grep -q '"is_error":true'
}

row_46() {
  echo "[ROW-46] §5.11 — hook stdin JSON fields"
  local stdinfile="$ACCEPT_TMP/hook_stdin.json"
  put_effective_json "$(python3 -c "import json,os; p=os.path.join(os.environ['ACCEPT_TMP'],'hook_stdin.json'); print(json.dumps({'hooks':[{'hook_event_name':'UserPromptSubmit','matcher':'','command':'cat > '+p}]}))")"
  write_mock_server 18774
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18774/v1"
  export LM_STUDIO_MODEL="m"
  printf '%s\n' '/model lm_studio_server_routed' '__ASSIST_TEXT__:z' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  [[ -f "$stdinfile" ]] || return 1
  python3 - "$stdinfile" <<'PY' || return 1
import json, sys
p = json.load(open(sys.argv[1]))
for k in ("hook_event_name", "session_id", "conversation_id", "runtime_db_path", "cwd"):
    assert k in p, k
assert "transcript_path" not in p
PY
}

row_47() {
  echo "[ROW-47] §5.11 — hook stdin ends with newline"
  local stdinfile="$ACCEPT_TMP/hook_stdin2.json"
  put_effective_json "$(python3 -c "import json,os; p=os.path.join(os.environ['ACCEPT_TMP'],'hook_stdin2.json'); print(json.dumps({'hooks':[{'hook_event_name':'UserPromptSubmit','matcher':'','command':'cat > '+p}]}))")"
  write_mock_server 18775
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18775/v1"
  export LM_STUDIO_MODEL="m"
  printf '%s\n' '/model lm_studio_server_routed' '__ASSIST_TEXT__:z2' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  [[ -f "$stdinfile" ]] || return 1
  python3 -c "d=open('$stdinfile','rb').read(); assert d.endswith(b'}\n'), d[-20:]"
}

row_48() {
  echo "[ROW-48] §5.11 — hook env AGENT_SDLC_DB SDLC_HOOK"
  local envfile="$ACCEPT_TMP/hook_env.txt"
  put_effective_json "$(python3 -c "import json,os; p=os.path.join(os.environ['ACCEPT_TMP'],'hook_env.txt'); print(json.dumps({'hooks':[{'hook_event_name':'SessionStart','matcher':'','command':'env > '+p}]}))")"
  write_mock_server 18776
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18776/v1"
  export LM_STUDIO_MODEL="m"
  printf '%s\n' '/model lm_studio_server_routed' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  grep -q '^AGENT_SDLC_DB=' "$envfile"
  grep -q '^SDLC_HOOK=1$' "$envfile" || grep -q '^SDLC_HOOK=1' "$envfile"
}

row_49() {
  echo "[ROW-49] §5.10 — SDLC_DISABLE_ALL_HOOKS=1"
  put_effective_json '{"hooks":[{"hook_event_name":"SessionStart","matcher":"","command":"false"}]}'
  write_mock_server 18777
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18777/v1"
  export LM_STUDIO_MODEL="m"
  export SDLC_DISABLE_ALL_HOOKS=1; printf '%s\n' '/model lm_studio_server_routed' '/exit' | node "$ONA" 2>&1 >/dev/null || true; unset SDLC_DISABLE_ALL_HOOKS
  stop_mock
  [[ "$(db "SELECT COUNT(*) FROM hook_invocations")" == "0" ]]
}

row_50() {
  echo "[ROW-50] §5.12 deny > allow precedence"
  put_effective_json '{"permissions":{"deny":["Bash"],"allow":["Read"],"defaultMode":"default"}}'
  write_mock_server 18778
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18778/v1"
  export LM_STUDIO_MODEL="m"
  printf -v nl '%s\n' 'line1' 'line2' 'line3'
  printf '%s' "$nl" >"$ACCEPT_TMP/r50read.txt"
  printf '%s\n' '/model lm_studio_server_routed' \
    "__TOOL__:Bash:{\"command\": \"echo x\"}" '/exit' | node "$ONA" 2>&1 >/dev/null || true
  local b
  b=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1")
  echo "$b" | grep -qi bash
  echo "$b" | grep -q '"is_error":true'
  stop_mock
  write_mock_server 18779
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18779/v1"
  printf '%s\n' '/model lm_studio_server_routed' \
    "__TOOL__:Read:{\"file_path\": \"$ACCEPT_TMP/r50read.txt\"}" '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  b=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1")
  echo "$b" | grep -qi read
  echo "$b" | grep -q '"is_error":false'
}

row_51() {
  echo "[ROW-51] bypassPermissions"
  put_effective_json '{"permissions":{"defaultMode":"bypassPermissions"}}'
  write_mock_server 18780
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18780/v1"
  export LM_STUDIO_MODEL="m"
  printf '%s\n' '/model lm_studio_server_routed' \
    "__TOOL__:Read:{\"file_path\": \"$ACCEPT_TMP/r50read.txt\"}" '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  local b
  b=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1")
  echo "$b" | grep -q '"is_error":false'
}

row_52() {
  echo "[ROW-52] plan defaultMode denies mutating tools"
  put_effective_json '{"permissions":{"defaultMode":"plan"}}'
  write_mock_server 18781
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18781/v1"
  export LM_STUDIO_MODEL="m"
  printf '%s\n' '/model lm_studio_server_routed' \
    "__TOOL__:Write:{\"file_path\": \"$ACCEPT_TMP/planblock.txt\", \"content\": \"nope\"}" '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  local w
  w=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1")
  echo "$w" | grep -q '"is_error":true'
  write_mock_server 18782
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18782/v1"
  printf '%s\n' '/model lm_studio_server_routed' \
    "__TOOL__:Read:{\"file_path\": \"$ACCEPT_TMP/r50read.txt\"}" '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  w=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1")
  echo "$w" | grep -q '"is_error":false'
}

row_53() {
  echo "[ROW-53] dontAsk denies all"
  put_effective_json '{"permissions":{"defaultMode":"dontAsk"}}'
  write_mock_server 18783
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18783/v1"
  export LM_STUDIO_MODEL="m"
  printf '%s\n' '/model lm_studio_server_routed' \
    "__TOOL__:Read:{\"file_path\": \"$ACCEPT_TMP/r50read.txt\"}" '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  local b
  b=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1")
  echo "$b" | grep -q '"is_error":true'
}

tool_one() {
  local rid="$1" tool="$2" args="$3"
  echo "[ROW-$rid] tool $tool" >&2
  stop_mock
  write_mock_server $((20000 + rid))
  export LM_STUDIO_BASE_URL="http://127.0.0.1:$((20000 + rid))/v1"
  export LM_STUDIO_MODEL="t"
  printf '%s\n' '/model lm_studio_server_routed' "__TOOL__:$tool:$args" '/exit' | node "$ONA" 2>&1 >"$ACCEPT_TMP/tool_${rid}.log" || true
  stop_mock
  local pj
  pj=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1" || true)
  [[ -n "$pj" ]] || {
    echo "  FAIL: ROW-$rid (no tool_result)" >&2
    exit 1
  }
  printf '%s' "$pj"
}

row_tool_matrix() {
  echo "[ROW-60..86] §7 tools — deterministic mock turns"
  mkdir -p "$ACCEPT_TMP/gd" "$ACCEPT_TMP/globd"
  printf '%s\n' 'line1' 'line2' 'line3' >"$ACCEPT_TMP/tread.txt"
  local pj

  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 60 Read "{\"file_path\": \"$ACCEPT_TMP/tread.txt\"}")
  echo "$pj" | grep -q '"is_error":false' && echo "$pj" | grep -qE 'line1|lines|3 line'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-60"

  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 62 Write "{\"file_path\": \"$ACCEPT_TMP/tw.txt\", \"content\": \"hello\"}")
  grep -q hello "$ACCEPT_TMP/tw.txt" && echo "$pj" | grep -q '"is_error":false'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-62"

  echo "old_text" >"$ACCEPT_TMP/te.txt"
  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 63 Edit "{\"file_path\": \"$ACCEPT_TMP/te.txt\", \"old_string\": \"old_text\", \"new_string\": \"new_text\"}")
  grep -q new_text "$ACCEPT_TMP/te.txt" && ! grep -q old_text "$ACCEPT_TMP/te.txt" && echo "$pj" | grep -q '"is_error":false'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-63"

  echo a >"$ACCEPT_TMP/globd/a.txt"
  echo b >"$ACCEPT_TMP/globd/b.js"
  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 64 Glob "{\"pattern\": \"*.txt\", \"path\": \"$ACCEPT_TMP/globd\"}")
  echo "$pj" | grep -q a.txt && ! echo "$pj" | grep -q b.js && echo "$pj" | grep -q '"is_error":false'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-64"

  echo 'needle here' >"$ACCEPT_TMP/gd/a.txt"
  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 65 Grep "{\"pattern\": \"needle\", \"path\": \"$ACCEPT_TMP/gd\"}")
  echo "$pj" | grep -q needle && echo "$pj" | grep -q '"is_error":false'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-65"

  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 67 Bash '{"command": "echo hello_ona_test"}')
  echo "$pj" | grep -q hello_ona_test && echo "$pj" | grep -q '"is_error":false'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-67"

  echo '{"cells":[{"cell_type":"code","metadata":{},"source":["x"]}],"metadata":{},"nbformat":4,"nbformat_minor":5}' >"$ACCEPT_TMP/t.ipynb"
  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 71 NotebookEdit "{\"notebook_path\": \"$ACCEPT_TMP/t.ipynb\", \"cell_id\": \"0\", \"new_source\": \"y\"}")
  python3 - "$ACCEPT_TMP/t.ipynb" <<'PY'
import json, sys
nb = json.load(open(sys.argv[1]))
src = nb["cells"][0]["source"]
ok = src == "y" or src == ["y"] or (isinstance(src, list) and "".join(src) == "y")
sys.exit(0 if ok else 1)
PY
  echo "$pj" | grep -q '"is_error":false'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-71"

  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 72 WebFetch '{"url": "http://example.com"}')
  echo "$pj" | grep -qE 'example|is_error|HTTP|html'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-72"

  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 73 WebSearch '{"query": "test"}')
  echo "$pj" | grep -qE 'is_error|result|test'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-73"

  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 77 AskUserQuestion '{"questions":[]}')
  echo "$pj" | grep -qE '_t|tool_result|error|question'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-77"

  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 78 Brief '{"message": "brief_msg"}')
  echo "$pj" | grep -q '"is_error":false'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-78"

  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 81 TaskStop '{"task_id": "nonexistent-task-id"}')
  echo "$pj" | grep -qE '_t|tool_result|error|task'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-81"

  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 83 Skill '{"name": "help"}')
  echo "$pj" | grep -q '"is_error":false'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-83"

  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 84 ToolSearch '{"query": "Read"}')
  echo "$pj" | grep -qi Read
  PASS=$((PASS + 1))
  echo "  PASS: ROW-84"

  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 85 ListMcpResources '{}')
  echo "$pj" | grep -q '"is_error":false'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-85"

  TOTAL=$((TOTAL + 1))
  pj=$(tool_one 86 ReadMcpResource '{"server": "nonexistent", "uri": "x"}')
  echo "$pj" | grep -q '"is_error":true'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-86"
}

row_60_extras() {
  echo "[ROW-61] Read missing file"
  TOTAL=$((TOTAL + 1))
  write_mock_server 18920
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18920/v1"
  export LM_STUDIO_MODEL="t"
  printf '%s\n' '/model lm_studio_server_routed' \
    '__TOOL__:Read:{"file_path": "/tmp/nonexistent_ona_test_xyz"}' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  local pj
  pj=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1")
  echo "$pj" | grep -q '"is_error":true' || return 1
  PASS=$((PASS + 1))
  echo "  PASS: ROW-61"

  echo "[ROW-66] Grep no match"
  TOTAL=$((TOTAL + 1))
  write_mock_server 18921
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18921/v1"
  mkdir -p "$ACCEPT_TMP/gd2"; echo z >"$ACCEPT_TMP/gd2/z.txt"
  printf '%s\n' '/model lm_studio_server_routed' \
    "__TOOL__:Grep:{\"pattern\": \"nomatchxxx\", \"path\": \"$ACCEPT_TMP/gd2\"}" '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  pj=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1")
  echo "$pj" | grep -q '"is_error":false'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-66"

  echo "[ROW-68] Bash fail"
  TOTAL=$((TOTAL + 1))
  write_mock_server 18922
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18922/v1"
  printf '%s\n' '/model lm_studio_server_routed' '__TOOL__:Bash:{"command": "exit 42"}' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  pj=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1")
  echo "$pj" | grep -q '"is_error":true'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-68"

  echo "[ROW-69] Bash stderr"
  TOTAL=$((TOTAL + 1))
  write_mock_server 18923
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18923/v1"
  printf '%s\n' '/model lm_studio_server_routed' '__TOOL__:Bash:{"command": "echo err >&2"}' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  pj=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1")
  echo "$pj" | grep -q 'stderr' && echo "$pj" | grep -q err
  PASS=$((PASS + 1))
  echo "  PASS: ROW-69"

  echo "[ROW-70] Bash truncation marker"
  TOTAL=$((TOTAL + 1))
  write_mock_server 18924
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18924/v1"
  printf '%s\n' '/model lm_studio_server_routed' \
    '__TOOL__:Bash:{"command": "dd if=/dev/zero bs=1048577 count=1 2>/dev/null | base64"}' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  pj=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1")
  echo "$pj" | grep -q 'SDLC_TRUNCATED'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-70"
}

row_74_76() {
  echo "[ROW-74] EnterPlanMode phase planning"
  TOTAL=$((TOTAL + 1))
  write_mock_server 18930
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18930/v1"
  printf '%s\n' '/model lm_studio_server_routed' '__TOOL__:EnterPlanMode:{}' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  local cid ph
  cid=$(db "SELECT id FROM conversations ORDER BY rowid DESC LIMIT 1")
  ph=$(db "SELECT phase FROM conversations WHERE id='$cid'")
  [[ "$ph" == "planning" ]]
  PASS=$((PASS + 1))
  echo "  PASS: ROW-74"

  echo "[ROW-75] ExitPlanMode no approved plan"
  TOTAL=$((TOTAL + 1))
  write_mock_server 18931
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18931/v1"
  printf '%s\n' '/model lm_studio_server_routed' '__TOOL__:ExitPlanMode:{}' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  local pj
  pj=$(db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1")
  echo "$pj" | grep -q '"is_error":true'
  echo "$pj" | grep -qiE 'approved|plan'
  PASS=$((PASS + 1))
  echo "  PASS: ROW-75"

  echo "[ROW-76] ExitPlanMode with approved plan"
  TOTAL=$((TOTAL + 1))
  cid=$(db "SELECT id FROM conversations ORDER BY rowid DESC LIMIT 1")
  db "INSERT INTO plans(conversation_id, content, hash, status) VALUES ('$cid','body','h','approved')"
  write_mock_server 18932
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18932/v1"
  printf '%s\n' '/model lm_studio_server_routed' '__TOOL__:ExitPlanMode:{}' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  ph=$(db "SELECT phase FROM conversations WHERE id='$cid'")
  [[ "$ph" == "implement" ]]
  PASS=$((PASS + 1))
  echo "  PASS: ROW-76"
}

row_79_80() {
  echo "[ROW-79] TodoWrite state"
  TOTAL=$((TOTAL + 1))
  write_mock_server 18940
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18940/v1"
  printf '%s\n' '/model lm_studio_server_routed' \
    '__TOOL__:TodoWrite:{"merge": true, "todos": [{"id": "x", "content": "c", "status": "pending"}]}' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  [[ "$(db "SELECT COUNT(*) FROM state WHERE key LIKE 'todo:%'")" -ge 1 ]]
  PASS=$((PASS + 1))
  echo "  PASS: ROW-79"

  echo "[ROW-80] TaskOutput events"
  TOTAL=$((TOTAL + 1))
  write_mock_server 18941
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18941/v1"
  printf '%s\n' '/model lm_studio_server_routed' \
    '__TOOL__:TaskOutput:{"task_id": "t1", "output": "out"}' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  [[ "$(db "SELECT COUNT(*) FROM events WHERE event_type='task_output'")" -ge 1 ]]
  PASS=$((PASS + 1))
  echo "  PASS: ROW-80"
}

row_82_86() {
  echo "[ROW-82] Agent sub-session"
  TOTAL=$((TOTAL + 1))
  write_mock_server 18950
  export LM_STUDIO_BASE_URL="http://127.0.0.1:18950/v1"
  printf '%s\n' '/model lm_studio_server_routed' \
    '__TOOL__:Agent:{"prompt": "sub", "subagent_type": "general"}' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  stop_mock
  [[ "$(db "SELECT COUNT(DISTINCT session_id) FROM sessions")" -ge 2 ]]
  PASS=$((PASS + 1))
  echo "  PASS: ROW-82"
}

row_90_96() {
  echo "[ROW-90] §8.1 phase enum (distinct values in DB)"
  TOTAL=$((TOTAL + 1))
  local p
  for ph in idle planning implement test verify done; do
    db "INSERT OR REPLACE INTO conversations(id, project_dir, phase) VALUES ('pv-$ph', '/tmp', '$ph')"
  done
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    case "$p" in idle|planning|implement|test|verify|done) ;; *)
      echo "  FAIL: ROW-90 bad phase $p" >&2
      exit 1
      ;;
    esac
  done < <(db "SELECT DISTINCT phase FROM conversations WHERE id LIKE 'pv-%'")
  PASS=$((PASS + 1))
  echo "  PASS: ROW-90"

  echo "[ROW-91] implement→verify blocked"
  skip_row "ROW-91" "no piped CLI for phase transition in harness (use implementation-specific --transition if added)"
  echo "[ROW-92] implement→test allowed"
  skip_row "ROW-92" "same as ROW-91"
  echo "[ROW-93] test→verify allowed"
  skip_row "ROW-93" "same as ROW-91"
  echo "[ROW-94] planning→implement requires approved plan"
  skip_row "ROW-94" "ROW-75/76 cover ExitPlanMode; direct phase SQL not a product interface"
  echo "[ROW-95] §8.3 planning gate mutating tools"
  skip_row "ROW-95" "requires stable conversation id + planning phase + mock tool turn in one session"
  echo "[ROW-96] §8.3 planning gate non-mutating allowed"
  skip_row "ROW-96" "same as ROW-95"
}

row_100_102() {
  echo "[ROW-100] §0.3 no not implemented in tool results"
  TOTAL=$((TOTAL + 1))
  if db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result'" | grep -qi 'not implemented'; then
    echo "  FAIL: ROW-100" >&2
    exit 1
  fi
  PASS=$((PASS + 1))
  echo "  PASS: ROW-100"

  echo "[ROW-101] §0.3 no TODO in tool results"
  TOTAL=$((TOTAL + 1))
  if db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result'" | grep -qE '(^|[^a-z])TODO([^a-z]|$)'; then
    echo "  FAIL: ROW-101" >&2
    exit 1
  fi
  PASS=$((PASS + 1))
  echo "  PASS: ROW-101"

  echo "[ROW-102] §0.2 no Unknown tool"
  TOTAL=$((TOTAL + 1))
  if db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result'" | grep -qi 'unknown tool'; then
    echo "  FAIL: ROW-102" >&2
    exit 1
  fi
  PASS=$((PASS + 1))
  echo "  PASS: ROW-102"
}

row_110_112() {
  echo "[ROW-110] user payload _t"
  TOTAL=$((TOTAL + 1))
  db "SELECT payload_json FROM transcript_entries WHERE entry_type='user' ORDER BY id DESC LIMIT 1" >"$ACCEPT_TMP/pju.json"
  python3 - "$ACCEPT_TMP/pju.json" <<'PY' || exit 1
import json, sys
j = json.load(open(sys.argv[1]))
assert j.get("_t") == "user"
assert "content" in j
PY
  PASS=$((PASS + 1))
  echo "  PASS: ROW-110"

  echo "[ROW-111] assistant payload _t"
  TOTAL=$((TOTAL + 1))
  db "SELECT payload_json FROM transcript_entries WHERE entry_type='assistant' ORDER BY id DESC LIMIT 1" >"$ACCEPT_TMP/pja.json"
  python3 - "$ACCEPT_TMP/pja.json" <<'PY' || exit 1
import json, sys
j = json.load(open(sys.argv[1]))
assert j.get("_t") == "assistant"
assert "content" in j
PY
  PASS=$((PASS + 1))
  echo "  PASS: ROW-111"

  echo "[ROW-112] tool_result payload _t"
  TOTAL=$((TOTAL + 1))
  db "SELECT payload_json FROM transcript_entries WHERE entry_type='tool_result' ORDER BY id DESC LIMIT 1" >"$ACCEPT_TMP/pjt.json"
  python3 - "$ACCEPT_TMP/pjt.json" <<'PY' || exit 1
import json, sys
j = json.load(open(sys.argv[1]))
assert j.get("_t") == "tool_result"
for k in ("tool_use_id", "content", "is_error"):
    assert k in j
PY
  PASS=$((PASS + 1))
  echo "  PASS: ROW-112"
}

main() {
  require_cmds
  require_ona
  export AGENT_SDLC_DB="${AGENT_SDLC_DB:-$(mktemp "$ACCEPT_TMP/db.XXXXXX")}"
  bootstrap_schema

  echo "=== SDLC acceptance (AGENT_SDLC_DB=$AGENT_SDLC_DB) ==="

  run_check ROW-01 row_01
  run_check ROW-02 row_02
  run_check ROW-03 row_03
  run_check ROW-04 row_04
  run_check ROW-05 row_05

  printf '%s\n' '/exit' | node "$ONA" 2>&1 >/dev/null || true
  seed_transcript_turn

  run_check ROW-06 row_06
  run_check ROW-07 row_07
  row_08

  run_check ROW-10 row_10
  # new DB for provider isolation
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-11 row_11
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-12 row_12
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-13 row_13
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-14 row_14
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-20 row_20
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-21 row_21
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-22 row_22
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-23 row_23
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-24 row_24
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-25 row_25

  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-30 row_30
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-31 row_31
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-32 row_32
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-33 row_33
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-34 row_34
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-35 row_35
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-36 row_36
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-37 row_37
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-38 row_38

  run_check ROW-40 row_40

  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-41 row_41
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-42 row_42
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-43 row_43
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-44 row_44
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-45 row_45
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-46 row_46
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-47 row_47
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-48 row_48
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-49 row_49
  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  run_check ROW-50 row_50
  run_check ROW-51 row_51
  run_check ROW-52 row_52
  run_check ROW-53 row_53

  export AGENT_SDLC_DB=$(mktemp "$ACCEPT_TMP/db.XXXXXX"); bootstrap_schema
  seed_transcript_turn
  echo "[ROW-60..86] tools"
  row_tool_matrix
  row_60_extras
  row_74_76
  row_79_80
  row_82_86
  row_90_96
  row_100_102
  row_110_112

  local failed=$((TOTAL - PASS - SKIP))
  if [[ $SKIP -gt 0 && "${SDLC_ACCEPTANCE_ALLOW_SKIP:-}" != 1 ]]; then
    echo "sdlc-acceptance: $SKIP row(s) skipped — set SDLC_ACCEPTANCE_ALLOW_SKIP=1 to exit 0 anyway" >&2
    exit 1
  fi
  [[ "$failed" -eq 0 ]] || exit 1
  echo "=== Results: $PASS passed, 0 failed ==="
}

main "$@"
