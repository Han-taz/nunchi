-- Forward migration 0008: bind each review to the memory version it judged (found by the PR #29 verifier, note 1).
-- Statements are copied from db/schema.sql (the schema-drift job compares the two).
-- Existing reviews are stamped with their memory's current version, so no earlier approval changes meaning.
ALTER TABLE review ADD COLUMN version integer;
UPDATE review SET version = m.version FROM memory AS m
WHERE m.id = review.memory_id;
ALTER TABLE review ALTER COLUMN version SET NOT NULL;

CREATE FUNCTION app_sec.review_before_insert() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  SELECT m.version INTO NEW.version FROM memory AS m WHERE m.id = NEW.memory_id;
  RETURN NEW;
END $$;
CREATE TRIGGER review_bi BEFORE INSERT ON review FOR EACH ROW EXECUTE FUNCTION app_sec.review_before_insert();

CREATE OR REPLACE FUNCTION app_sec.quorum(p_mem memory, p_to memory_status) RETURNS TABLE (have integer, needed integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT
    (
      SELECT count(DISTINCT v.reviewer_id)::integer FROM review AS v, memory AS m
      WHERE
        m.id = p_mem.id
        AND m.store_id IN (SELECT app_sec.my_stores('curator'))
        AND v.memory_id = m.id
        AND v.version = m.version
        AND v.verdict = (SELECT t.op::text FROM memory_transition AS t WHERE t.from_status = m.status AND t.to_status = p_to)
        AND v.reviewer_id NOT IN (m.created_by, coalesce(m.on_behalf_of, m.created_by))
        AND EXISTS (
          SELECT 1 FROM store_grant AS g
          WHERE g.store_id = m.store_id AND g.tenant_id = m.tenant_id AND g.role = 'curator' AND g.principal_id IN (SELECT app_sec.closure(v.reviewer_id))
        )
        AND (
          v.via_agent_id IS NULL OR EXISTS (
            SELECT 1 FROM store_grant AS g
            WHERE g.store_id = m.store_id AND g.tenant_id = m.tenant_id AND g.role = 'curator' AND g.principal_id IN (SELECT app_sec.closure(v.via_agent_id))
          )
        )
    ),
    CASE WHEN p_to = 'active' THEN (SELECT r.approvals_needed FROM approval_tier_rule AS r WHERE r.tier = p_mem.tier)::integer ELSE 1 END
$$;
