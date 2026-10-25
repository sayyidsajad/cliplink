-- Idempotent migration for EXISTING D1 databases (run via wrangler d1 execute).
-- Supabase shares keep provider='supabase' so the legacy path keeps working
-- until every legacy share has expired, after which the Supabase project is retired.

CREATE TABLE IF NOT EXISTS connections (
  id TEXT PRIMARY KEY, provider TEXT NOT NULL,
  refresh_token TEXT NOT NULL, account_label TEXT,
  owner_install_id TEXT, created_at INTEGER NOT NULL,
  access_token TEXT, access_expires_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_connections_install ON connections(owner_install_id, created_at);

CREATE TABLE IF NOT EXISTS oauth_sessions (
  state TEXT PRIMARY KEY, code_verifier TEXT NOT NULL,
  owner_install_id TEXT, created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_oauth_created ON oauth_sessions(created_at);

CREATE TABLE IF NOT EXISTS mock_blobs (token TEXT PRIMARY KEY, data TEXT NOT NULL);

-- Add BYO columns to the legacy shares table. SQLite ALTER TABLE has no
-- IF NOT EXISTS: if these already exist (previous run), skip & ignore errors.
ALTER TABLE shares ADD COLUMN provider TEXT NOT NULL DEFAULT 'supabase';
ALTER TABLE shares ADD COLUMN connection_id TEXT;
