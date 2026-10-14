-- Forward migration 0033: app_sec.remember() (design v1.3 U33e).
-- 5.1 의 표 10행을 실행하는 쓰기 함수다. 옛 INSERT 경로는 호출자가 옮겨 갈 때까지 남는다:
-- memory_propose 정책이 basis 가 빈 INSERT 만 받고, remember() 가 쓴 행(basis 가 있다)은 memory_set_origin 이 상태를 건드리지 않는다.
-- 외부 출처와 지시문 표시가 붙은 기억은 promote_at 이 비어 시간으로 승격하지 않는다.
-- 함수 본문과 정책은 db/schema.sql 에서 그대로 복사했다 (schema-drift 가 둘을 비교한다).
DROP POLICY memory_propose ON memory;

-- 제안: contributor 이상. 최초 상태는 memory_bi3_origin 이 정한다. basis 는 app_sec.remember() 만 정하므로 옛 INSERT 경로는 비어 있어야 한다.
-- U33f 가 remember() 로 호출자를 옮긴 뒤 이 정책과 INSERT 권한을 없앤다.
-- 작성자 바인딩: 에이전트면 created_by=에이전트, on_behalf_of=사용자 / 아니면 created_by=사용자, on_behalf_of=NULL
CREATE POLICY memory_propose ON memory FOR INSERT WITH CHECK (
  status IN ('provisional', 'proposed', 'active') AND basis IS null AND version = 1
  AND tenant_id = app_sec.ctx_tenant()
  AND store_id IN (SELECT app_sec.my_stores('contributor'))
  AND created_by = coalesce(app_sec.ctx_agent(), app_sec.ctx_user())
  AND on_behalf_of IS NOT DISTINCT FROM (CASE WHEN app_sec.ctx_agent() IS NOT null THEN app_sec.ctx_user() END)
);

-- INSERT: 요청 컨텍스트가 있으면 저자·대리·tenant 를 세션에 묶고(NULL 은 채우고, 다르면 42501),
-- version 을 1 로 고정한다 (status 는 memory_bi3_origin 이 정한다). 컨텍스트가 없는 소유자 적재는 값을 그대로 둔다.
-- 이 트리거는 호출자(app_rw) 권한으로 돈다: 정책과 RLS 가 그대로 적용된다. 내부 함수(content_hmac 등)는
-- app_rw 가 부를 수 없으므로 해시 계산은 SECURITY DEFINER 트리거 memory_bi2_hash / memory_bu2_hash 가 한다.
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
    WHERE m.id = NEW.supersedes_id AND m.store_id = NEW.store_id AND m.status IN ('active', 'provisional', 'superseded')
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

-- origin 과 containment 는 출처에서 서버가 정한다. 외부 출처이거나 지시문 표지(flags)가 붙은 기억은 시간으로 승격하지 않는다 (결정 1):
-- promote_at 을 비우면 합의(confirm, 같은 값을 다른 사람이 말함)로만 active 가 된다.
-- 옛 INSERT 경로(basis 가 비어 있다)는 최초 상태도 여기서 정한다: 충돌한 값(conflict_with)은 proposed, 개인 store 는 active, 나머지는 provisional.
-- remember() 가 쓴 행은 basis 가 있고 상태도 이미 정해져 있다. U33f 가 옛 경로와 이 분기를 함께 지운다.
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
    IF NEW.basis IS NULL THEN
      NEW.status := CASE
        WHEN NEW.conflict_with IS NOT NULL THEN 'proposed'
        WHEN EXISTS (SELECT 1 FROM store AS s WHERE s.id = NEW.store_id AND s.kind = 'user') THEN 'active'
        ELSE 'provisional'
      END;
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

