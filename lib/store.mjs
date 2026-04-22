// §4 Storage: single SQLite database
// §4.8 Concurrency and transaction boundaries
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

let _db = null;

export function openDB(dbPath) {
  if (_db) return _db;
  _db = new DatabaseSync(dbPath);
  // §4.8 pragmas — every connection
  _db.exec('PRAGMA foreign_keys = ON');
  _db.exec('PRAGMA journal_mode = WAL');
  _db.exec('PRAGMA busy_timeout = 30000');
  return _db;
}

export function getDB() {
  if (!_db) throw new Error('DB not opened — call openDB first');
  return _db;
}

export function bootstrapSchema() {
  const db = getDB();
  const ddl = readFileSync(join(__dirname, 'schema.sql'), 'utf8');
  // Split on statements (node:sqlite exec handles multi-statement)
  db.exec(ddl);
  // §4.2 schema version
  db.prepare("INSERT OR IGNORE INTO schema_meta(key, value) VALUES ('schema_version', '1')").run();
}

export function closeDB() {
  if (_db) {
    _db.close();
    _db = null;
  }
}

// §4.4 Bootstrap import — read settings_snapshot effective scope
export function getEffectiveSettings() {
  const db = getDB();
  const row = db.prepare("SELECT json FROM settings_snapshot WHERE scope = 'effective'").get();
  if (!row) return {};
  try { return JSON.parse(row.json); } catch { return {}; }
}

export function putEffectiveSettings(obj) {
  const db = getDB();
  const json = JSON.stringify(obj);
  db.prepare("INSERT OR REPLACE INTO settings_snapshot(scope, json, updated_at) VALUES ('effective', ?, datetime('now'))").run(json);
}
