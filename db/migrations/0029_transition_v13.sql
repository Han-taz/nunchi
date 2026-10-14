-- Forward migration 0029: transition table v1.3 and app.op (design v1.3 U32b).
-- Statements are copied from db/schema.sql (the schema-drift job compares the two).
-- memory_transition is keyed (from_status, to_status, op) and holds by_roles. Every status change names its op in the
-- transaction-local setting app.op; memory_bu looks the row up with it.
-- The callers that exist today (decide, mark_expired) now set app.op.
-- The proposed rows and the reviewed column stay until U33 replaces the card path.
DROP TABLE memory_transition;
DROP TYPE transition_role;
-- 상태 기계 (v1.3 §5.2): 허용되는 (from, to, op) 전이는 이 표가 전부다. memory_bu 는 이 표를 한 번 조회할 뿐 분기하지 않는다.
-- op = 전이를 일으키는 함수가 트랜잭션 로컬 설정 app.op 로 넘기는 값이고 버전 기록에도 그대로 남는다. app.op 없는 상태 UPDATE 는 42501.
-- by_roles = 이 전이를 할 수 있는 역할. 요청 컨텍스트가 있으면 contributor 와 curator, 없으면 system 으로 본다. curator 는 삭제에만 쓴다.
-- reviewed = 전이마다 review 행(verdict = op)이 정족수만큼 있어야 하는가. 카드 경로(U33 이 지운다)가 남아 있는 동안의 호환 열이다.
-- proposed 에서 나가는 세 행도 같은 이유로 남긴다 (U33 이 remember() 로 쓰기 경로를 바꿀 때, U38 이 proposed 행을 없앨 때 지운다).
CREATE TYPE transition_role AS ENUM ('contributor', 'system', 'curator');
CREATE TABLE memory_transition (
  from_status memory_status NOT NULL,
  to_status memory_status NOT NULL,
  op memory_op NOT NULL,
  by_roles transition_role[] NOT NULL CHECK (cardinality(by_roles) > 0),
  reviewed boolean NOT NULL DEFAULT false,
  PRIMARY KEY (from_status, to_status, op)
);
INSERT INTO memory_transition (from_status, to_status, op, by_roles, reviewed) VALUES
('provisional', 'active', 'confirm', '{contributor}', true),
('provisional', 'active', 'promote', '{system}', false),
('provisional', 'rejected', 'retract', '{contributor}', true),
('provisional', 'superseded', 'supersede', '{contributor,system}', false),
('active', 'superseded', 'supersede', '{contributor,system}', false),
('active', 'expired', 'retract', '{contributor}', false),
('active', 'expired', 'expire', '{system}', false),
('challenger', 'active', 'confirm', '{contributor}', false),
('challenger', 'active', 'promote', '{system}', false),
('challenger', 'rejected', 'retract', '{contributor}', false),
('active', 'deleted', 'delete', '{curator}', false),
('provisional', 'deleted', 'delete', '{curator}', false),
('challenger', 'deleted', 'delete', '{curator}', false),
('superseded', 'deleted', 'delete', '{curator}', false),
('expired', 'deleted', 'delete', '{curator}', false),
('rejected', 'deleted', 'delete', '{curator}', false),
('proposed', 'provisional', 'auto_activate', '{system}', false),
('proposed', 'active', 'approve', '{curator}', true),
('proposed', 'rejected', 'reject', '{curator}', true);
GRANT SELECT ON memory_transition TO app_rw;

-- 버전/리뷰 테이블은 수정·삭제 금지. 예외: memory_version.snapshot 을 NULL 로 만드는 redact 만 허용
-- (snapshot 을 뺀 모든 컬럼이 동일해야 함. 컬럼이 추가돼도 자동으로 비교 대상에 포함)
CREATE OR REPLACE FUNCTION forbid_mutation() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION '% is append-only', TG_TABLE_NAME; END IF;
  IF TG_TABLE_NAME = 'memory_evidence' THEN
    IF NOT (OLD.author_name IS NOT NULL AND NEW.author_name IS NULL
            AND to_jsonb(OLD) - 'author_name' = to_jsonb(NEW) - 'author_name'
            AND EXISTS (SELECT 1 FROM memory AS m WHERE m.id = OLD.memory_id AND m.status = 'deleted')) THEN
      RAISE EXCEPTION 'memory_evidence is append-only (only the delete scrub of author_name is allowed)';
    END IF;
    RETURN NEW;
  END IF;
  IF TG_TABLE_NAME <> 'memory_version' THEN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
  END IF;
  IF NOT (OLD.snapshot IS NOT NULL AND NEW.snapshot IS NULL
          AND to_jsonb(OLD) - 'snapshot' = to_jsonb(NEW) - 'snapshot') THEN
    RAISE EXCEPTION 'memory_version: only redaction (snapshot -> NULL) allowed';
  END IF;
  RETURN NEW;