-- 쓰기 판정. 키의 살아 있는 행과 열린 challenger 를 잠그고 5.1 의 표에서 첫 일치 행을 실행한다.
-- 결과: created, confirmed, reconfirmed, challenged, superseded, retracted
-- (r_id = 결과가 된 행, r_conflict = challenged 일 때 살아 있는 행).
-- 증거 author 가 없으면 호출자, 시각이 없으면 지금이다. 같은 키에 동시에 쓰는 두 번째 INSERT 는 23505 를 받고 한 번 다시 판정한다.
-- p_retract 가 있으면 9, 10행만 본다: 대상이 provisional 이나 challenger 면 rejected, active 면 expired.
CREATE FUNCTION app_sec.remember(
  p_store uuid, p_kind memory_kind, p_title text, p_body text, p_source_refs jsonb,
  p_subject uuid, p_attribute text, p_value text, p_gate jsonb,
  p_consensus text, p_evidence jsonb, p_retract uuid DEFAULT null
) RETURNS TABLE (r_outcome text, r_id uuid, r_status memory_status, r_conflict uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  me uuid := app_sec.ctx_user();
  by_whom uuid := coalesce(app_sec.ctx_agent(), app_sec.ctx_user());
  behalf uuid := CASE WHEN app_sec.ctx_agent() IS NULL THEN NULL ELSE app_sec.ctx_user() END;
  v_attr text := app_sec.norm_text(p_attribute);
  v_val text := nullif(app_sec.norm_text(p_value), '');
  v_hash text := CASE WHEN p_body IS NULL THEN NULL ELSE app_sec.content_hmac(p_body) END;
  v_agreed boolean;
  v_basis promotion_basis;
  v_after interval;
  v_ev jsonb;
  v_fresh jsonb;
  live memory;
  chal memory;
  tgt memory;
  fresh memory;
  ref text;
  attempt integer;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'no user context' USING ERRCODE = '28000';
  END IF;
  IF p_consensus NOT IN ('agreed', 'stated') THEN
    RAISE EXCEPTION 'unknown consensus %', p_consensus USING ERRCODE = '22023';
  END IF;
  IF p_store NOT IN (SELECT app_sec.my_stores('contributor')) THEN
    RAISE EXCEPTION 'not a contributor of this store' USING ERRCODE = '42501';
  END IF;
  -- memory:// 인용은 호출자가 읽을 수 있는 기억만이다. 존재하지 않음과 읽을 수 없음은 같은 오류다 (memory_read 정책과 같은 조건)
  FOR ref IN SELECT x ->> 'uri' FROM jsonb_array_elements(p_source_refs) AS x WHERE x ->> 'uri' LIKE 'memory://%' LOOP
    IF ref ~ '^memory://[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' AND NOT EXISTS (
      SELECT 1 FROM memory AS m
      WHERE m.id = substr(ref, 10)::uuid AND m.tenant_id = app_sec.ctx_tenant() AND (
        (m.status IN ('active', 'provisional', 'superseded', 'expired') AND m.store_id IN (SELECT app_sec.my_stores('reader')))
        OR m.store_id IN (SELECT app_sec.my_stores('curator'))
        OR (m.status IN ('proposed', 'challenger') AND coalesce(m.on_behalf_of, m.created_by) = me AND m.store_id IN (SELECT app_sec.my_stores('reader')))
      )
    ) THEN
      RAISE EXCEPTION 'source memory not found: %', ref USING ERRCODE = '23503';
    END IF;
  END LOOP;

  v_agreed := p_consensus = 'agreed' OR EXISTS (SELECT 1 FROM store AS s WHERE s.id = p_store AND s.kind = 'user');
  v_basis := CASE
    WHEN EXISTS (SELECT 1 FROM store AS s WHERE s.id = p_store AND s.kind = 'user') THEN 'user_store'
    WHEN v_agreed THEN 'agreed'
    ELSE 'stated'
  END;
  v_after := coalesce((SELECT a.promote_after FROM store_autonomy AS a WHERE a.store_id = p_store), interval '24 hours');
  v_ev := (
    SELECT jsonb_agg(jsonb_build_object(
      'uri', e ->> 'uri', 'post_id', e ->> 'post_id', 'author', coalesce(e ->> 'author', me::text),
      'author_name', e ->> 'author_name', 'said_at', coalesce(e ->> 'said_at', clock_timestamp()::text)
    ))
    FROM jsonb_array_elements(CASE WHEN jsonb_array_length(coalesce(p_evidence, '[]'::jsonb)) = 0 THEN '[{}]'::jsonb ELSE p_evidence END) AS e
  );

  FOR attempt IN 1..2 LOOP
    BEGIN
      live := NULL;
      chal := NULL;
      IF p_retract IS NOT NULL THEN
        -- 9, 10행
        SELECT * INTO tgt FROM memory AS m
        WHERE m.id = p_retract AND m.store_id = p_store AND m.tenant_id = app_sec.ctx_tenant() AND m.status IN ('provisional', 'challenger', 'active')
        FOR UPDATE;
        IF NOT found THEN
          RAISE EXCEPTION 'retract target not found' USING ERRCODE = 'P0002';
        END IF;
        PERFORM app_sec.move(
          tgt.id, CASE WHEN tgt.status = 'active' THEN 'expired'::memory_status ELSE 'rejected'::memory_status END,
          'retract', app_sec.evidence_reason(v_basis, v_ev)
        );
        PERFORM app_sec.record_evidence(tgt.id, 'retract', v_basis, v_ev);
        IF tgt.status IN ('active', 'provisional') AND tgt.subject_id IS NOT NULL THEN
          PERFORM app_sec.adopt_orphan_challenger(tgt.store_id, tgt.subject_id, tgt.attribute);
        END IF;
        r_outcome := 'retracted';
        r_id := tgt.id;
      ELSE
        IF p_subject IS NOT NULL AND v_attr IS NOT NULL THEN
          SELECT * INTO live FROM memory AS m
          WHERE m.store_id = p_store AND m.tenant_id = app_sec.ctx_tenant() AND m.subject_id = p_subject AND m.attribute = v_attr
            AND m.status IN ('active', 'provisional')
          FOR UPDATE;
          SELECT * INTO chal FROM memory AS m
          WHERE m.store_id = p_store AND m.tenant_id = app_sec.ctx_tenant() AND m.subject_id = p_subject AND m.attribute = v_attr
            AND m.status = 'challenger'
          FOR UPDATE;
        END IF;
        r_conflict := NULL;
        IF live.id IS NULL THEN
          -- 1, 2행
          PERFORM set_config('app.reason', app_sec.evidence_reason(v_basis, v_ev), true);
          INSERT INTO memory (
            tenant_id, store_id, kind, status, title, body, source_refs, created_by, on_behalf_of,
            subject_id, attribute, value, gate_result, basis, promote_at
          ) VALUES (
            app_sec.ctx_tenant(), p_store, p_kind, CASE WHEN v_agreed THEN 'active' ELSE 'provisional' END::memory_status, p_title, p_body, p_source_refs,
            by_whom, behalf, p_subject, v_attr, v_val, coalesce(p_gate, '{}'), v_basis, CASE WHEN v_agreed THEN NULL ELSE now() + v_after END
          ) RETURNING * INTO fresh;
          PERFORM app_sec.record_evidence(fresh.id, 'propose', v_basis, v_ev);
          r_outcome := 'created';
          r_id := fresh.id;
        ELSIF coalesce(CASE WHEN v_val IS NOT NULL AND live.value IS NOT NULL THEN v_val = live.value ELSE v_hash = live.content_hash END, false) THEN
          IF live.status = 'provisional' AND EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_ev) AS e
            WHERE NOT EXISTS (SELECT 1 FROM memory_evidence AS x WHERE x.memory_id = live.id AND x.author = e ->> 'author')
          ) THEN
            -- 3행
            PERFORM app_sec.move(live.id, 'active', 'confirm', app_sec.evidence_reason('agreed', v_ev), 'agreed');
            PERFORM app_sec.record_evidence(live.id, 'confirm', 'agreed', v_ev);
            r_outcome := 'confirmed';
          ELSE
            -- 4행
            v_fresh := app_sec.new_evidence(live.id, 'reconfirm', v_ev);
            IF jsonb_array_length(v_fresh) > 0 THEN
              IF chal.id IS NOT NULL AND EXISTS (
                SELECT 1 FROM jsonb_array_elements(v_fresh) AS e WHERE (e ->> 'said_at')::timestamptz > chal.created_at
              ) THEN
                PERFORM app_sec.move(chal.id, 'rejected', 'retract', 'reaffirmed');
              END IF;
              PERFORM set_config('app.op', 'reconfirm', true);
              PERFORM set_config('app.reason', app_sec.evidence_reason(v_basis, v_fresh), true);
              UPDATE memory SET last_confirmed_at = clock_timestamp(), value = coalesce(value, v_val) WHERE id = live.id;
              PERFORM app_sec.record_evidence(live.id, 'reconfirm', v_basis, v_fresh);
            END IF;
            r_outcome := 'reconfirmed';
          END IF;
          r_id := live.id;
        ELSIF chal.id IS NOT NULL AND coalesce(CASE WHEN v_val IS NOT NULL AND chal.value IS NOT NULL THEN v_val = chal.value ELSE v_hash = chal.content_hash END, false) THEN
          IF v_agreed OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_ev) AS e
            WHERE NOT EXISTS (SELECT 1 FROM memory_evidence AS x WHERE x.memory_id = chal.id AND x.author = e ->> 'author')
          ) THEN
            -- 5행: 이전 행을 먼저 superseded 로 옮긴 뒤 challenger 를 active 로 올린다
            PERFORM app_sec.move(live.id, 'superseded', 'supersede', 'superseded by ' || chal.id);
            PERFORM app_sec.move(chal.id, 'active', 'confirm', app_sec.evidence_reason('agreed', v_ev), 'agreed', live.id);
            PERFORM app_sec.record_evidence(chal.id, 'confirm', 'agreed', v_ev);
            r_outcome := 'superseded';
            r_conflict := live.id;
          ELSE
            -- 6행
            v_fresh := app_sec.new_evidence(chal.id, 'reconfirm', v_ev);
            IF jsonb_array_length(v_fresh) > 0 THEN
              PERFORM set_config('app.op', 'reconfirm', true);
              PERFORM set_config('app.reason', app_sec.evidence_reason(v_basis, v_fresh), true);
              UPDATE memory SET last_confirmed_at = clock_timestamp() WHERE id = chal.id;
              PERFORM app_sec.record_evidence(chal.id, 'reconfirm', v_basis, v_fresh);
            END IF;
            r_outcome := 'reconfirmed';
            r_conflict := live.id;
          END IF;
          r_id := chal.id;
        ELSE
          -- 7, 8행: 열린 challenger 는 먼저 닫는다
          IF chal.id IS NOT NULL THEN
            PERFORM app_sec.move(chal.id, 'rejected', 'retract', 'replaced');
          END IF;
          IF v_agreed THEN
            PERFORM app_sec.move(live.id, 'superseded', 'supersede', 'superseded by a newer value');
          END IF;
          PERFORM set_config('app.reason', app_sec.evidence_reason(v_basis, v_ev), true);
          INSERT INTO memory (
            tenant_id, store_id, kind, status, title, body, source_refs, created_by, on_behalf_of,
            subject_id, attribute, value, gate_result, basis, promote_at, supersedes_id, conflict_with, valid_from
          ) VALUES (
            app_sec.ctx_tenant(), p_store, p_kind, CASE WHEN v_agreed THEN 'active' ELSE 'challenger' END::memory_status, p_title, p_body, p_source_refs,
            by_whom, behalf, p_subject, v_attr, v_val, coalesce(p_gate, '{}'), v_basis, CASE WHEN v_agreed THEN NULL ELSE now() + v_after END,
            live.id, CASE WHEN v_agreed THEN NULL ELSE live.id END, CASE WHEN v_agreed THEN current_date END
          ) RETURNING * INTO fresh;
          PERFORM app_sec.record_evidence(fresh.id, 'propose', v_basis, v_ev);
          r_outcome := CASE WHEN v_agreed THEN 'superseded' ELSE 'challenged' END;
          r_id := fresh.id;
          r_conflict := CASE WHEN v_agreed THEN NULL ELSE live.id END;
        END IF;
      END IF;
      PERFORM set_config('app.op', '', true);
      PERFORM set_config('app.reason', '', true);
      SELECT m.status INTO r_status FROM memory AS m WHERE m.id = r_id;
      RETURN NEXT;
      RETURN;
    EXCEPTION WHEN unique_violation THEN
      IF attempt = 2 THEN
        RAISE;
      END IF;
    END;
  END LOOP;
END $$;

GRANT EXECUTE ON FUNCTION
app_sec.remember(uuid, memory_kind, text, text, jsonb, uuid, text, text, jsonb, text, jsonb, uuid)
TO app_rw;
