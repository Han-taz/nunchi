-- Forward migration 0011: memory identity (design v1.2 sections 2 to 4).
-- entity / entity_alias, memory.subject_id / attribute / last_confirmed_at, one live row per key,
-- the same-key decision in propose (reconfirm / conflict_with), the decide() replace path and memory_as_of().
-- Function and trigger bodies are copied from db/schema.sql (the schema-drift job compares the two).
-- memory_set_tier keeps 0010's server-decided origin/containment (source_facts) and drops its conflict_with reset,
-- which memory_key_decide now owns.
-- Existing non-note rows get a per-tenant '(legacy)' subject and a unique attribute so the key check can hold.

ALTER TYPE memory_op ADD VALUE 'reconfirm';

CREATE TABLE entity (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenant (id),
  kind text NOT NULL,
  canonical_name text NOT NULL,
  UNIQUE (tenant_id, id)
);
CREATE TABLE entity_alias (
  tenant_id uuid NOT NULL,
  entity_id uuid NOT NULL,
  alias_norm text NOT NULL,   -- app_sec.norm_text() 결과. 트리거가 정규화한다
  PRIMARY KEY (tenant_id, alias_norm),
  CONSTRAINT alias_entity_same_tenant FOREIGN KEY (tenant_id, entity_id) REFERENCES entity (tenant_id, id)
);

ALTER TABLE memory ADD COLUMN subject_id uuid;
ALTER TABLE memory ADD COLUMN attribute text;
ALTER TABLE memory ADD COLUMN last_confirmed_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE memory DISABLE TRIGGER USER;
INSERT INTO entity (tenant_id, kind, canonical_name)
SELECT DISTINCT
  tenant_id,
  'legacy' AS kind,
  '(legacy)' AS canonical_name
FROM memory
WHERE kind <> 'note';
UPDATE memory SET
  subject_id = (
    SELECT e.id FROM entity AS e
    WHERE e.tenant_id = memory.tenant_id AND e.kind = 'legacy'
  ),
  attribute = 'legacy-' || memory.id
WHERE kind <> 'note';
ALTER TABLE memory ENABLE TRIGGER USER;

ALTER TABLE memory
ADD CONSTRAINT memory_subject_same_tenant FOREIGN KEY (tenant_id, subject_id) REFERENCES entity (tenant_id, id);
ALTER TABLE memory ADD CONSTRAINT memory_key_by_kind CHECK (
  CASE
    WHEN kind = 'note' THEN subject_id IS NULL AND attribute IS NULL
    ELSE subject_id IS NOT NULL AND attribute IS NOT NULL
  END
);
CREATE UNIQUE INDEX memory_live_key_uidx ON memory (store_id, subject_id, attribute)
WHERE status IN ('active', 'provisional');

ALTER TABLE entity ENABLE ROW LEVEL SECURITY;
ALTER TABLE entity FORCE ROW LEVEL SECURITY;
CREATE POLICY entity_read ON entity FOR SELECT USING (tenant_id = app_sec.ctx_tenant());
ALTER TABLE entity_alias ENABLE ROW LEVEL SECURITY;
ALTER TABLE entity_alias FORCE ROW LEVEL SECURITY;
CREATE POLICY entity_alias_read ON entity_alias FOR SELECT USING (tenant_id = app_sec.ctx_tenant());

