-- fix.sql — 핵심 수정 PoC. db/tests/fixtures/schema_v1_0_vulnerable.sql + smoke_test + exp1/2 실행 후 상태 위에 적용.
\set ON_ERROR_STOP on
BEGIN;

-- ── 0. 실험으로 생긴 오염 정리 (교차 테넌트 grant / tenant 불일치 행) ──
DELETE FROM store_grant WHERE principal_id='00000000-0000-0000-0000-0000000000ff';
DELETE FROM memory WHERE title='tenant mismatch row';
DELETE FROM memory WHERE title IN ('probe');          -- 크로스 store supersedes 링크 행
DELETE FROM deleted_hash WHERE reason='censor';

-- ── 1. 최소 권한: app_rw 는 memory 에만 INSERT/UPDATE. 나머지는 읽기만 ──
REVOKE INSERT, UPDATE ON tenant, principal, group_member, store, store_grant,
                        deleted_hash, memory_version, review FROM app_rw;

-- ── 2. 테넌트 일관성: 복합 FK ──
ALTER TABLE store     ADD CONSTRAINT store_tenant_id_uq     UNIQUE (tenant_id, id);
ALTER TABLE principal ADD CONSTRAINT principal_tenant_id_uq UNIQUE (tenant_id, id);
ALTER TABLE memory    ADD CONSTRAINT memory_store_same_tenant FOREIGN KEY (tenant_id, store_id) REFERENCES store(tenant_id, id);
ALTER TABLE store_grant ADD COLUMN tenant_id uuid;
UPDATE store_grant g SET tenant_id = s.tenant_id FROM store s WHERE s.id = g.store_id;
ALTER TABLE store_grant ALTER COLUMN tenant_id SET NOT NULL,
  ADD CONSTRAINT grant_store_same_tenant     FOREIGN KEY (tenant_id, store_id)     REFERENCES store(tenant_id, id),
  ADD CONSTRAINT grant_principal_same_tenant FOREIGN KEY (tenant_id, principal_id) REFERENCES principal(tenant_id, id);

-- ── 3. 보안 스키마: 비밀키, 요청 컨텍스트, 실효 권한 ──
CREATE SCHEMA app_sec;
GRANT USAGE ON SCHEMA app_sec TO app_rw;
CREATE TABLE app_sec.secret (name text PRIMARY KEY, value bytea NOT NULL);   -- app_rw 접근 불가
INSERT INTO app_sec.secret VALUES ('hash_key', gen_random_bytes(32));

