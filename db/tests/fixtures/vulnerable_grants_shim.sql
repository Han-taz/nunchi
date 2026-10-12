-- Grants the v1.0 smoke test used to create before the X3 fix (broad
-- table privileges, no least privilege). The vulnerable schema fixture has
-- no app_rw role of its own, so the mutation gate applies this shim after it.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') THEN CREATE ROLE app_rw NOLOGIN; END IF;
END $$;
GRANT USAGE ON SCHEMA public TO app_rw;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO app_rw;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_rw;
