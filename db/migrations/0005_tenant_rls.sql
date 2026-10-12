-- Forward migration 0005: tenant gets FORCE ROW LEVEL SECURITY. app_rw sees only the row of ctx_tenant(),
-- and no row without a request context. Statements are copied from db/schema.sql
-- (the schema-drift job compares the two).
ALTER TABLE tenant ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_read ON tenant FOR SELECT USING (id = app_sec.ctx_tenant());
