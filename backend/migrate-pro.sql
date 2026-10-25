-- ClipLink Pro (v0.5) — idempotent for existing prod D1.
CREATE TABLE IF NOT EXISTS licenses (
  key_id TEXT PRIMARY KEY, installs TEXT, first_seen_at INTEGER NOT NULL, last_check_at INTEGER
);
ALTER TABLE shares ADD COLUMN password_salt TEXT;
ALTER TABLE shares ADD COLUMN password_hash TEXT;
