-- ClipLink metadata schema (Cloudflare D1 / SQLite).

CREATE TABLE IF NOT EXISTS shares (
  token            TEXT    PRIMARY KEY,        -- public, unguessable share token
  revoke_token     TEXT    NOT NULL,           -- secret; only the uploader (or admin) may revoke
  object_key       TEXT    NOT NULL,           -- R2 object key (never exposed via public URLs)
  filename         TEXT    NOT NULL,           -- sanitized original filename
  size             INTEGER NOT NULL,           -- bytes
  created_at       INTEGER NOT NULL,           -- epoch milliseconds
  expires_at       INTEGER NOT NULL,           -- epoch milliseconds; enforced on every request
  revoked          INTEGER NOT NULL DEFAULT 0, -- 1 => permanently refused
  object_deleted   INTEGER NOT NULL DEFAULT 0, -- 1 => blob removed from storage by cleanup/revoke
  deleted_at       INTEGER,                    -- when the object was deleted
  owner_install_id TEXT,                       -- client-generated install id (rate limiting only, NOT auth)
  source_ip        TEXT,                       -- best-effort IP for rate limiting when no install id
  downloads        INTEGER NOT NULL DEFAULT 0  -- rough download counter
);

CREATE INDEX IF NOT EXISTS idx_shares_expires       ON shares(expires_at);
CREATE INDEX IF NOT EXISTS idx_shares_owner_created  ON shares(owner_install_id, created_at);
CREATE INDEX IF NOT EXISTS idx_shares_ip_created     ON shares(source_ip, created_at);

-- ---------------------------------------------------------------- BYO storage (v0.4+)
-- Shares are stored in THE USER'S OWN cloud (v1: Google Drive) via their
-- OAuth consent. The Worker holds metadata + sealed OAuth tokens only.

CREATE TABLE IF NOT EXISTS connections (
  id                 TEXT    PRIMARY KEY,      -- random connection id (given to the app)
  provider           TEXT    NOT NULL,         -- 'drive' (v1)
  refresh_token      TEXT    NOT NULL,         -- AES-GCM sealed (crypto.js "enc1:…")
  account_label      TEXT,                     -- sealed account e-mail; decrypted for the owner app only
  owner_install_id   TEXT,                     -- install id that created it (rate limiting only)
  created_at         INTEGER NOT NULL,
  access_token       TEXT,                     -- sealed; short-lived cache
  access_expires_at  INTEGER                   -- epoch ms
);
CREATE INDEX IF NOT EXISTS idx_connections_install ON connections(owner_install_id, created_at);

CREATE TABLE IF NOT EXISTS oauth_sessions (
  state           TEXT    PRIMARY KEY,        -- random, doubles as the poll secret
  code_verifier   TEXT    NOT NULL,           -- PKCE verifier (never leaves the server)
  owner_install_id TEXT,
  created_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_oauth_created ON oauth_sessions(created_at);

-- Dev/CI only: tiny blobs for the mock provider. Never touched in production.
CREATE TABLE IF NOT EXISTS mock_blobs (
  token TEXT PRIMARY KEY,
  data  TEXT NOT NULL                        -- base64
);

-- ---------------------------------------------------------------- ClipLink Pro (v0.5+, one-time license)
CREATE TABLE IF NOT EXISTS licenses (
  key_id  TEXT PRIMARY KEY,        -- non-reversible id of the presented key (never the raw key)
  installs  TEXT                   -- JSON array of install ids bound to this key (≤ 5)
, first_seen_at INTEGER NOT NULL
, last_check_at INTEGER
);
