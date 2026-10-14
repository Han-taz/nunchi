-- Forward migration 0031: 위험 등급, 신뢰 점수, 정족수 표를 지운다 (design v1.3 U33c).
-- memory.tier, approval_tier, approval_tier_rule, proposer_trust, trust_rule, app_sec.risk_tier() 를 없앤다.
-- 최초 상태는 등급표 대신 memory_set_origin 이 정한다 (충돌한 값 proposed, 개인 store active, 나머지 provisional).
-- 이 임시 규칙은 U33d 의 remember() 가 대신하고 INSERT 권한과 함께 사라진다.
-- 함수 본문과 정책은 db/schema.sql 에서 그대로 복사했다 (schema-drift 가 둘을 비교한다).
DROP TRIGGER memory_bi3_tier ON memory;
DROP POLICY memory_propose ON memory;
DROP FUNCTION app_sec.memory_set_tier();
DROP FUNCTION app_sec.risk_tier(memory);
ALTER TABLE memory DROP COLUMN tier;
DROP TABLE trust_rule;
DROP TABLE proposer_trust;
DROP TABLE approval_tier_rule;
DROP TYPE approval_tier;

-- 제안: contributor 이상. 최초 상태는 memory_bi3_origin 이 정한다. U33d 가 이 정책과 함께 INSERT 권한을 없앤다.
-- 작성자 바인딩: 에이전트면 created_by=에이전트, on_behalf_of=사용자 / 아니면 created_by=사용자, on_behalf_of=NULL
CREATE POLICY memory_propose ON memory FOR INSERT WITH CHECK (
  status IN ('provisional', 'proposed', 'active') AND version = 1
  AND tenant_id = app_sec.ctx_tenant()
  AND store_id IN (SELECT app_sec.my_stores('contributor'))
  AND created_by = coalesce(app_sec.ctx_agent(), app_sec.ctx_user())
  AND on_behalf_of IS NOT DISTINCT FROM (CASE WHEN app_sec.ctx_agent() IS NOT null THEN app_sec.ctx_user() END)
);

-- origin 과 containment 는 출처에서, 최초 상태는 서버가 정한다: 클라이언트가 보낸 status 는 요청 컨텍스트가 있으면 덮어쓴다.
-- 충돌한 값(conflict_with)은 proposed, 개인 store 는 active, 나머지는 provisional 이다. 이 상태 정하기는 U33d 의 remember() 가 대신한다.
-- source_facts 는 app_rw 가 부를 수 없으므로 소유자 권한 트리거가 대신 부른다. 이름 순서상 memory_bi, memory_bi2_hash 다음에 돈다.
CREATE FUNCTION app_sec.memory_set_origin() RETURNS trigger
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
    NEW.status := CASE
      WHEN NEW.conflict_with IS NOT NULL THEN 'proposed'
      WHEN EXISTS (SELECT 1 FROM store AS s WHERE s.id = NEW.store_id AND s.kind = 'user') THEN 'active'
      ELSE 'provisional'
    END;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER memory_bi3_origin BEFORE INSERT ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_set_origin();

-- UPDATE: 불변 컬럼, origin 단방향, memory_transition 표, 본문 편집 범위, 버전 증가, 삭제 시 본문 제거
CREATE OR REPLACE FUNCTION app_sec.memory_before_update() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  tr memory_transition;
  v_op memory_op;
BEGIN
  IF (NEW.id, NEW.tenant_id, NEW.store_id, NEW.kind, NEW.created_by, NEW.on_behalf_of, NEW.created_at, NEW.session_ref)
     IS DISTINCT FROM
     (OLD.id, OLD.tenant_id, OLD.store_id, OLD.kind, OLD.created_by, OLD.on_behalf_of, OLD.created_at, OLD.session_ref) THEN
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
