-- Forward migration 0006: approval model B (risk tier, provisional status, transition table).
-- Statements are copied from db/schema.sql (the schema-drift job compares the two).
-- ALTER TYPE ... ADD VALUE cannot be used again inside the transaction that adds it, and the migration runner
-- applies every pending migration in one transaction. So memory_status and memory_op are replaced by new types
-- (a type created in the transaction is usable at once) and everything that holds the old types is dropped first
-- and recreated below in its final form.
ALTER TYPE memory_status RENAME TO memory_status_old;
ALTER TYPE memory_op RENAME TO memory_op_old;
-- provisional = 검토 전에 이미 노출된 상태. 불리언이 아니라 상태다 (전이 표가 허용하는 길만 있다)
CREATE TYPE memory_status AS ENUM ('proposed', 'provisional', 'active', 'superseded', 'rejected', 'expired', 'deleted');
-- 위험 등급: risk_tier() 가 정하고 approval_tier_rule 이 등급마다 최초 상태와 승인 정족수를 정한다
CREATE TYPE approval_tier AS ENUM ('auto', 'auto_labeled', 'one_curator', 'two_curators');
CREATE TYPE memory_op AS ENUM (
  'propose', 'auto_activate', 'approve', 'confirm', 'reject', 'retract',
  'edit', 'supersede', 'expire', 'delete', 'redact'
);
CREATE TYPE transition_role AS ENUM ('curator', 'system');

DROP POLICY memory_read ON memory;
DROP POLICY memory_propose ON memory;
ALTER TABLE memory DROP CONSTRAINT memory_check;
DROP FUNCTION app_sec.search(text, uuid[], memory_status_old[]);
DROP FUNCTION app_sec.write_version(memory, memory_op_old, uuid, text);

DELETE FROM memory_transition;
ALTER TABLE memory_transition
ALTER COLUMN from_status TYPE memory_status USING from_status::text::memory_status,
ALTER COLUMN to_status TYPE memory_status USING to_status::text::memory_status,
ADD COLUMN op memory_op NOT NULL,
ADD COLUMN by_role transition_role NOT NULL;
INSERT INTO memory_transition (from_status, to_status, op, by_role) VALUES
('proposed', 'provisional', 'auto_activate', 'system'),
('proposed', 'active', 'approve', 'curator'),
('proposed', 'rejected', 'reject', 'curator'),
('provisional', 'active', 'confirm', 'curator'),
('provisional', 'rejected', 'retract', 'curator'),
('provisional', 'superseded', 'supersede', 'curator'),
('provisional', 'deleted', 'delete', 'curator'),
('active', 'superseded', 'supersede', 'curator'),
('active', 'expired', 'expire', 'system'),
('active', 'deleted', 'delete', 'curator'),
('superseded', 'deleted', 'delete', 'curator'),
('expired', 'deleted', 'delete', 'curator'),
('rejected', 'deleted', 'delete', 'curator');

ALTER TABLE memory ALTER COLUMN status DROP DEFAULT;
ALTER TABLE memory ALTER COLUMN status TYPE memory_status USING status::text::memory_status;
ALTER TABLE memory ALTER COLUMN status SET DEFAULT 'proposed';
ALTER TABLE memory_version ALTER COLUMN op TYPE memory_op USING op::text::memory_op;
DROP TYPE memory_status_old;
DROP TYPE memory_op_old;

ALTER TABLE store DROP COLUMN auto_approve;
-- 기존 행의 tier 는 기본값(one_curator)이다: 등급 도입 전에 승인된 행이라 소급해서 정하지 않는다.
ALTER TABLE memory
ADD COLUMN tier approval_tier NOT NULL DEFAULT 'one_curator',
ADD COLUMN conflict_with uuid REFERENCES memory (id),
ADD CONSTRAINT memory_check CHECK (status <> 'deleted' OR body IS null);

CREATE TABLE approval_tier_rule (
  tier approval_tier PRIMARY KEY,
  initial_status memory_status NOT NULL,
  approvals_needed integer NOT NULL
);
INSERT INTO approval_tier_rule (tier, initial_status, approvals_needed) VALUES
('auto', 'active', 0),
('auto_labeled', 'provisional', 1),
('one_curator', 'proposed', 1),
('two_curators', 'proposed', 2);

CREATE TABLE proposer_trust (
  principal_id uuid NOT NULL REFERENCES principal (id),
  store_id uuid NOT NULL REFERENCES store (id),
  points integer NOT NULL DEFAULT 0,
  approved integer NOT NULL DEFAULT 0,
  rejected integer NOT NULL DEFAULT 0,
  retracted integer NOT NULL DEFAULT 0,
  demoted_until timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (principal_id, store_id)
);

