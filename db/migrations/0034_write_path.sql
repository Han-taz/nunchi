-- Forward migration 0034: 쓰기는 remember() 하나다 (design v1.3 U33f).
-- memory 의 INSERT 정책과 INSERT 권한을 없애고, 키 판정 트리거(memory_key_decide)는 정규화(memory_norm_key)만 남긴다.
-- memory_set_origin 의 옛 상태 정하기 분기를 지운다. challenger 는 쓴 사람 본인에게도 보인다 (memory_read).
-- 함수 본문과 정책은 db/schema.sql 에서 그대로 복사했다 (schema-drift 가 둘을 비교한다).
DROP POLICY memory_propose ON memory;
DROP POLICY memory_read ON memory;
REVOKE INSERT ON memory FROM app_rw;

-- 읽기: reader 이상. provisional 은 active 와 같이 reader 에게 보인다 (검토 전이라는 표시는 status 가 한다).
-- proposed 는 대리된 사용자 본인(에이전트 유무 무관) 또는 사람 작성자와 curator만,
-- deleted/rejected 는 curator만. 봇을 공유하는 다른 사용자는 남의 proposed 를 보지 못한다.
-- challenger(살아 있는 값과 다른 값의 제안)도 같다: 쓴 사람 본인과 curator 만 본다 (살아 있는 행에 붙여 보여 주는 일은 U37 이 한다).
CREATE POLICY memory_read ON memory FOR SELECT USING (
  tenant_id = app_sec.ctx_tenant() AND (
    (
      status IN ('active', 'provisional', 'superseded', 'expired')
      AND store_id IN (SELECT app_sec.my_stores('reader'))
    )
    OR store_id IN (SELECT app_sec.my_stores('curator'))
    OR (
      status IN ('proposed', 'challenger') AND coalesce(on_behalf_of, created_by) = app_sec.ctx_user()
      AND store_id IN (SELECT app_sec.my_stores('reader'))
    )
  )
);

DROP TRIGGER memory_bi2k_key ON memory;
DROP FUNCTION app_sec.memory_key_decide();
-- 키와 값은 정규화해서 저장한다 (attribute, value). 같은 키와 값의 판정은 remember() 가 한다.
-- memory_bi2_hash 가 content_hash 를 정한 뒤, memory_bi3_origin 이 origin 을 정하기 전에 돈다.
CREATE FUNCTION app_sec.memory_norm_key() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF NEW.attribute IS NOT NULL THEN
    NEW.attribute := app_sec.norm_text(NEW.attribute);
  END IF;
  NEW.value := nullif(app_sec.norm_text(NEW.value), '');
  RETURN NEW;
END $$;

CREATE TRIGGER memory_bi2k_norm BEFORE INSERT ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_norm_key();

-- origin 과 containment 는 출처에서 서버가 정한다. 외부 출처이거나 지시문 표지(flags)가 붙은 기억은 시간으로 승격하지 않는다 (결정 1):
-- promote_at 을 비우면 합의(confirm, 같은 값을 다른 사람이 말함)로만 active 가 된다.
-- source_facts 는 app_rw 가 부를 수 없으므로 소유자 권한 트리거가 대신 부른다. 이름 순서상 memory_bi, memory_bi2_hash 다음에 돈다.
CREATE OR REPLACE FUNCTION app_sec.memory_set_origin() RETURNS trigger
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
    IF (NEW.origin = 'external' OR CASE
      WHEN NOT (NEW.gate_result ? 'flags') THEN false
      WHEN jsonb_typeof(NEW.gate_result -> 'flags') = 'array' THEN jsonb_array_length(NEW.gate_result -> 'flags') > 0
      ELSE true
    END) THEN
      NEW.promote_at := NULL;
    END IF;
  END IF;
  RETURN NEW;
END $$;
