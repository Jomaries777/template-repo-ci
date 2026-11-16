-- Audit log of the bot token broker (spec 0002, FR-7). No tokens are stored.
CREATE TABLE IF NOT EXISTS audit (
  ts INTEGER NOT NULL,        -- milliseconds since the epoch
  caller_id TEXT,             -- GitHub user ID, once known
  endpoint TEXT NOT NULL,     -- token (relay and secrets follow in 7c/7d)
  repo TEXT,
  outcome TEXT NOT NULL,      -- issued | refused
  reason TEXT,                -- error code when refused
  expires_at TEXT,            -- of the issued bot token
  ip TEXT                     -- CF-Connecting-IP
);
CREATE INDEX IF NOT EXISTS audit_caller ON audit (caller_id, endpoint, ts);
CREATE INDEX IF NOT EXISTS audit_ts ON audit (ts);
