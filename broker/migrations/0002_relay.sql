-- M2 step 7c: audit columns for POST /relay. Run once on a database created
-- before 7c:
--   npx -y wrangler@4.163.0 d1 execute agent-bot-audit --remote --file migrations/0002_relay.sql
-- A fresh install gets these columns from schema.sql instead.
ALTER TABLE audit ADD COLUMN branch TEXT;
ALTER TABLE audit ADD COLUMN files INTEGER;
ALTER TABLE audit ADD COLUMN paths TEXT;