-- 내용 해시 = HMAC(정규화 본문). 평문 sha256 오라클 차단. 서버가 계산(클라이언트 값 무시)
CREATE FUNCTION app_sec.content_hmac(t text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT encode(hmac(convert_to(lower(regexp_replace(coalesce(t,''), '\s+', ' ', 'g')), 'UTF8'),
                     (SELECT value FROM app_sec.secret WHERE name='hash_key'), 'sha256'), 'hex')
$$;

-- 요청 컨텍스트: principal 존재/활성/종류/테넌트를 DB가 검증하고 LOCAL 로만 설정. 트랜잭션 xid 에 바인딩.
CREATE FUNCTION app_sec.begin_request(p_user uuid, p_agent uuid DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE t uuid;
BEGIN
  SELECT tenant_id INTO t FROM principal WHERE id = p_user AND kind = 'user' AND active;
  IF t IS NULL THEN RAISE EXCEPTION 'unknown or inactive user %', p_user USING ERRCODE = '28000'; END IF;
  IF p_agent IS NOT NULL AND NOT EXISTS (SELECT 1 FROM principal WHERE id = p_agent AND kind = 'agent' AND active AND tenant_id = t) THEN
    RAISE EXCEPTION 'unknown or inactive agent %', p_agent USING ERRCODE = '28000';
  END IF;
  PERFORM set_config('app.user_id',   p_user::text, true);
  PERFORM set_config('app.agent_id',  coalesce(p_agent::text, ''), true);
  PERFORM set_config('app.tenant_id', t::text, true);
  PERFORM set_config('app.ctx_xid',   pg_current_xact_id()::text, true);   -- 풀러 세션 누수 방지 (primary 전용; 복제본은 lease 방식)
END $$;

CREATE FUNCTION app_sec.ctx_user()   RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN current_setting('app.ctx_xid', true) = pg_current_xact_id()::text
              THEN nullif(current_setting('app.user_id', true), '')::uuid END $$;
CREATE FUNCTION app_sec.ctx_agent()  RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN current_setting('app.ctx_xid', true) = pg_current_xact_id()::text
              THEN nullif(current_setting('app.agent_id', true), '')::uuid END $$;
CREATE FUNCTION app_sec.ctx_tenant() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN current_setting('app.ctx_xid', true) = pg_current_xact_id()::text
              THEN nullif(current_setting('app.tenant_id', true), '')::uuid END $$;

-- 실효 권한 집합 (요청당 1회 평가되도록 정책에서 IN (subquery) 로 사용)
-- NULL-safe 교집합: 에이전트가 있으면 사용자/에이전트 모두 grant 가 있어야 하고, 둘 중 낮은 쪽.
CREATE FUNCTION app_sec.my_store_roles() RETURNS TABLE (store_id uuid, role store_role)
LANGUAGE sql STABLE AS $$
  WITH ctx AS (SELECT app_sec.ctx_user() u, app_sec.ctx_agent() a, app_sec.ctx_tenant() t),
  ur AS (SELECT g.store_id, max(g.role) role FROM ctx, store_grant g
          WHERE ctx.u IS NOT NULL AND g.tenant_id = ctx.t
            AND g.principal_id IN (SELECT principal_closure(ctx.u)) GROUP BY g.store_id),
  ar AS (SELECT g.store_id, max(g.role) role FROM ctx, store_grant g
          WHERE ctx.a IS NOT NULL AND g.tenant_id = ctx.t
            AND g.principal_id IN (SELECT principal_closure(ctx.a)) GROUP BY g.store_id)
  SELECT ur.store_id, CASE WHEN ctx.a IS NULL THEN ur.role ELSE least(ur.role, ar.role) END
  FROM ctx, ur
  JOIN store s ON s.id = ur.store_id AND s.archived_at IS NULL
  LEFT JOIN ar ON ar.store_id = ur.store_id
  WHERE ctx.a IS NULL OR ar.role IS NOT NULL
$$;
CREATE INDEX IF NOT EXISTS store_grant_principal_idx ON store_grant (principal_id);
CREATE INDEX IF NOT EXISTS group_member_member_idx   ON group_member (member_id);

-- ── 4. memory 정책 재작성 ──
DROP POLICY memory_read ON memory; DROP POLICY memory_propose ON memory; DROP POLICY memory_curate ON memory;

CREATE POLICY memory_read ON memory FOR SELECT USING (
  tenant_id = app_sec.ctx_tenant() AND (
       (status IN ('active','superseded','expired')
        AND store_id IN (SELECT r.store_id FROM app_sec.my_store_roles() r))
    OR store_id IN (SELECT r.store_id FROM app_sec.my_store_roles() r WHERE r.role = 'curator')
    -- proposed: 대리된 사용자 본인(에이전트 유무 무관) 또는 사람이 직접 쓴 경우 작성자. 봇을 공유하는 타 사용자는 못 봄
    OR (status = 'proposed' AND coalesce(on_behalf_of, created_by) = app_sec.ctx_user()
        AND store_id IN (SELECT r.store_id FROM app_sec.my_store_roles() r))
  )
);
CREATE POLICY memory_propose ON memory FOR INSERT WITH CHECK (
  status = 'proposed' AND version = 1
  AND tenant_id = app_sec.ctx_tenant()
  AND store_id IN (SELECT r.store_id FROM app_sec.my_store_roles() r WHERE r.role >= 'contributor')
  AND created_by = coalesce(app_sec.ctx_agent(), app_sec.ctx_user())                    -- 저자 위조 불가
  AND on_behalf_of IS NOT DISTINCT FROM (CASE WHEN app_sec.ctx_agent() IS NULL THEN NULL ELSE app_sec.ctx_user() END)
);
CREATE POLICY memory_curate ON memory FOR UPDATE
  USING      (tenant_id = app_sec.ctx_tenant() AND store_id IN (SELECT r.store_id FROM app_sec.my_store_roles() r WHERE r.role = 'curator'))
  WITH CHECK (tenant_id = app_sec.ctx_tenant() AND store_id IN (SELECT r.store_id FROM app_sec.my_store_roles() r WHERE r.role = 'curator'));

-- ── 5. memory_version / review / deleted_hash 에 RLS (읽기는 해당 memory 가 보일 때만; 쓰기는 트리거 전용) ──
ALTER TABLE memory_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE review         ENABLE ROW LEVEL SECURITY;
ALTER TABLE deleted_hash   ENABLE ROW LEVEL SECURITY;
CREATE POLICY mv_read ON memory_version FOR SELECT USING (EXISTS (SELECT 1 FROM memory m WHERE m.id = memory_id));
CREATE POLICY rv_read ON review         FOR SELECT USING (EXISTS (SELECT 1 FROM memory m WHERE m.id = memory_id));
CREATE POLICY dh_read ON deleted_hash   FOR SELECT USING (store_id IN (SELECT r.store_id FROM app_sec.my_store_roles() r WHERE r.role = 'curator'));

-- ── 6. 감사 로그: 해시 체인 + redact 가능 구조 (snapshot_hash 는 남겨 체인 검증 유지) ──
ALTER TABLE memory_version ADD COLUMN snapshot_hash text, ADD COLUMN prev_hash text, ADD COLUMN row_hash text;
CREATE OR REPLACE FUNCTION forbid_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION '% is append-only', TG_TABLE_NAME; END IF;
  -- redact 만 허용: snapshot 외의 모든 컬럼이 동일해야 함 (reason 포함)
  IF NOT (OLD.snapshot IS NOT NULL AND NEW.snapshot IS NULL
          AND (to_jsonb(OLD) - 'snapshot') = (to_jsonb(NEW) - 'snapshot')) THEN
    RAISE EXCEPTION '%: only redaction (snapshot -> NULL) allowed', TG_TABLE_NAME;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER review_append_only BEFORE UPDATE OR DELETE ON review FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

CREATE FUNCTION app_sec.write_version(p_mem memory, p_op memory_op, p_actor uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE snap jsonb; prev text; shash text; ts timestamptz := now();
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_mem.id::text, 0));
  snap := CASE WHEN p_op IN ('delete','redact') THEN NULL
               ELSE jsonb_build_object('title', p_mem.title, 'body', p_mem.body, 'status', p_mem.status,
                                       'source_refs', p_mem.source_refs, 'origin', p_mem.origin, 'store_id', p_mem.store_id) END;
  shash := encode(sha256(convert_to(coalesce(snap::text, ''), 'UTF8')), 'hex');
  SELECT row_hash INTO prev FROM memory_version WHERE memory_id = p_mem.id ORDER BY id DESC LIMIT 1;
  INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot, reason, at, snapshot_hash, prev_hash, row_hash)
  VALUES (p_mem.id, p_mem.version, p_op, p_actor, snap, p_reason, ts, shash, prev,
          encode(sha256(convert_to(concat_ws('|', prev, p_mem.id, p_mem.version, p_op, p_actor, shash, ts::text), 'UTF8')), 'hex'));
