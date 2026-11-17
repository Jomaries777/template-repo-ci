-- Audit log of the bot token broker (spec 0002, FR-7). No tokens are stored.
CREATE TABLE IF NOT EXISTS audit (
  ts INTEGER NOT NULL,        -- milliseconds since the epoch
  caller_id TEXT,             -- GitHub user ID, once known
  endpoint TEXT NOT NULL,     -- token | relay (secrets follows in 7d)
  repo TEXT,
  outcome TEXT NOT NULL,      -- issued | refused
  reason TEXT,                -- error code when refused
  expires_at TEXT,            -- of the issued bot token
  ip TEXT,                    -- CF-Connecting-IP
  branch TEXT,                -- relay: the branch written
  files INTEGER,              -- relay: number of files
  paths TEXT                  -- relay: comma-joined paths (never contents), cut to 2000 chars
);
CREATE INDEX IF NOT EXISTS audit_caller ON audit (caller_id, endpoint, ts);
CREATE INDEX IF NOT EXISTS audit_ts ON audit (ts);