CREATE FUNCTION app_sec.norm_text(t text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT lower(btrim(regexp_replace(t, '\s+', ' ', 'g')))
$$;
CREATE FUNCTION app_sec.alias_before_write() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  NEW.alias_norm := app_sec.norm_text(NEW.alias_norm);
  RETURN NEW;
END $$;
CREATE TRIGGER entity_alias_norm BEFORE INSERT OR UPDATE ON entity_alias
FOR EACH ROW EXECUTE FUNCTION app_sec.alias_before_write();

CREATE FUNCTION app_sec.resolve_entity(p_name text) RETURNS uuid
LANGUAGE sql STABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT a.entity_id FROM entity_alias AS a WHERE a.alias_norm = app_sec.norm_text(p_name)
$$;
CREATE FUNCTION app_sec.memory_key_decide() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  live memory;
BEGIN
  IF NEW.attribute IS NOT NULL THEN
    NEW.attribute := app_sec.norm_text(NEW.attribute);
  END IF;
  IF app_sec.ctx_user() IS NULL THEN
    RETURN NEW;
  END IF;
  NEW.conflict_with := NULL;
  IF NEW.subject_id IS NULL OR NEW.attribute IS NULL OR NEW.store_id NOT IN (SELECT app_sec.my_stores('contributor')) THEN
    RETURN NEW;
  END IF;
  SELECT * INTO live FROM memory AS m
  WHERE m.store_id = NEW.store_id AND m.tenant_id = NEW.tenant_id AND m.subject_id = NEW.subject_id
    AND m.attribute = NEW.attribute AND m.status IN ('active', 'provisional')
  FOR UPDATE;
  IF NOT found THEN
    RETURN NEW;
  END IF;
  IF NEW.content_hash IS NOT NULL AND NEW.content_hash = live.content_hash THEN
    UPDATE memory SET last_confirmed_at = now() WHERE id = live.id;
    RETURN NULL;
  END IF;
  NEW.conflict_with := live.id;
  NEW.supersedes_id := live.id;
  RETURN NEW;
END $$;
CREATE TRIGGER memory_bi2k_key BEFORE INSERT ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_key_decide();

CREATE OR REPLACE FUNCTION app_sec.memory_before_update() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  tr memory_transition;
  q record;
BEGIN
  IF (NEW.id, NEW.tenant_id, NEW.store_id, NEW.kind, NEW.created_by, NEW.on_behalf_of, NEW.created_at, NEW.session_ref, NEW.tier)
     IS DISTINCT FROM
     (OLD.id, OLD.tenant_id, OLD.store_id, OLD.kind, OLD.created_by, OLD.on_behalf_of, OLD.created_at, OLD.session_ref, OLD.tier) THEN
    RAISE EXCEPTION 'immutable column changed';
  END IF;
  IF (NEW.subject_id, NEW.attribute) IS DISTINCT FROM (OLD.subject_id, OLD.attribute) THEN
    IF OLD.status <> 'proposed' THEN
      RAISE EXCEPTION 'immutable column changed';
    END IF;
    -- 별개로 저장: curator 가 제안의 키를 고치면 충돌 대상을 새 키로 다시 찾는다
    NEW.attribute := app_sec.norm_text(NEW.attribute);
    SELECT m.id INTO NEW.conflict_with FROM memory AS m
    WHERE m.store_id = OLD.store_id AND m.subject_id = NEW.subject_id AND m.attribute = NEW.attribute
      AND m.status IN ('active', 'provisional');
    NEW.supersedes_id := NEW.conflict_with;
  END IF;
  IF NEW.status = 'active' AND OLD.status <> 'active' THEN
    NEW.last_confirmed_at := now();
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
    IF tr.reviewed THEN
      IF app_sec.ctx_user() IN (OLD.created_by, coalesce(OLD.on_behalf_of, OLD.created_by)) THEN
        RAISE EXCEPTION 'separation of duties: the proposer cannot review' USING ERRCODE = '42501';
      END IF;
      SELECT * INTO q FROM app_sec.quorum(OLD, NEW.status);
      IF q.have < q.needed THEN
        RAISE EXCEPTION 'quorum not met: % of % reviews', q.have, q.needed USING ERRCODE = '42501';
      END IF;
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
CREATE OR REPLACE FUNCTION app_sec.memory_set_tier() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE cont text;
BEGIN
  IF app_sec.ctx_user() IS NOT NULL THEN
    -- origin 과 containment 는 출처에서 서버가 정한다. 클라이언트 값은 올리는 쪽으로만 반영된다 (내릴 수 없다).
    SELECT f.p_origin, f.p_containment INTO NEW.origin, cont FROM app_sec.source_facts(NEW) AS f;
    IF jsonb_typeof(NEW.gate_result) <> 'object' THEN
      NEW.gate_result := '{}';
    END IF;
    cont := CASE
      WHEN cont = 'unverified' OR coalesce(NEW.gate_result ->> 'containment', 'ok') <> 'ok' THEN 'unverified'
      ELSE coalesce(cont, NEW.gate_result ->> 'containment')
    END;
    IF cont IS NOT NULL THEN
      NEW.gate_result := NEW.gate_result || jsonb_build_object('containment', cont);
    END IF;
    NEW.tier := app_sec.risk_tier(NEW);
    SELECT r.initial_status INTO NEW.status FROM approval_tier_rule AS r WHERE r.tier = NEW.tier;
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION app_sec.memory_after_write() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  v_op memory_op;
  actor uuid := coalesce(app_sec.ctx_user(), app_sec.ctx_agent(), NEW.created_by);
  why text := current_setting('app.reason', true);
BEGIN
  v_op := CASE
    WHEN TG_OP = 'INSERT' THEN 'propose'
    WHEN NEW.status = OLD.status AND NEW.last_confirmed_at IS DISTINCT FROM OLD.last_confirmed_at
      AND (NEW.title, NEW.body, NEW.source_refs) IS NOT DISTINCT FROM (OLD.title, OLD.body, OLD.source_refs) THEN 'reconfirm'
    WHEN NEW.status = OLD.status THEN 'edit'
    ELSE (SELECT t.op FROM memory_transition AS t WHERE t.from_status = OLD.status AND t.to_status = NEW.status)
  END;
  PERFORM app_sec.write_version(NEW, v_op, actor, why);
  -- 제안자 신뢰는 전이의 op 마다 trust_rule 한 행으로 갱신한다 (규칙이 없는 op 는 아무 행도 만들지 않는다)
  INSERT INTO proposer_trust AS pt (principal_id, store_id, points, approved, rejected, retracted, demoted_until)
  SELECT
    NEW.created_by, NEW.store_id, r.points, r.approved, r.rejected, r.retracted,
    CASE WHEN r.demote_days > 0 THEN now() + make_interval(days => r.demote_days) END
  FROM trust_rule AS r WHERE r.op = v_op
  ON CONFLICT (principal_id, store_id) DO UPDATE SET
    points = pt.points + excluded.points,
    approved = pt.approved + excluded.approved,
    rejected = pt.rejected + excluded.rejected,
    retracted = pt.retracted + excluded.retracted,
    demoted_until = coalesce(excluded.demoted_until, pt.demoted_until),
    updated_at = now();
  IF TG_OP = 'INSERT' AND EXISTS (
    SELECT 1 FROM approval_tier_rule AS r
    WHERE r.tier = NEW.tier AND r.initial_status = NEW.status AND r.initial_status <> 'proposed'
  ) THEN
    PERFORM app_sec.write_version(NEW, 'auto_activate', actor, why);
  END IF;
  IF v_op = 'delete' THEN
    IF OLD.content_hash IS NOT NULL THEN
      INSERT INTO deleted_hash (store_id, content_hash, reason) VALUES (NEW.store_id, OLD.content_hash, coalesce(why, 'delete'))
      ON CONFLICT DO NOTHING;
    END IF;
    UPDATE memory_version SET snapshot = NULL WHERE memory_id = NEW.id AND snapshot IS NOT NULL;
  END IF;
  RETURN NULL;
END $$;
CREATE OR REPLACE FUNCTION app_sec.decide(
  p_nonce uuid, p_memory uuid, p_expected_version integer, p_verdict text, p_reason text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  me uuid := app_sec.ctx_user();
  c approval_card;
  m memory;
  tr memory_transition;
  q record;
  refusal text;
  target memory_status;
  v_outcome text;
  v_old uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'no user context' USING ERRCODE = '28000';
  END IF;
  IF p_verdict NOT IN ('approve', 'confirm', 'reject', 'retract', 'comment') THEN
    RAISE EXCEPTION 'unknown verdict %', p_verdict USING ERRCODE = '22023';
  END IF;
  SELECT * INTO c FROM approval_card WHERE nonce = p_nonce FOR UPDATE;
  SELECT * INTO m FROM memory WHERE id = c.memory_id FOR UPDATE;
  refusal := CASE
    WHEN c.nonce IS NULL THEN 'unknown_nonce'
    WHEN c.issued_to <> me THEN 'wrong_clicker'
    WHEN c.consumed_at IS NOT NULL THEN 'duplicate:' || c.outcome
    WHEN c.memory_id <> p_memory THEN 'mismatch'
    WHEN c.expires_at < now() THEN 'expired'
    WHEN NOT EXISTS (
      SELECT 1 FROM app_sec.my_store_roles() AS r WHERE r.store_id = m.store_id AND r.role = 'curator'
    ) THEN 'not_curator'
    WHEN m.version <> p_expected_version THEN 'stale'
    WHEN me IN (m.created_by, coalesce(m.on_behalf_of, m.created_by)) THEN 'self_review'
  END;
  IF refusal IS NOT NULL THEN
    RETURN refusal;
  END IF;

  target := CASE p_verdict WHEN 'approve' THEN 'active' WHEN 'confirm' THEN 'active' WHEN 'reject' THEN 'rejected' WHEN 'retract' THEN 'rejected' END;
  SELECT * INTO tr FROM memory_transition AS t WHERE t.from_status = m.status AND t.to_status = target;
  IF target IS NOT NULL AND NOT found THEN
    RAISE EXCEPTION 'illegal transition % -> %', m.status, target;
  END IF;
  INSERT INTO review (memory_id, reviewer_id, verdict, note, via_agent_id, card_nonce)
  VALUES (m.id, me, coalesce(tr.op::text, p_verdict), p_reason, app_sec.ctx_agent(), p_nonce);
  PERFORM set_config('app.reason', coalesce(p_reason, ''), true);

  v_outcome := CASE WHEN target IS NULL THEN 'comment' ELSE target::text END;
  IF target IS NOT NULL THEN
    SELECT * INTO q FROM app_sec.quorum(m, target);
    IF q.have < q.needed THEN
      v_outcome := 'pending_quorum:' || q.have || '/' || q.needed;
    ELSE
      -- 교체: 같은 키(또는 supersedes_id)의 살아 있는 행을 먼저 superseded 로 바꾼 뒤 새 행을 활성화한다 (한 트랜잭션, 지연 제약 없음)
      IF target = 'active' THEN
        UPDATE memory SET status = 'superseded', valid_to = coalesce(m.valid_from, current_date)
        WHERE id <> m.id AND status IN ('active', 'provisional')
          AND (id = m.supersedes_id OR (store_id = m.store_id AND subject_id = m.subject_id AND attribute = m.attribute))
        RETURNING id INTO v_old;
      END IF;
      UPDATE memory SET
        status = target,
        supersedes_id = coalesce(v_old, supersedes_id),
        valid_from = CASE WHEN v_old IS NULL THEN valid_from ELSE coalesce(valid_from, current_date) END
      WHERE id = m.id AND version = p_expected_version;
    END IF;
  END IF;
  UPDATE approval_card SET consumed_at = now(), outcome = v_outcome WHERE nonce = p_nonce;
  RETURN v_outcome;
END $$;
CREATE FUNCTION app_sec.memory_as_of(p_store uuid, p_subject uuid, p_attribute text, p_as_of date)
RETURNS TABLE (id uuid, title text, body text, status memory_status, valid_from date, valid_to date)
LANGUAGE sql STABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT m.id, m.title, m.body, m.status, m.valid_from, m.valid_to FROM memory AS m
  WHERE m.store_id = p_store AND m.subject_id = p_subject AND m.attribute = app_sec.norm_text(p_attribute)
    AND m.status IN ('active', 'provisional', 'superseded', 'expired')
    AND (m.valid_from IS NULL OR m.valid_from <= p_as_of)
    AND (m.valid_to IS NULL OR p_as_of < m.valid_to)
  ORDER BY m.valid_from DESC NULLS LAST, m.created_at DESC
  LIMIT 1
$$;
GRANT SELECT ON entity, entity_alias TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.norm_text(text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.resolve_entity(text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.memory_as_of(uuid, uuid, text, date) TO app_rw;