END $$;

-- ── 7. memory 트리거: 바인딩·해시·계보 검사·상태 기계·버전·감사 ──
CREATE FUNCTION app_sec.memory_before_insert() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r text; mid uuid;
BEGIN
  NEW.created_by   := coalesce(app_sec.ctx_agent(), app_sec.ctx_user());     -- 세션에서 강제 바인딩
  NEW.on_behalf_of := CASE WHEN app_sec.ctx_agent() IS NULL THEN NULL ELSE app_sec.ctx_user() END;
  NEW.tenant_id    := app_sec.ctx_tenant();
  NEW.status := 'proposed'; NEW.version := 1; NEW.gate_result := '{}';
  NEW.content_hash := app_sec.content_hmac(NEW.body);
  -- deleted_hash 는 contributor 에게 RLS 로 안 보이므로 SECURITY DEFINER 검사 함수 사용
  IF app_sec.is_deleted_content(NEW.store_id, NEW.content_hash) THEN
    RAISE EXCEPTION 'content was previously deleted in this store' USING ERRCODE = '23505';
  END IF;
  -- supersedes 는 같은 store 의, 내가 읽을 수 있는 active 항목만 (존재 오라클 차단: 못 읽으면 '없음'과 동일 오류)
  IF NEW.supersedes_id IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM memory m WHERE m.id = NEW.supersedes_id AND m.store_id = NEW.store_id AND m.status = 'active') THEN
    RAISE EXCEPTION 'supersedes target not found' USING ERRCODE = '23503';
  END IF;
  -- memory:// 근거는 같은 테넌트이고 내가 읽을 수 있어야 함
  FOR r IN SELECT x->>'uri' FROM jsonb_array_elements(NEW.source_refs) x WHERE x->>'uri' LIKE 'memory://%' LOOP
    mid := substr(r, 10)::uuid;
    IF NOT EXISTS (SELECT 1 FROM memory m WHERE m.id = mid) THEN
      RAISE EXCEPTION 'source memory not found: %', r USING ERRCODE = '23503';
    END IF;
    -- 외부 taint 보수적 전파: 근거 중 하나라도 external 이면 파생도 external
    IF EXISTS (SELECT 1 FROM memory m WHERE m.id = mid AND m.origin = 'external') THEN NEW.origin := 'external'; END IF;
  END LOOP;
  RETURN NEW;