CREATE POLICY memory_read ON memory FOR SELECT USING (
  tenant_id = app_sec.ctx_tenant() AND (
    (
      status IN ('active', 'provisional', 'superseded', 'expired')
      AND store_id IN (SELECT app_sec.my_stores('reader'))
    )
    OR store_id IN (SELECT app_sec.my_stores('curator'))
    OR (
      status = 'proposed' AND coalesce(on_behalf_of, created_by) = app_sec.ctx_user()
      AND store_id IN (SELECT app_sec.my_stores('reader'))
    )
  )
);

CREATE POLICY memory_propose ON memory FOR INSERT WITH CHECK (
  status = (
    SELECT r.initial_status FROM approval_tier_rule AS r
    WHERE r.tier = memory.tier
  ) AND version = 1
  AND tenant_id = app_sec.ctx_tenant()
  AND store_id IN (SELECT app_sec.my_stores('contributor'))
  AND created_by = coalesce(app_sec.ctx_agent(), app_sec.ctx_user())
  AND on_behalf_of IS NOT DISTINCT FROM (CASE WHEN app_sec.ctx_agent() IS NOT null THEN app_sec.ctx_user() END)
);

CREATE FUNCTION app_sec.write_version(p_mem memory, p_op memory_op, p_actor uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  snap jsonb;
  prev text;
  shash text;
  ts timestamptz := clock_timestamp();
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_mem.id::text, 0));
  snap := CASE WHEN p_op IN ('delete', 'redact') THEN NULL
    ELSE jsonb_build_object(
      'title', p_mem.title, 'body', p_mem.body, 'status', p_mem.status,
      'source_refs', p_mem.source_refs, 'origin', p_mem.origin, 'store_id', p_mem.store_id
    ) END;
  shash := encode(sha256(convert_to(coalesce(snap::text, ''), 'UTF8')), 'hex');
  SELECT row_hash INTO prev FROM memory_version WHERE memory_id = p_mem.id ORDER BY id DESC LIMIT 1;
  INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot, reason, at, snapshot_hash, prev_hash, row_hash)
  VALUES (
    p_mem.id, p_mem.version, p_op, p_actor, snap, p_reason, ts, shash, prev,
    encode(
      sha256(
        convert_to(concat_ws('|', prev, p_mem.id, p_mem.version, p_op, p_actor, shash, extract(EPOCH FROM ts), coalesce(p_reason, '')), 'UTF8')
      ),
      'hex'
    )
  );
END $$;

CREATE FUNCTION app_sec.risk_tier(m memory) RETURNS approval_tier
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  WITH f AS (
    SELECT
      s.kind AS store_kind,
      m.supersedes_id IS NOT NULL AS supersedes,
      t.kind = 'decision' AS target_is_decision,
      EXISTS (
        SELECT 1 FROM store_grant AS g
        WHERE g.store_id = t.store_id AND g.role = 'curator'
          AND g.principal_id IN (SELECT app_sec.closure(coalesce(t.on_behalf_of, t.created_by)))
      ) AS target_by_curator,
      coalesce(substring(m.gate_result ->> 'authority' FROM '^[0-9]{1,4}$')::int, 1) AS authority,
      coalesce(substring(t.gate_result ->> 'authority' FROM '^[0-9]{1,4}$')::int, 1) AS target_authority,
      CASE
        WHEN NOT (m.gate_result ? 'flags') THEN false
        WHEN jsonb_typeof(m.gate_result -> 'flags') = 'array' THEN jsonb_array_length(m.gate_result -> 'flags') > 0
        ELSE true
      END AS flagged,
      m.gate_result ? 'containment' AND (m.gate_result ->> 'containment') IS DISTINCT FROM 'ok' AS containment_unverified,
      coalesce(pt.demoted_until > now(), false) AS demoted,
      au.kind AS author_kind,
      coalesce(pt.points, 0) AS trust_points,
      20 AS trust_threshold
    FROM store AS s
    LEFT JOIN memory AS t ON t.id = m.supersedes_id
    LEFT JOIN proposer_trust AS pt ON pt.principal_id = m.created_by AND pt.store_id = m.store_id
    LEFT JOIN principal AS au ON au.id = m.created_by
    WHERE s.id = m.store_id
  )

  SELECT (CASE
    WHEN f.store_kind = 'user' THEN 'auto'
    WHEN f.store_kind = 'org' OR m.kind = 'decision' THEN 'two_curators'
    WHEN f.supersedes AND (f.target_is_decision OR f.target_by_curator OR f.authority < f.target_authority) THEN 'two_curators'
    WHEN f.supersedes THEN 'one_curator'
    WHEN m.kind = 'procedure' THEN 'one_curator'
    WHEN m.origin = 'external' THEN 'one_curator'
    WHEN f.flagged THEN 'one_curator'
    WHEN m.conflict_with IS NOT NULL OR f.containment_unverified THEN 'one_curator'
    WHEN f.demoted THEN 'one_curator'
    WHEN f.author_kind = 'user' OR f.trust_points >= f.trust_threshold THEN 'auto_labeled'
    ELSE 'one_curator'
  END)::approval_tier FROM f
