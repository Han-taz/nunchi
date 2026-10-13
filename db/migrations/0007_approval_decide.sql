-- Forward migration 0007: approval model B, second half (decide(), quorum and separation of duties, proposer trust).
-- Statements are copied from db/schema.sql (the schema-drift job compares the two).
ALTER TABLE memory_transition ADD COLUMN reviewed boolean NOT NULL DEFAULT false;
UPDATE memory_transition SET reviewed = true
WHERE op IN ('approve', 'confirm', 'reject', 'retract');

-- 비대칭 점수: 승인/확인 +1, 반려 -5, 회수 -10 (이미 노출된 것이라 반려의 두 배) + 30일 강등. 전이의 op 마다 한 행이다.
CREATE TABLE trust_rule (
  op memory_op PRIMARY KEY,
  points integer NOT NULL,
  approved integer NOT NULL,
  rejected integer NOT NULL,
  retracted integer NOT NULL,
  demote_days integer NOT NULL
);
INSERT INTO trust_rule (op, points, approved, rejected, retracted, demote_days) VALUES
('approve', 1, 1, 0, 0, 0),
('confirm', 1, 1, 0, 0, 0),
('reject', -5, 0, 1, 0, 0),
('retract', -10, 0, 0, 1, 30);

-- 승인 카드: nonce 1개 = (memory, 수신 curator) 1장. 클릭은 nonce 로만 들어오고 decide() 만 읽고 쓴다 (app_rw 권한 없음).
CREATE TABLE approval_card (
  nonce uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  memory_id uuid NOT NULL REFERENCES memory (id),
  version_at_issue integer NOT NULL,
  issued_to uuid NOT NULL REFERENCES principal (id),
  platform text NOT NULL,
  channel_id text,
  message_ts text,
  issued_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT now() + interval '14 days',
  consumed_at timestamptz,
  outcome text
);

ALTER TABLE review DROP CONSTRAINT review_verdict_check;
ALTER TABLE review
ADD CONSTRAINT review_verdict_check CHECK (verdict IN ('approve', 'reject', 'comment', 'confirm', 'retract')),
ADD COLUMN via_agent_id uuid REFERENCES principal (id),
ADD COLUMN card_nonce uuid REFERENCES approval_card (nonce);

CREATE FUNCTION app_sec.quorum(p_mem memory, p_to memory_status) RETURNS TABLE (have integer, needed integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT
    (
      SELECT count(DISTINCT v.reviewer_id)::integer FROM review AS v, memory AS m
      WHERE
        m.id = p_mem.id
        AND m.store_id IN (SELECT app_sec.my_stores('curator'))
        AND v.memory_id = m.id
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

CREATE OR REPLACE FUNCTION app_sec.memory_after_write() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  v_op memory_op;
  actor uuid := coalesce(app_sec.ctx_user(), app_sec.ctx_agent(), NEW.created_by);
  why text := current_setting('app.reason', true);
BEGIN
  v_op := CASE
    WHEN TG_OP = 'INSERT' THEN 'propose'
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

CREATE FUNCTION app_sec.decide(
  p_nonce uuid, p_memory uuid, p_expected_version integer, p_verdict text, p_reason text DEFAULT null
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
      UPDATE memory SET status = 'superseded', valid_to = coalesce(m.valid_from, current_date)
      WHERE id = m.supersedes_id AND status IN ('active', 'provisional') AND target = 'active';
      UPDATE memory SET status = target WHERE id = m.id AND version = p_expected_version;
    END IF;
  END IF;
  UPDATE approval_card SET consumed_at = now(), outcome = v_outcome WHERE nonce = p_nonce;
  RETURN v_outcome;
END $$;

GRANT EXECUTE ON FUNCTION app_sec.decide(uuid, uuid, integer, text, text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.quorum(memory, memory_status) TO app_rw;