END $$;
CREATE FUNCTION app_sec.is_deleted_content(s uuid, h text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (SELECT 1 FROM deleted_hash WHERE store_id = s AND content_hash = h) $$;

CREATE FUNCTION app_sec.memory_before_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- 불변 컬럼
  IF (NEW.id, NEW.tenant_id, NEW.store_id, NEW.kind, NEW.created_by, NEW.on_behalf_of, NEW.created_at, NEW.session_ref)
     IS DISTINCT FROM (OLD.id, OLD.tenant_id, OLD.store_id, OLD.kind, OLD.created_by, OLD.on_behalf_of, OLD.created_at, OLD.session_ref) THEN
    RAISE EXCEPTION 'immutable column changed';
  END IF;
  -- origin 은 internal 로 "승격" 불가 (세탁 금지). external 로 낮추는 것만 허용
  IF OLD.origin = 'external' AND NEW.origin = 'internal' THEN RAISE EXCEPTION 'origin cannot be laundered to internal'; END IF;
  -- 상태 기계
  IF NEW.status <> OLD.status AND NOT (
       (OLD.status = 'proposed' AND NEW.status IN ('active','rejected'))
    OR (OLD.status = 'active'   AND NEW.status IN ('superseded','expired','deleted'))
    OR (OLD.status IN ('superseded','expired','rejected') AND NEW.status = 'deleted')) THEN
    RAISE EXCEPTION 'illegal transition % -> %', OLD.status, NEW.status;
  END IF;
  -- 본문/제목/출처 편집은 proposed 또는 active(동일 상태 유지) 에서만
  IF (NEW.title, NEW.body, NEW.source_refs) IS DISTINCT FROM (OLD.title, OLD.body, OLD.source_refs)
     AND NOT (NEW.status = OLD.status AND OLD.status IN ('proposed','active')) AND NEW.status <> 'deleted' THEN
    RAISE EXCEPTION 'content edit not allowed in this transition';
  END IF;
  IF NEW.status = 'deleted' THEN NEW.body := NULL; NEW.title := '[deleted]'; END IF;   -- source_refs 는 CHECK 때문에 유지 (URL 내 PII 는 별도 정책)
  NEW.version := OLD.version + 1;           -- 낙관적 잠금은 WHERE version = $expected 로
  NEW.updated_at := now();
  NEW.content_hash := CASE WHEN NEW.body IS NULL THEN OLD.content_hash ELSE app_sec.content_hmac(NEW.body) END;
  RETURN NEW;
END $$;

CREATE FUNCTION app_sec.memory_after_write() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE op memory_op; actor uuid := coalesce(app_sec.ctx_user(), app_sec.ctx_agent());
BEGIN
  IF TG_OP = 'INSERT' THEN op := 'propose';
  ELSIF NEW.status <> OLD.status THEN
    op := CASE NEW.status WHEN 'active' THEN 'approve' WHEN 'rejected' THEN 'reject' WHEN 'superseded' THEN 'supersede'
                          WHEN 'expired' THEN 'expire' WHEN 'deleted' THEN 'delete' END;
  ELSE op := 'edit'; END IF;
  PERFORM app_sec.write_version(NEW, op, actor, current_setting('app.reason', true));
  IF op = 'delete' THEN
    INSERT INTO deleted_hash (store_id, content_hash, reason) VALUES (NEW.store_id, OLD.content_hash, coalesce(current_setting('app.reason', true), 'delete'))
      ON CONFLICT DO NOTHING;
    UPDATE memory_version SET snapshot = NULL WHERE memory_id = NEW.id AND snapshot IS NOT NULL;   -- 과거 스냅샷 redact
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER memory_bi BEFORE INSERT ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_before_insert();
CREATE TRIGGER memory_bu BEFORE UPDATE ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_before_update();
CREATE TRIGGER memory_aw AFTER INSERT OR UPDATE ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_after_write();

-- 체인 검증 함수 (worker 가 주기적으로 실행하고 루트를 외부 WORM 에 앵커)
CREATE FUNCTION app_sec.verify_chain(p_mem uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT bool_and(row_hash = encode(sha256(convert_to(concat_ws('|', prev_hash, memory_id, version, op, actor_id, snapshot_hash, at::text), 'UTF8')), 'hex')
                  AND prev_hash IS NOT DISTINCT FROM expected_prev)
  FROM (SELECT v.*, lag(row_hash) OVER (ORDER BY id) AS expected_prev FROM memory_version v WHERE memory_id = p_mem) x
$$;
COMMIT;
