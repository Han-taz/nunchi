-- Setup the v1.0 smoke test used before the X3 fix. The vulnerable schema fixture
-- has no app_rw role of its own, so the mutation gate applies this shim after it:
--   * app_rw as v1.0 had it: NOLOGIN, broad table privileges including DELETE
--     (the X3c/X3f tests must fail on their own merit, not because DELETE is missing).
--   * store_grant.tenant_id, so the shared seed data loads. The column carries no
--     constraint here, which is the v1.0 behaviour the N8 tests must detect.
-- app_rw is a cluster-wide role: ALTER ROLE resets it when a current-schema run came first.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') THEN CREATE ROLE app_rw NOLOGIN; END IF;
END $$;
ALTER ROLE app_rw NOLOGIN INHERIT;
ALTER TABLE store_grant ADD COLUMN tenant_id uuid;
GRANT USAGE ON SCHEMA public TO app_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_rw;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_rw;
