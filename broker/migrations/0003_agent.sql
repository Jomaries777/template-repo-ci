-- Spec 0003 (NFR-5): record which agent's token or which key each audited
-- request used. Apply before deploying the 0003 broker:
--   npx -y wrangler@4.163.0 d1 migrations apply agent-bot-audit --remote
-- A fresh install gets this column from schema.sql instead.
ALTER TABLE audit ADD COLUMN agent TEXT;