END $$;

-- 정족수: 이 전이를 뒷받침하는 review(verdict = 전이의 op)의 서로 다른 비저자 reviewer 수와 필요한 수.
-- 결정 시점에 reviewer(와 via_agent)가 지금도 그 store 의 curator 인 review 만 센다: 역할을 잃은 curator 의 이전 승인은 세지 않는다.
-- 다른 사람의 grant 를 읽어야 해서 SECURITY DEFINER 이고, 호출자가 그 store 의 curator 일 때만 0 이상을 돌려준다(그 외는 0).
-- 활성화(to = active)는 등급의 approvals_needed, 반려/회수는 1.
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
        AND v.verdict = (SELECT t.op::text FROM memory_transition AS t WHERE t.from_status = m.status AND t.to_status = p_to AND t.reviewed)
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

-- UPDATE: 불변 컬럼, origin 단방향, memory_transition 표, 본문 편집 범위, 버전 증가, 삭제 시 본문 제거
CREATE OR REPLACE FUNCTION app_sec.memory_before_update() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  tr memory_transition;
  q record;
  v_op memory_op;
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
    v_op := nullif(current_setting('app.op', true), '')::memory_op;
    IF v_op IS NULL THEN
      RAISE EXCEPTION 'status change % -> % needs app.op', OLD.status, NEW.status USING ERRCODE = '42501';
    END IF;
    SELECT * INTO tr FROM memory_transition AS t WHERE t.from_status = OLD.status AND t.to_status = NEW.status AND t.op = v_op;
    IF NOT found THEN
      RAISE EXCEPTION 'illegal transition % -> % (%)', OLD.status, NEW.status, v_op;
    END IF;
    IF NOT (tr.by_roles && (
      CASE WHEN app_sec.ctx_user() IS NOT NULL THEN ARRAY['contributor', 'curator'] ELSE ARRAY['system'] END
    )::transition_role[]) THEN
      RAISE EXCEPTION 'transition % -> % (%) is for the % role', OLD.status, NEW.status, v_op, tr.by_roles USING ERRCODE = '42501';
    END IF;
    IF NEW.status NOT IN ('provisional', 'challenger') THEN
      NEW.promote_at := NULL;
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

-- 쓰기 후: 버전 기록. 삭제면 삭제 해시를 등록하고 과거 snapshot 을 전부 redact 한다
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
    ELSE nullif(current_setting('app.op', true), '')::memory_op
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
    UPDATE memory_evidence SET author_name = NULL WHERE memory_id = NEW.id AND author_name IS NOT NULL;
  END IF;
  RETURN NULL;
END $$;

-- 승인 함수: 카드 nonce 로만 승인/반려/의견. 멱등(소비된 nonce), 낙관적 잠금(expected_version), 클릭자 = 수신자.
-- 거절 사유는 위에서부터 첫 일치 하나만 반환하고 review 행도 버전도 남기지 않는다. 처리되면 review 를 쓰고 memory 를 UPDATE 하며
-- 정족수와 직무 분리의 최종 판정은 memory_bu 가 한다. verdict 는 approve/confirm(→ active), reject/retract(→ rejected), comment 이고
-- review 에는 현재 상태에서 그 전이의 op 로 기록한다 (proposed 의 approve 는 approve, provisional 의 approve 는 confirm).
CREATE OR REPLACE FUNCTION app_sec.decide(
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
  v_op memory_op;
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
  v_op := CASE
    WHEN target = 'active' THEN CASE WHEN m.status = 'proposed' THEN 'approve' ELSE 'confirm' END
    WHEN target = 'rejected' THEN CASE WHEN m.status = 'proposed' THEN 'reject' ELSE 'retract' END
  END;
  SELECT * INTO tr FROM memory_transition AS t WHERE t.from_status = m.status AND t.to_status = target AND t.op = v_op;
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
        PERFORM set_config('app.op', 'supersede', true);
        UPDATE memory SET status = 'superseded', valid_to = coalesce(m.valid_from, current_date)
        WHERE id <> m.id AND status IN ('active', 'provisional')
          AND (id = m.supersedes_id OR (store_id = m.store_id AND subject_id = m.subject_id AND attribute = m.attribute))
        RETURNING id INTO v_old;
      END IF;
      PERFORM set_config('app.op', v_op::text, true);
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

-- 워커 전용(컨텍스트 없음 = system 역할): valid_to 가 오늘 이전인 active 행을 expired 로. 옮긴 행 수를 돌려준다
CREATE OR REPLACE FUNCTION app_sec.mark_expired() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  PERFORM set_config('app.op', 'expire', true);
  UPDATE memory SET status = 'expired' WHERE status = 'active' AND valid_to < current_date;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