$$;

CREATE OR REPLACE FUNCTION app_sec.memory_before_insert() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  by_whom uuid := coalesce(app_sec.ctx_agent(), app_sec.ctx_user());
  on_behalf uuid := CASE WHEN app_sec.ctx_agent() IS NULL THEN NULL ELSE app_sec.ctx_user() END;
  ref text;
  src uuid;
BEGIN
  IF app_sec.ctx_user() IS NOT NULL THEN
    NEW.created_by := coalesce(NEW.created_by, by_whom);
    NEW.tenant_id := coalesce(NEW.tenant_id, app_sec.ctx_tenant());
    IF NEW.created_by <> by_whom OR NEW.tenant_id <> app_sec.ctx_tenant()
       OR NEW.on_behalf_of IS DISTINCT FROM on_behalf THEN
      RAISE EXCEPTION 'author, delegate and tenant are bound to the request' USING ERRCODE = '42501';
    END IF;
    NEW.version := 1;
  END IF;

  -- 존재하지 않음과 읽을 수 없음은 같은 오류다 (존재 오라클 차단). 호출자의 RLS 가 그대로 적용된다
  IF NEW.supersedes_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM memory AS m
    WHERE m.id = NEW.supersedes_id AND m.store_id = NEW.store_id AND m.status IN ('active', 'provisional')
  ) THEN
    RAISE EXCEPTION 'supersedes target not found' USING ERRCODE = '23503';
  END IF;

  FOR ref IN SELECT x ->> 'uri' FROM jsonb_array_elements(NEW.source_refs) AS x WHERE x ->> 'uri' LIKE 'memory://%' LOOP
    IF ref !~ '^memory://[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'source memory not found: %', ref USING ERRCODE = '23503';
    END IF;
    src := substr(ref, 10)::uuid;
    IF NOT EXISTS (SELECT 1 FROM memory AS m WHERE m.id = src) THEN
      RAISE EXCEPTION 'source memory not found: %', ref USING ERRCODE = '23503';
    END IF;
    -- 외부 오염은 보수적으로 전파한다: 근거가 external 이거나 user store 이거나 아직 검토 전(provisional)이면 파생도 external
    IF EXISTS (
      SELECT 1 FROM memory AS m
      INNER JOIN store AS s ON s.id = m.store_id
      WHERE m.id = src AND (m.origin = 'external' OR m.status = 'provisional' OR s.kind = 'user')
    ) THEN
      NEW.origin := 'external';
    END IF;
  END LOOP;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION app_sec.memory_before_update() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  tr memory_transition;
BEGIN
  IF (NEW.id, NEW.tenant_id, NEW.store_id, NEW.kind, NEW.created_by, NEW.on_behalf_of, NEW.created_at, NEW.session_ref, NEW.tier)
     IS DISTINCT FROM
     (OLD.id, OLD.tenant_id, OLD.store_id, OLD.kind, OLD.created_by, OLD.on_behalf_of, OLD.created_at, OLD.session_ref, OLD.tier) THEN
    RAISE EXCEPTION 'immutable column changed';
  END IF;
  IF OLD.origin = 'external' AND NEW.origin = 'internal' THEN
    RAISE EXCEPTION 'origin cannot be laundered to internal';
  END IF;
  IF NEW.status <> OLD.status THEN
    SELECT * INTO tr FROM memory_transition AS t WHERE t.from_status = OLD.status AND t.to_status = NEW.status;
    IF NOT found THEN
      RAISE EXCEPTION 'illegal transition % -> %', OLD.status, NEW.status;
    END IF;
    IF (tr.by_role = 'curator') <> (app_sec.ctx_user() IS NOT NULL) THEN
      RAISE EXCEPTION 'transition % -> % is for the % role', OLD.status, NEW.status, tr.by_role USING ERRCODE = '42501';
    END IF;
  END IF;
  IF (NEW.title, NEW.body, NEW.source_refs) IS DISTINCT FROM (OLD.title, OLD.body, OLD.source_refs)
     AND NOT (NEW.status = OLD.status AND OLD.status IN ('proposed', 'active')) AND NEW.status <> 'deleted' THEN
    RAISE EXCEPTION 'content edit not allowed in this transition';
  END IF;
  IF NEW.status = 'deleted' THEN
    NEW.body := NULL;
    NEW.title := '[deleted]';
  END IF;
  NEW.version := OLD.version + 1;
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE FUNCTION app_sec.memory_set_tier() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF app_sec.ctx_user() IS NOT NULL THEN
    NEW.conflict_with := NULL;
    NEW.tier := app_sec.risk_tier(NEW);
    SELECT r.initial_status INTO NEW.status FROM approval_tier_rule AS r WHERE r.tier = NEW.tier;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION app_sec.memory_after_write() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  op memory_op;
  actor uuid := coalesce(app_sec.ctx_user(), app_sec.ctx_agent(), NEW.created_by);
  why text := current_setting('app.reason', true);
