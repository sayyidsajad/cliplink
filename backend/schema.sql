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
