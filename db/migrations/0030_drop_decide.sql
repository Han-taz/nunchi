-- Forward migration 0030: DB 의 decide 경로를 지운다 (design v1.3 U33b).
-- 승인 카드 nonce 로만 움직이던 decide(), issue_card(), quorum() 과 전이 표의 reviewed 열, proposed 에서 나가는 세 행을 없앤다.
-- 상태가 proposed 인 행은 더 이어지는 전이가 없다 (U38 의 이전 스크립트가 처리한다).
-- memory_before_update 본문은 db/schema.sql 에서 그대로 복사했다 (schema-drift 가 둘을 비교한다).
DROP FUNCTION app_sec.decide(uuid, uuid, integer, text, text);
DROP FUNCTION app_sec.issue_card(uuid);
DROP FUNCTION app_sec.quorum(memory, memory_status);
DELETE FROM memory_transition
WHERE from_status = 'proposed';
ALTER TABLE memory_transition DROP COLUMN reviewed;

-- UPDATE: 불변 컬럼, origin 단방향, memory_transition 표, 본문 편집 범위, 버전 증가, 삭제 시 본문 제거
CREATE OR REPLACE FUNCTION app_sec.memory_before_update() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  tr memory_transition;
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