BEGIN
  op := CASE
    WHEN TG_OP = 'INSERT' THEN 'propose'
    WHEN NEW.status = OLD.status THEN 'edit'
    ELSE (SELECT t.op FROM memory_transition AS t WHERE t.from_status = OLD.status AND t.to_status = NEW.status)
  END;
  PERFORM app_sec.write_version(NEW, op, actor, why);
  IF TG_OP = 'INSERT' AND EXISTS (
    SELECT 1 FROM approval_tier_rule AS r
    WHERE r.tier = NEW.tier AND r.initial_status = NEW.status AND r.initial_status <> 'proposed'
  ) THEN
    PERFORM app_sec.write_version(NEW, 'auto_activate', actor, why);
  END IF;
  IF op = 'delete' THEN
    IF OLD.content_hash IS NOT NULL THEN
      INSERT INTO deleted_hash (store_id, content_hash, reason) VALUES (NEW.store_id, OLD.content_hash, coalesce(why, 'delete'))
      ON CONFLICT DO NOTHING;
    END IF;
    UPDATE memory_version SET snapshot = NULL WHERE memory_id = NEW.id AND snapshot IS NOT NULL;
  END IF;
  RETURN NULL;
END $$;

CREATE FUNCTION app_sec.search(
  p_query text,
  p_stores uuid[] DEFAULT null,
  p_statuses memory_status[] DEFAULT ARRAY['active']::memory_status[]
) RETURNS TABLE (id uuid, store_id uuid, kind memory_kind, title text, status memory_status, score real)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
#variable_conflict use_column
DECLARE v_tsq tsquery;
BEGIN
  IF length(p_query) > 1000 THEN
    RAISE EXCEPTION 'search query too long: at most 1000 characters' USING ERRCODE = '22023';
  END IF;
  v_tsq := websearch_to_tsquery('simple', p_query);
  IF numnode(v_tsq) > 64 THEN
    RAISE EXCEPTION 'search query too complex: at most 64 tsquery nodes' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  WITH q AS (SELECT v_tsq AS tsq)
    SELECT m.id, m.store_id, m.kind, m.title, m.status, ts_rank(m.search_tsv, q.tsq) AS score
    FROM q, memory AS m
    WHERE
      m.tenant_id = app_sec.ctx_tenant()
      AND m.search_tsv @@ q.tsq
      AND (p_stores IS NULL OR m.store_id = ANY (p_stores))
      AND m.status = ANY (coalesce(p_statuses, ARRAY['active']::memory_status[]))
      AND (
        (m.status IN ('active', 'provisional', 'superseded', 'expired') AND m.store_id IN (SELECT app_sec.my_stores('reader')))
        OR m.store_id IN (SELECT app_sec.my_stores('curator'))
        OR (
          m.status = 'proposed' AND coalesce(m.on_behalf_of, m.created_by) = app_sec.ctx_user()
          AND m.store_id IN (SELECT app_sec.my_stores('reader'))
        )
      )
    ORDER BY score DESC, m.id
    LIMIT 50;
END $$;

CREATE TRIGGER memory_bi3_tier BEFORE INSERT ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_set_tier();

GRANT SELECT ON approval_tier_rule TO app_rw;
REVOKE ALL ON FUNCTION app_sec.write_version(memory, memory_op, uuid, text) FROM public, app_rw;
REVOKE ALL ON FUNCTION app_sec.risk_tier(memory) FROM public, app_rw;
REVOKE ALL ON FUNCTION app_sec.memory_set_tier() FROM public, app_rw;
GRANT EXECUTE ON FUNCTION app_sec.search(text, uuid[], memory_status[]) TO app_rw;
