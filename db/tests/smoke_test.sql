-- RLS 동작 검증용 스모크 테스트
\set ON_ERROR_STOP on
-- app_rw 역할과 최소 권한 GRANT 는 schema.sql 에 있다

-- 테스트 헬퍼는 전용 스키마 t 에 둔다 (schema.sql 에는 없다). app_rw 로 호출되므로 PUBLIC 실행을 허용한다
-- (schema.sql 이 끈 기본값을 이 세션에서만 되돌림). P3 는 이름이 아니라 스키마 t 전체를 제외한다.
-- P3c: P3 는 스키마 t 를 통째로 제외하므로, schema.sql 이 t 를 만들거나 쓰면 거기 둔 운영 함수가 보이지 않는다.
-- 헬퍼를 만들기 전에 t 가 없고 그 스키마의 객체(함수, 관계, 타입)도 없음을 확인한다.
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 't')
    AND NOT EXISTS (SELECT 1 FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace WHERE n.nspname = 't')
    AND NOT EXISTS (SELECT 1 FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace WHERE n.nspname = 't')
  THEN 'P3c schema t does not exist before the test helpers are created (ok)'
  ELSE 'P3c FAIL: schema.sql created or uses schema t' END;
CREATE SCHEMA t;
GRANT USAGE ON SCHEMA t TO app_rw;
ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
-- 헬퍼: t.eq = 쿼리 결과(text) 비교, t_err = 실행 시 SQLSTATE 비교('ok' = 성공). 호출자 권한으로 실행됨.
-- t_ctx = 요청 컨텍스트 시작. 새 스키마에서는 app_sec.begin_request, v1.0 취약 스키마에서는 옛 방식(트랜잭션 로컬
--         app.user_id/app.agent_id)으로 같은 사용자를 흉내 내서 mutation gate 가 같은 테스트를 양쪽에 돌릴 수 있게 한다.
--         user 가 NULL 이면 컨텍스트 없음(빈 값)이다.
-- t_role = 현재 컨텍스트의 한 store 에 대한 실효 role (my_store_roles 또는 v1.0 effective_role)
CREATE FUNCTION t.eq(label text, q text, expected text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  EXECUTE q INTO r;
  IF coalesce(r, 'NULL') = expected THEN RAISE NOTICE '% = % (ok)', label, expected;
  ELSE RAISE NOTICE '% FAIL: expected %, got %', label, expected, coalesce(r, 'NULL'); END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE '% FAIL: error % %', label, SQLSTATE, SQLERRM;
END $$;
CREATE FUNCTION t.err(label text, q text, expected text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE s text := 'ok';
BEGIN
  BEGIN EXECUTE q; EXCEPTION WHEN OTHERS THEN s := SQLSTATE; END;
  IF s = expected THEN RAISE NOTICE '% -> % (ok)', label, expected;
  ELSE RAISE NOTICE '% FAIL: expected %, got %', label, expected, s; END IF;
END $$;

CREATE FUNCTION t.ctx(u uuid, a uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF u IS NOT NULL AND to_regprocedure('app_sec.begin_request(uuid,uuid)') IS NOT NULL THEN
    PERFORM app_sec.begin_request(u, a);
  ELSE
    PERFORM set_config('app.user_id', coalesce(u::text, ''), true);
    PERFORM set_config('app.agent_id', coalesce(a::text, ''), true);
  END IF;
END $$;
-- t_ctx_soft = t_ctx, but a refused begin_request (inactive principal) leaves no context instead of aborting the script.
CREATE FUNCTION t.ctx_soft(u uuid, a uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM t.ctx(u, a);
EXCEPTION WHEN invalid_authorization_specification THEN
  NULL;
END $$;
CREATE FUNCTION t.role(s uuid) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  IF to_regprocedure('app_sec.my_store_roles()') IS NOT NULL THEN
    EXECUTE 'SELECT role::text FROM app_sec.my_store_roles() WHERE store_id = $1' INTO r USING s;
  ELSE
    EXECUTE 'SELECT effective_role($1)::text' INTO r USING s;
  END IF;
  RETURN r;
END $$;


INSERT INTO tenant (id, name) VALUES ('00000000-0000-0000-0000-000000000001', 'acme');
INSERT INTO principal (id, tenant_id, kind, external_id, display_name) VALUES
 ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-000000000001','user','alice','Alice(영업)'),
 ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-000000000001','user','bob','Bob(인사)'),
 ('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-000000000001','user','carol','Carol(영업 큐레이터)'),
 ('00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-000000000001','agent','sales-bot','영업 에이전트'),
 ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-000000000001','group','sales','영업팀');
INSERT INTO group_member VALUES ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000a1'),
                                ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000c1');
INSERT INTO store (id, tenant_id, kind, slug, description) VALUES
 ('00000000-0000-0000-0000-00000000f001','00000000-0000-0000-0000-000000000001','team','sales','영업팀 지식'),
 ('00000000-0000-0000-0000-00000000f002','00000000-0000-0000-0000-000000000001','team','hr','인사팀 지식');
INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES
 ('00000000-0000-0000-0000-00000000f001','00000000-0000-0000-0000-0000000000e1','contributor','00000000-0000-0000-0000-000000000001'),
 ('00000000-0000-0000-0000-00000000f001','00000000-0000-0000-0000-0000000000c1','curator','00000000-0000-0000-0000-000000000001'),
 ('00000000-0000-0000-0000-00000000f001','00000000-0000-0000-0000-0000000000d1','contributor','00000000-0000-0000-0000-000000000001'),
 ('00000000-0000-0000-0000-00000000f002','00000000-0000-0000-0000-0000000000b1','curator','00000000-0000-0000-0000-000000000001');
SET app.reason = 'original';
INSERT INTO memory (id, tenant_id, store_id, kind, status, title, body, source_refs, created_by) VALUES
 ('00000000-0000-0000-0000-0000000aa001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f002',
  'fact','active','연봉 밴드 정책','비공개','[{"uri":"https://hr/x"}]','00000000-0000-0000-0000-0000000000b1');
RESET app.reason;

SET ROLE app_rw;

-- 1) Alice+영업봇: hr store 안 보여야 함
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT 'T1 alice sees hr rows = ' || count(*) FROM memory; COMMIT;

-- 2) 영업봇이 Alice 대리로 제안 (proposed) → 성공
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
INSERT INTO memory (id, tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
VALUES ('00000000-0000-0000-0000-0000000bb001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001',
 'fact','A사 갱신 담당자 변경','김OO → 이OO','[{"uri":"https://crm/acct/A"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1');
SELECT 'T2 propose ok'; COMMIT;

-- 3) 영업봇이 active 로 바로 쓰기 시도 → 성공하되 트리거가 proposed 로 덮어쓴다
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.eq('T3 bot insert with status=active is stored as', $q$WITH i AS (
  INSERT INTO memory (tenant_id, store_id, kind, status, title, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','active','우회','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')
  RETURNING status) SELECT status::text FROM i$q$, 'proposed');
COMMIT;

-- 4) Alice(contributor)는 승인 불가 → 0 rows updated
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', NULL);
WITH u AS (UPDATE memory SET status='active' WHERE id='00000000-0000-0000-0000-0000000bb001' RETURNING 1)
SELECT 'T4 alice approve rows = ' || count(*) FROM u; COMMIT;

-- 5) Carol(curator) 승인 → 1 row
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000c1', NULL);
WITH u AS (UPDATE memory SET status='active' WHERE id='00000000-0000-0000-0000-0000000bb001' RETURNING 1)
SELECT 'T5 carol approve rows = ' || count(*) FROM u; COMMIT;

-- 6) Carol이 영업봇과 함께여도 봇 권한이 contributor라 승인 불가 (교집합)
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000d1');
WITH u AS (UPDATE memory SET title=title WHERE id='00000000-0000-0000-0000-0000000bb001' RETURNING 1)
SELECT 'T6 carol+bot curate rows = ' || count(*) FROM u; COMMIT;

-- 7) 버전 기록 수정 금지
RESET ROLE;
INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot)
VALUES ('00000000-0000-0000-0000-0000000bb001',1,'propose','00000000-0000-0000-0000-0000000000d1','{"title":"x"}')
ON CONFLICT DO NOTHING;
DO $$ BEGIN
  UPDATE memory_version SET reason='tamper';
  RAISE NOTICE 'T7 FAIL';
EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'T7 version tamper blocked (ok)';
END $$;
UPDATE memory_version SET snapshot = NULL WHERE memory_id = '00000000-0000-0000-0000-0000000bb001' AND version = 1;  -- redact 허용
SELECT 'T7b redact ok, snapshot null = ' || bool_and(snapshot IS NULL) FROM memory_version WHERE memory_id = '00000000-0000-0000-0000-0000000bb001' AND version = 1;

-- ═══ 회귀 테스트 X1–X6 (보안 수정 검증) ═══════════════════
-- 사전 데이터(소유자 권한): 다른 tenant, hr/sales 버전·리뷰 행
INSERT INTO tenant (id, name) VALUES ('00000000-0000-0000-0000-000000000002', 'other');
INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot, reason) VALUES
 ('00000000-0000-0000-0000-0000000aa001',1,'propose','00000000-0000-0000-0000-0000000000b1','{"title":"hr"}','original')
ON CONFLICT DO NOTHING;
INSERT INTO review (memory_id, reviewer_id, verdict, note) VALUES
 ('00000000-0000-0000-0000-0000000aa001','00000000-0000-0000-0000-0000000000b1','comment','hr 전용'),
 ('00000000-0000-0000-0000-0000000bb001','00000000-0000-0000-0000-0000000000c1','comment','sales 리뷰');

SET ROLE app_rw;

-- X1) 한쪽 권한이 없으면 교집합은 무권한 (least 의 NULL 무시 방지) + 미설정/빈 값은 fail-closed
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.eq('X1a bob(hr)+sales-bot role on sales', $q$SELECT t.role('00000000-0000-0000-0000-00000000f001')$q$, 'NULL');
SELECT t.eq('X1b bob+sales-bot role on hr (bot has no grant)', $q$SELECT t.role('00000000-0000-0000-0000-00000000f002')$q$, 'NULL');
SELECT t.eq('X1c bob+sales-bot visible memory rows', $q$SELECT count(*)::text FROM memory$q$, '0');
COMMIT;
BEGIN; SELECT t.ctx(NULL, NULL);
SELECT t.eq('X1d empty user_id role', $q$SELECT t.role('00000000-0000-0000-0000-00000000f001')$q$, 'NULL');
SELECT t.eq('X1e empty user_id visible rows', $q$SELECT count(*)::text FROM memory$q$, '0');
COMMIT;
BEGIN; SELECT t.ctx(NULL, '00000000-0000-0000-0000-0000000000d1');
SELECT t.eq('X1f agent only (no user) role', $q$SELECT t.role('00000000-0000-0000-0000-00000000f001')$q$, 'NULL');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000c1', NULL);
SELECT t.eq('X1g carol alone still curator (no regression)', $q$SELECT t.role('00000000-0000-0000-0000-00000000f001')$q$, 'curator');
COMMIT;

-- X2) 작성자 위조 불가: created_by / on_behalf_of / tenant_id 바인딩
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.err('X2a bot forges created_by=carol', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','forged','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000a1')$q$, '42501');
SELECT t.err('X2b bot forges on_behalf_of=carol', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','forged','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000c1')$q$, '42501');
SELECT t.err('X2c bot omits on_behalf_of', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','forged','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1')$q$, '42501');
SELECT t.err('X2d wrong tenant_id', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000f001','fact','t','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, '42501');
SELECT t.err('X2e honest bot proposal', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','honest','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, 'ok');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t.err('X2f human forges created_by=carol', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','forged','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000c1')$q$, '42501');
SELECT t.err('X2g human sets on_behalf_of', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','forged','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000c1')$q$, '42501');
SELECT t.err('X2h honest human proposal', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','honest','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000a1')$q$, 'ok');
COMMIT;

-- X3) app_rw 는 권한/주체 테이블을 쓸 수 없다 (스스로 curator 부여 불가)
BEGIN;
SELECT t.err('X3a app_rw self-grant via store_grant INSERT', $q$INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES ('00000000-0000-0000-0000-00000000f002','00000000-0000-0000-0000-0000000000a1','curator','00000000-0000-0000-0000-000000000001')$q$, '42501');
SELECT t.err('X3b app_rw store_grant UPDATE', $q$UPDATE store_grant SET role='curator'$q$, '42501');
SELECT t.err('X3c app_rw store_grant DELETE', $q$DELETE FROM store_grant$q$, '42501');
SELECT t.err('X3d app_rw principal UPDATE (re-activate)', $q$UPDATE principal SET active=true$q$, '42501');
SELECT t.err('X3e app_rw group_member INSERT', $q$INSERT INTO group_member VALUES ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000b1')$q$, '42501');
SELECT t.err('X3f app_rw memory_version DELETE', $q$DELETE FROM memory_version$q$, '42501');
SELECT t.err('X3g app_rw memory_version reason UPDATE (no column grant)', $q$UPDATE memory_version SET reason='x'$q$, '42501');
ROLLBACK;

-- X4) 버전/리뷰는 부모 memory 가 보일 때만 보인다
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.eq('X4a alice+bot hr memory_version rows', $q$SELECT count(*)::text FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000aa001'$q$, '0');
SELECT t.eq('X4b alice+bot hr review rows', $q$SELECT count(*)::text FROM review WHERE memory_id='00000000-0000-0000-0000-0000000aa001'$q$, '0');
SELECT t.eq('X4c alice+bot sees sales memory_version rows (own store visible)', $q$SELECT (count(*) >= 1)::text FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000bb001'$q$, 'true');
SELECT t.eq('X4d alice+bot sales review rows', $q$SELECT count(*)::text FROM review$q$, '1');
SELECT t.err('X4e insert version on hr memory', $q$INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot) VALUES ('00000000-0000-0000-0000-0000000aa001',2,'edit','00000000-0000-0000-0000-0000000000d1','{}')$q$, '42501');
SELECT t.err('X4f insert review on hr memory', $q$INSERT INTO review (memory_id, reviewer_id, verdict) VALUES ('00000000-0000-0000-0000-0000000aa001','00000000-0000-0000-0000-0000000000d1','comment')$q$, '42501');
SELECT t.err('X4g version actor forged as carol', $q$INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot) VALUES ('00000000-0000-0000-0000-0000000bb001',2,'edit','00000000-0000-0000-0000-0000000000c1','{}')$q$, '42501');
SELECT t.err('X4h insert version on sales memory (triggers only)', $q$INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot) VALUES ('00000000-0000-0000-0000-0000000bb001',2,'edit','00000000-0000-0000-0000-0000000000d1','{"title":"v2"}')$q$, '42501');
SELECT t.err('X4i bot comment review on sales memory (decision function only)', $q$INSERT INTO review (memory_id, reviewer_id, verdict) VALUES ('00000000-0000-0000-0000-0000000bb001','00000000-0000-0000-0000-0000000000d1','comment')$q$, '42501');
SELECT t.err('X4j bot approve review (needs curator)', $q$INSERT INTO review (memory_id, reviewer_id, verdict) VALUES ('00000000-0000-0000-0000-0000000bb001','00000000-0000-0000-0000-0000000000d1','approve')$q$, '42501');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000b1', NULL);
SELECT t.eq('X4k bob(hr) sees hr version', $q$SELECT (count(*) >= 1)::text FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000aa001'$q$, 'true');
SELECT t.eq('X4l bob(hr) sees no sales version/review', $q$SELECT (SELECT count(*) FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000bb001') + (SELECT count(*) FROM review WHERE memory_id='00000000-0000-0000-0000-0000000bb001')$q$, '0');
COMMIT;

-- X5) redact 는 curator 만, snapshot 외 컬럼(reason 포함) 변경 불가 / review 는 append-only
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t.err('X5a contributor alice redact (no UPDATE privilege)', $q$UPDATE memory_version SET snapshot=NULL WHERE memory_id='00000000-0000-0000-0000-0000000bb001' AND version=2$q$, '42501');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000c1', NULL);
SELECT t.err('X5b curator carol redact (only the delete trigger redacts)', $q$UPDATE memory_version SET snapshot=NULL WHERE memory_id='00000000-0000-0000-0000-0000000bb001' AND version=2$q$, '42501');
COMMIT;
RESET ROLE;
SELECT t.err('X5c redact + rewrite reason (owner)', $q$UPDATE memory_version SET snapshot=NULL, reason='rewritten' WHERE reason='original'$q$, 'P0001');
SELECT t.err('X5d redact + change at', $q$UPDATE memory_version SET snapshot=NULL, at=now()+interval '1 day' WHERE reason='original'$q$, 'P0001');
SELECT t.err('X5e un-redact (NULL -> value)', $q$UPDATE memory_version SET snapshot='{"x":1}' WHERE memory_id='00000000-0000-0000-0000-0000000bb001' AND version=2$q$, 'P0001');
SELECT t.err('X5f plain redact keeps reason', $q$UPDATE memory_version SET snapshot=NULL WHERE reason='original'$q$, 'ok');
SELECT t.eq('X5g reason intact after redact', $q$SELECT reason FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000aa001'$q$, 'original');
SELECT t.err('X5h review UPDATE blocked', $q$UPDATE review SET note='tamper'$q$, 'P0001');
SELECT t.err('X5i review DELETE blocked', $q$DELETE FROM review$q$, 'P0001');

-- X6) 비활성 principal/그룹은 아무 권한도 주지 않는다
UPDATE principal SET active=false WHERE external_id='carol';
SET ROLE app_rw;
BEGIN; SELECT t.ctx_soft('00000000-0000-0000-0000-0000000000c1', NULL);
SELECT t.eq('X6a deactivated carol role', $q$SELECT t.role('00000000-0000-0000-0000-00000000f001')$q$, 'NULL');
SELECT t.eq('X6b deactivated carol visible rows', $q$SELECT count(*)::text FROM memory$q$, '0');
COMMIT;
RESET ROLE;
UPDATE principal SET active=true WHERE external_id='carol';
UPDATE principal SET active=false WHERE external_id='sales' AND kind='group';
SET ROLE app_rw;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t.eq('X6c alice via deactivated group sales', $q$SELECT t.role('00000000-0000-0000-0000-00000000f001')$q$, 'NULL');
COMMIT;
RESET ROLE;
UPDATE principal SET active=true WHERE external_id='sales' AND kind='group';
UPDATE principal SET active=false WHERE external_id='sales-bot';
SET ROLE app_rw;
BEGIN; SELECT t.ctx_soft('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.eq('X6d alice + deactivated sales-bot', $q$SELECT t.role('00000000-0000-0000-0000-00000000f001')$q$, 'NULL');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t.eq('X6e alice alone unaffected', $q$SELECT t.role('00000000-0000-0000-0000-00000000f001')$q$, 'contributor');
COMMIT;
RESET ROLE;
UPDATE principal SET active=true WHERE external_id='sales-bot';
SET ROLE app_rw;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.eq('X6f reactivated -> contributor again', $q$SELECT t.role('00000000-0000-0000-0000-00000000f001')$q$, 'contributor');
COMMIT;
RESET ROLE;

-- ═══ P0 하드닝 (A1, A2, A5, A6, A10) ═════════════════════
-- 사전 데이터(소유자 권한): 같은 테넌트의 reader Dave, 비활성 Eve, 타 테넌트 Mallory, 성능용 store 와 사용자
INSERT INTO principal (id, tenant_id, kind, external_id, display_name) VALUES
 ('00000000-0000-0000-0000-0000000000f1','00000000-0000-0000-0000-000000000001','user','dave','Dave(영업 reader)'),
 ('00000000-0000-0000-0000-0000000000f2','00000000-0000-0000-0000-000000000001','user','eve','Eve(비활성)'),
 ('00000000-0000-0000-0000-0000000000f3','00000000-0000-0000-0000-000000000001','user','pat','Pat(성능 측정)'),
 ('00000000-0000-0000-0000-0000000000ff','00000000-0000-0000-0000-000000000002','user','mallory','Mallory(타 테넌트)');
UPDATE principal SET active = false WHERE external_id = 'eve';
INSERT INTO store (id, tenant_id, kind, slug, description) VALUES
 ('00000000-0000-0000-0000-00000000f003','00000000-0000-0000-0000-000000000001','team','perf','성능 측정용');
INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES
 ('00000000-0000-0000-0000-00000000f001','00000000-0000-0000-0000-0000000000f1','reader','00000000-0000-0000-0000-000000000001'),
 ('00000000-0000-0000-0000-00000000f003','00000000-0000-0000-0000-0000000000f3','reader','00000000-0000-0000-0000-000000000001'),
 ('00000000-0000-0000-0000-00000000f003','00000000-0000-0000-0000-0000000000d1','reader','00000000-0000-0000-0000-000000000001');

-- A10) 앱 역할은 LOGIN NOBYPASSRLS NOINHERIT, RLS 테이블은 소유자에게도 정책을 강제한다
SELECT t.eq('A10a app_rw login/bypassrls/inherit', $q$SELECT rolcanlogin || '/' || rolbypassrls || '/' || rolinherit FROM pg_roles WHERE rolname = 'app_rw'$q$, 'true/false/false');
SELECT t.eq('A10b tables with FORCE ROW LEVEL SECURITY', $q$SELECT string_agg(relname::text, ',' ORDER BY relname) FROM pg_class WHERE relforcerowsecurity$q$, 'deleted_hash,group_member,memory,memory_version,principal,review,store,store_grant');

SET ROLE app_rw;

-- A1) 컨텍스트는 begin_request 만 만들 수 있다 (N1, N2)
SELECT t.err('F3a inactive user Eve', $q$SELECT t.ctx('00000000-0000-0000-0000-0000000000f2', NULL)$q$, '28000');
SELECT t.err('F3b group id as user (N2a)', $q$SELECT t.ctx('00000000-0000-0000-0000-0000000000e1', NULL)$q$, '28000');
SELECT t.err('F3c agent id as user (N2b)', $q$SELECT t.ctx('00000000-0000-0000-0000-0000000000d1', NULL)$q$, '28000');
SELECT t.err('F3d user id as agent', $q$SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000c1')$q$, '28000');
SET app.user_id = '00000000-0000-0000-0000-0000000000c1'; SET app.agent_id = '';
SET app.tenant_id = '00000000-0000-0000-0000-000000000001'; SET app.ctx_xid = '1';
BEGIN;
SELECT t.eq('F4 session-level SET with forged ctx_xid sees rows (N1)', $q$SELECT count(*)::text FROM memory$q$, '0');
COMMIT;
RESET app.user_id; RESET app.agent_id; RESET app.tenant_id; RESET app.ctx_xid;

-- A2) 교집합: Bob(hr curator, sales reader) + sales-bot(contributor) = sales 의 reader 만
RESET ROLE;
INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES
 ('00000000-0000-0000-0000-00000000f001','00000000-0000-0000-0000-0000000000b1','reader','00000000-0000-0000-0000-000000000001');
SET ROLE app_rw;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.eq('F1 bob(hr curator, sales reader)+sales-bot roles', $q$SELECT coalesce(string_agg(s.slug || '=' || t.role(s.id), ',' ORDER BY s.slug), 'none') FROM store AS s WHERE t.role(s.id) IS NOT NULL$q$, 'sales=reader');
COMMIT;
RESET ROLE;
DELETE FROM store_grant WHERE principal_id = '00000000-0000-0000-0000-0000000000b1' AND store_id = '00000000-0000-0000-0000-00000000f001';
SET ROLE app_rw;

-- A6) proposed 는 대리된 사용자 본인에게만 보인다 (N7)
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
INSERT INTO memory (id, tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
VALUES ('00000000-0000-0000-0000-0000000cc002', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000f001', 'note', '민감한 초안', 'draft', '[]', '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.eq('F6a dave(reader)+same bot sees alice proposal (N7a)', $q$SELECT count(*)::text FROM memory WHERE id = '00000000-0000-0000-0000-0000000cc002'$q$, '0');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t.eq('F6b alice without agent sees own proposal (N7b)', $q$SELECT count(*)::text FROM memory WHERE id = '00000000-0000-0000-0000-0000000cc002'$q$, '1');
COMMIT;

-- A5) 테넌트 경계는 복합 FK (N8). 소유자 권한으로도 교차 테넌트 행은 만들 수 없다
RESET ROLE;
BEGIN;
SELECT t.err('N8a cross-tenant principal in grant', $q$INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES ('00000000-0000-0000-0000-00000000f002','00000000-0000-0000-0000-0000000000ff','curator','00000000-0000-0000-0000-000000000001')$q$, '23503');
ROLLBACK;
BEGIN;
SELECT t.err('N8b grant on a store of another tenant', $q$INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES ('00000000-0000-0000-0000-00000000f002','00000000-0000-0000-0000-0000000000ff','curator','00000000-0000-0000-0000-000000000002')$q$, '23503');
ROLLBACK;
BEGIN;
SELECT t.err('N8c memory whose tenant differs from its store', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by) VALUES ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000f001','note','t','x','[]','00000000-0000-0000-0000-0000000000a1')$q$, '23503');
ROLLBACK;

-- A2) 정책 비용 (N9): 10만 행 count(*) 가 요청 전체에서 한 번 평가되는 권한 집합으로 끝나야 한다
-- 한도는 로컬 200 ms, CI 1000 ms (러너 잡음 흡수). 값은 db-test.sh 가 -v f11_limit_ms 로 넘긴다
SELECT set_config('nunchi.f11_limit_ms', :'f11_limit_ms', false);
ALTER TABLE memory DISABLE TRIGGER USER;
INSERT INTO memory (tenant_id, store_id, kind, status, title, body, source_refs, created_by)
SELECT '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000f003', 'fact', 'active', 'perf ' || g, 'body ' || g, '[{"uri":"x"}]', '00000000-0000-0000-0000-0000000000c1'
FROM generate_series(1, 100000) AS g;
ALTER TABLE memory ENABLE TRIGGER USER;
ANALYZE memory;
SET ROLE app_rw;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000d1');
DO $$
DECLARE t0 timestamptz := clock_timestamp(); n bigint; ms numeric; lim numeric := current_setting('nunchi.f11_limit_ms')::numeric;
BEGIN
  SELECT count(*) INTO n FROM memory;
  ms := round(extract(epoch FROM clock_timestamp() - t0) * 1000, 1);
  IF n = 100000 AND ms <= lim THEN RAISE NOTICE 'F11 count(*) over 100000 rows as app_rw took % ms, limit % ms (ok)', ms, lim;
  ELSE RAISE NOTICE 'F11 FAIL: count % in % ms, limit % ms', n, ms, lim; END IF;
END $$;
COMMIT;
RESET ROLE;

-- ═══ P0 하드닝 (A3, A4, A7, A8, A9): 쓰기 경로는 트리거와 함수뿐 ═════════
-- 사전 데이터(소유자 권한): hr 의 삭제 해시, 외부 출처 active 메모리
INSERT INTO deleted_hash (store_id, content_hash, reason) VALUES ('00000000-0000-0000-0000-00000000f002', 'seed', 'seed');
INSERT INTO memory (id, tenant_id, store_id, kind, status, title, body, source_refs, origin, created_by) VALUES
 ('00000000-0000-0000-0000-0000000ee001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001',
  'fact','active','외부 문서','외부 본문','[{"uri":"https://ext/1"}]','external','00000000-0000-0000-0000-0000000000c1');
INSERT INTO memory (id, tenant_id, store_id, kind, status, title, body, source_refs, created_by) VALUES
 ('00000000-0000-0000-0000-0000000ff001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f003',
  'fact','active','성능 store 메모리','다른 store 본문','[{"uri":"https://perf/1"}]','00000000-0000-0000-0000-0000000000c1');
INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES
 ('00000000-0000-0000-0000-00000000f003','00000000-0000-0000-0000-0000000000a1','reader','00000000-0000-0000-0000-000000000001');

SET ROLE app_rw;

-- A7) 서버가 정하는 값: 상태, 내용 해시. 클라이언트가 보낸 status/content_hash 는 무시된다
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.eq('F5 client status=active and content_hash are replaced', $q$WITH i AS (
  INSERT INTO memory (id, tenant_id, store_id, kind, status, title, body, source_refs, created_by, on_behalf_of, content_hash)
  VALUES ('00000000-0000-0000-0000-0000000cc001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','active','F5','본문 F5','[{"uri":"https://crm/1"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1','client-hash')
  RETURNING status, content_hash, body) SELECT status || '/' || (content_hash ~ '^[0-9a-f]{64}$') FROM i$q$, 'proposed/true');
COMMIT;

-- 존재 오라클 차단: 못 읽는 행과 없는 행은 같은 오류 (N3)
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.err('F7a supersedes an hr memory (exists, unreadable)', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of, supersedes_id)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000aa001')$q$, '23503');
SELECT t.err('F7b supersedes a random uuid (absent)', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of, supersedes_id)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000dead')$q$, '23503');
SELECT t.err('F7h supersedes a readable memory of another store', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of, supersedes_id)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000ff001')$q$, '23503');
SELECT t.err('F7c memory:// citation of an hr memory', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"memory://00000000-0000-0000-0000-0000000aa001"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, '23503');
SELECT t.err('F7d memory:// citation of a random uuid', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"memory://00000000-0000-0000-0000-00000000dead"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, '23503');
SELECT t.err('F7e memory:// citation that is not a uuid', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"memory://not-a-uuid"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, '23503');
SELECT t.eq('F7f citing an external memory makes the derived memory external (N11)', $q$WITH i AS (
  INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"memory://00000000-0000-0000-0000-0000000ee001"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')
  RETURNING origin) SELECT origin::text FROM i$q$, 'external');
SELECT t.eq('F7g citing an internal memory keeps it internal', $q$WITH i AS (
  INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','y','[{"uri":"memory://00000000-0000-0000-0000-0000000bb001"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')
  RETURNING origin) SELECT origin::text FROM i$q$, 'internal');
ROLLBACK;

-- A3, A4) 감사·삭제 해시·리뷰는 앱이 직접 쓰지 못한다 (N4, N6)
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.err('F8a deleted_hash INSERT into hr (N4a)', $q$INSERT INTO deleted_hash (store_id, content_hash, reason) VALUES ('00000000-0000-0000-0000-00000000f002','h1','censor')$q$, '42501');
SELECT t.err('F8b bot inserts an approve version as itself (N6a)', $q$INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot) VALUES ('00000000-0000-0000-0000-0000000bb001', 9, 'approve', '00000000-0000-0000-0000-0000000000d1', '{"forged":true}')$q$, '42501');
SELECT t.err('F8c memory_version UPDATE', $q$UPDATE memory_version SET snapshot = NULL$q$, '42501');
SELECT t.err('F8d bot inserts an approve review (N6b)', $q$INSERT INTO review (memory_id, reviewer_id, verdict) VALUES ('00000000-0000-0000-0000-0000000bb001','00000000-0000-0000-0000-0000000000d1','approve')$q$, '42501');
SELECT t.eq('N4b alice+bot reads deleted_hash rows', $q$SELECT count(*)::text FROM deleted_hash$q$, '0');
ROLLBACK;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t.err('N6c contributor inserts an approve version in her own name', $q$INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot) VALUES ('00000000-0000-0000-0000-0000000bb001', 9, 'approve', '00000000-0000-0000-0000-0000000000a1', '{"forged":true}')$q$, '42501');
ROLLBACK;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000b1', NULL);
SELECT t.eq('N4c hr curator bob reads hr deleted_hash rows', $q$SELECT count(*)::text FROM deleted_hash$q$, '1');
ROLLBACK;

-- A8, A9) 승인 → origin 세탁 → 작성자 변경 → 삭제 → 소생 → 체인 검증
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000c1', NULL); SET LOCAL app.reason = 'looks good';
UPDATE memory SET status = 'active' WHERE id = '00000000-0000-0000-0000-0000000cc001' AND version = 1;
SELECT t.eq('F9a approved: version / versions logged', $q$SELECT version || '/' || (SELECT count(*) FROM memory_version WHERE memory_id = '00000000-0000-0000-0000-0000000cc001') FROM memory WHERE id = '00000000-0000-0000-0000-0000000cc001'$q$, '2/2');
UPDATE memory SET origin = 'external' WHERE id = '00000000-0000-0000-0000-0000000cc001';
SELECT t.err('F9b launder origin external -> internal (N5a)', $q$UPDATE memory SET origin = 'internal' WHERE id = '00000000-0000-0000-0000-0000000cc001'$q$, 'P0001');
SELECT t.err('F9c rewrite created_by (N5a)', $q$UPDATE memory SET created_by = '00000000-0000-0000-0000-0000000000a1' WHERE id = '00000000-0000-0000-0000-0000000cc001'$q$, 'P0001');
SET LOCAL app.reason = 'PII erasure request #42';
UPDATE memory SET status = 'deleted' WHERE id = '00000000-0000-0000-0000-0000000cc001';
SELECT t.eq('F9d deleted: body null / snapshots all null / deleted_hash rows', $q$SELECT (body IS NULL) || '/' || (SELECT bool_and(snapshot IS NULL) FROM memory_version WHERE memory_id = '00000000-0000-0000-0000-0000000cc001') || '/' || (SELECT count(*) FROM deleted_hash WHERE store_id = '00000000-0000-0000-0000-00000000f001') FROM memory WHERE id = '00000000-0000-0000-0000-0000000cc001'$q$, 'true/true/1');
SELECT t.err('F9e resurrect deleted -> active with a new body (N5b)', $q$UPDATE memory SET status = 'active', body = '되살림' WHERE id = '00000000-0000-0000-0000-0000000cc001'$q$, 'P0001');
SELECT t.eq('F9f chain valid', $q$SELECT app_sec.verify_chain('00000000-0000-0000-0000-0000000cc001')::text$q$, 'true');
SELECT t.eq('F9g ops in order', $q$SELECT string_agg(op::text, ',' ORDER BY id) FROM memory_version WHERE memory_id = '00000000-0000-0000-0000-0000000cc001'$q$, 'propose,approve,edit,delete');
COMMIT;

-- A4) 삭제된 본문의 공백만 바꾼 재제안은 막힌다
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.err('F10 re-propose of deleted content with different whitespace', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','again','본문  F5','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, '23505');
ROLLBACK;

-- A4) 공백 변형 우회: NBSP, 전각 공백, 폭 없는 문자도 삭제된 내용과 같은 해시가 된다 (P4)
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.err('P4a re-propose of deleted content with NBSP', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','again',E'본문\u00a0F5','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, '23505');
SELECT t.err('P4b re-propose with an ideographic space', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','again',E'본문\u3000F5','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, '23505');
SELECT t.err('P4c re-propose with a zero-width space', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','again',E'본문 F\u200b5','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, '23505');
ROLLBACK;

-- N6, N4) app_rw 는 내부 함수를 직접 부를 수 없다 (P1, P2)
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t.err('P1 contributor calls write_version to forge an approve row', $q$SELECT app_sec.write_version(m, 'approve', '00000000-0000-0000-0000-0000000000c1', 'forged') FROM memory AS m WHERE m.id = '00000000-0000-0000-0000-0000000bb001'$q$, '42501');
SELECT t.err('P2a contributor calls is_deleted_content (existence oracle)', $q$SELECT app_sec.is_deleted_content('00000000-0000-0000-0000-00000000f002', 'seed')$q$, '42501');
SELECT t.err('P2b contributor calls content_hmac', $q$SELECT app_sec.content_hmac('x')$q$, '42501');
SELECT t.err('P2c contributor calls the hash trigger function', $q$SELECT app_sec.memory_set_hash()$q$, '42501');
ROLLBACK;

-- 허용 목록: app_rw 가 실행할 수 있는 함수(확장 소속, 시스템 스키마, 테스트 스키마 t 제외)는 정확히 이 목록이다.
-- 새 함수는 의식적으로 여기에 추가한다 (P3). 이름이 아니라 스키마로 제외하므로 public.t_eq 같은 운영 함수도 잡힌다 (P3b)
RESET ROLE;
CREATE FUNCTION t.exec_list() RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(n.nspname || '.' || p.proname, ',' ORDER BY n.nspname, p.proname)
  FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname NOT IN ('t', 'information_schema') AND n.nspname NOT LIKE 'pg\_%'
    AND has_function_privilege('app_rw', p.oid, 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM pg_depend AS d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
$$;
SET ROLE app_rw;
SELECT t.eq('P3 functions app_rw can execute equal the allowlist', 'SELECT t.exec_list()',
  'app_sec.begin_request,app_sec.ctx_agent,app_sec.ctx_tenant,app_sec.ctx_user,app_sec.my_store_roles,app_sec.my_stores,app_sec.resolve_principal,app_sec.search,app_sec.verify_chain,public.principal_closure');
RESET ROLE;
BEGIN;
CREATE FUNCTION public.t_eq() RETURNS void LANGUAGE sql AS $$ SELECT $$;
SELECT t.eq('P3b a production function named public.t_eq is listed', $q$SELECT (t.exec_list() LIKE '%public.t_eq%')::text$q$, 'true');
ROLLBACK;
SET ROLE app_rw;

-- A9) 체인은 변조를 드러낸다: 소유자가 트리거를 끄고 actor 를 바꾸면 verify_chain 이 false
RESET ROLE;
BEGIN;
ALTER TABLE memory_version DISABLE TRIGGER memory_version_append_only;
UPDATE memory_version SET actor_id = '00000000-0000-0000-0000-0000000000b1' WHERE memory_id = '00000000-0000-0000-0000-0000000cc001' AND op = 'approve';
SELECT t.eq('F9h tampered actor breaks the chain', $q$SELECT app_sec.verify_chain('00000000-0000-0000-0000-0000000cc001')::text$q$, 'false');
ROLLBACK;
-- A9) reason 도 행 해시에 들어간다 (P5)
BEGIN;
ALTER TABLE memory_version DISABLE TRIGGER memory_version_append_only;
UPDATE memory_version SET reason = 'rewritten' WHERE memory_id = '00000000-0000-0000-0000-0000000cc001' AND op = 'approve';
SELECT t.eq('P5 tampered reason breaks the chain', $q$SELECT app_sec.verify_chain('00000000-0000-0000-0000-0000000cc001')::text$q$, 'false');
ROLLBACK;
-- ═══ P0 하드닝 (A11): 검색 함수 ═════════════════════════════
-- 사전 데이터(소유자 권한): 같은 단어를 가진 행을 store, 상태, 작성자별로 흩어 놓는다
INSERT INTO principal (id, tenant_id, kind, external_id, display_name) VALUES
 ('00000000-0000-0000-0000-0000000000f4','00000000-0000-0000-0000-000000000001','user','fay','Fay(영업 contributor)');
INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES
 ('00000000-0000-0000-0000-00000000f001','00000000-0000-0000-0000-0000000000f4','contributor','00000000-0000-0000-0000-000000000001');
INSERT INTO memory (id, tenant_id, store_id, kind, status, title, body, source_refs, created_by, on_behalf_of) VALUES
 ('00000000-0000-0000-0000-0000000e0001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f002','note','active','zebra hr active','x','[]','00000000-0000-0000-0000-0000000000b1',NULL),
 ('00000000-0000-0000-0000-0000000e0002','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','note','active','zebra sales active','x','[]','00000000-0000-0000-0000-0000000000c1',NULL),
 ('00000000-0000-0000-0000-0000000e0003','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','note','proposed','zebra sales proposed by bot for alice','x','[]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1'),
 ('00000000-0000-0000-0000-0000000e0004','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','note','proposed','zebra sales proposed by fay','x','[]','00000000-0000-0000-0000-0000000000f4',NULL),
 ('00000000-0000-0000-0000-0000000e0005','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','note','rejected','zebra sales rejected','x','[]','00000000-0000-0000-0000-0000000000f4',NULL),
 ('00000000-0000-0000-0000-0000000e0006','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','note','superseded','zebra sales superseded','x','[]','00000000-0000-0000-0000-0000000000c1',NULL);

SET ROLE app_rw;

-- 정책과 같은 가시성: 호출자가 읽을 수 있는 행만, 기본은 active (N10)
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.eq('N10a alice+bot searches zebra: default status is active, hr hidden', $q$SELECT string_agg(title, ',' ORDER BY title) FROM app_sec.search('zebra')$q$, 'zebra sales active');
SELECT t.eq('N10b alice+bot searches an hr-only word', $q$SELECT count(*)::text FROM app_sec.search('연봉', NULL, enum_range(NULL::memory_status))$q$, '0');
SELECT t.eq('N10c alice+bot asks for the hr store by id', $q$SELECT count(*)::text FROM app_sec.search('zebra', ARRAY['00000000-0000-0000-0000-00000000f002']::uuid[], enum_range(NULL::memory_status))$q$, '0');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t.eq('N10d alice alone, all statuses: active, own proposal, superseded', $q$SELECT string_agg(title, ',' ORDER BY title) FROM app_sec.search('zebra', NULL, enum_range(NULL::memory_status))$q$, 'zebra sales active,zebra sales proposed by bot for alice,zebra sales superseded');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000c1', NULL);
SELECT t.eq('N10e curator carol, all statuses', $q$SELECT count(*)::text FROM app_sec.search('zebra', NULL, enum_range(NULL::memory_status))$q$, '5');
SELECT t.eq('N10f curator carol asks only for proposed', $q$SELECT count(*)::text FROM app_sec.search('zebra', NULL, ARRAY['proposed']::memory_status[])$q$, '2');
SELECT t.eq('N10g curator carol narrows to the hr store', $q$SELECT count(*)::text FROM app_sec.search('zebra', ARRAY['00000000-0000-0000-0000-00000000f002']::uuid[], enum_range(NULL::memory_status))$q$, '0');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000b1', NULL);
SELECT t.eq('N10h hr curator bob finds the hr row', $q$SELECT string_agg(title, ',') FROM app_sec.search('zebra', NULL, enum_range(NULL::memory_status))$q$, 'zebra hr active');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000f1', NULL);
SELECT t.eq('N10i reader dave, all statuses: active and superseded only', $q$SELECT count(*)::text FROM app_sec.search('zebra', NULL, enum_range(NULL::memory_status))$q$, '2');
COMMIT;
BEGIN;
SELECT t.eq('N10j no request context finds nothing', $q$SELECT count(*)::text FROM app_sec.search('zebra', NULL, enum_range(NULL::memory_status))$q$, '0');
COMMIT;

-- 함수가 보여 주는 행 = 같은 호출자가 memory 를 직접 읽어 보이는 행 (정책과 함수의 가시성 규칙이 어긋나지 않는다)
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.eq('N10k parity alice+bot', $q$SELECT ((SELECT string_agg(id::text, ',' ORDER BY id) FROM app_sec.search('zebra', NULL, enum_range(NULL::memory_status))) = (SELECT string_agg(id::text, ',' ORDER BY id) FROM memory WHERE search_tsv @@ websearch_to_tsquery('simple', 'zebra')))::text$q$, 'true');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000c1', NULL);
SELECT t.eq('N10l parity carol', $q$SELECT ((SELECT string_agg(id::text, ',' ORDER BY id) FROM app_sec.search('zebra', NULL, enum_range(NULL::memory_status))) = (SELECT string_agg(id::text, ',' ORDER BY id) FROM memory WHERE search_tsv @@ websearch_to_tsquery('simple', 'zebra')))::text$q$, 'true');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000f1', NULL);
SELECT t.eq('N10m parity dave', $q$SELECT ((SELECT string_agg(id::text, ',' ORDER BY id) FROM app_sec.search('zebra', NULL, enum_range(NULL::memory_status))) = (SELECT string_agg(id::text, ',' ORDER BY id) FROM memory WHERE search_tsv @@ websearch_to_tsquery('simple', 'zebra')))::text$q$, 'true');

-- N13) 검색 입력 상한: 1000자, tsquery 노드 64개. 넘으면 22023, 한계 바로 아래는 정상 실행 (zebra 32개 = 노드 63개, 33개 = 65개)
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t.err('N13a search with 1001 characters', $q$SELECT * FROM app_sec.search(repeat('a', 1001))$q$, '22023');
SELECT t.err('N13b search with 65 terms', $q$SELECT * FROM app_sec.search(repeat('a ', 65))$q$, '22023');
SELECT t.err('N13c search with 3000 leading minus signs', $q$SELECT * FROM app_sec.search(repeat('-', 3000))$q$, '22023');
SELECT t.err('N13d search with 32 terms (63 nodes)', $q$SELECT * FROM app_sec.search(repeat('zebra ', 32))$q$, 'ok');
SELECT t.err('N13f search with 999 characters of x,x,x (999 nodes)', $q$SELECT * FROM app_sec.search(repeat('x,', 499) || 'x')$q$, '22023');
SELECT t.err('N13g search with 65 NBSP-separated terms', $q$SELECT * FROM app_sec.search(repeat('a' || chr(160), 65))$q$, '22023');
SELECT t.err('N13h search with 33 terms (65 nodes)', $q$SELECT * FROM app_sec.search(repeat('zebra ', 33))$q$, '22023');
SELECT t.err('N13e search with 1000 characters', $q$SELECT * FROM app_sec.search(repeat('a', 1000))$q$, 'ok');
ROLLBACK;
COMMIT;
RESET ROLE;

-- ═══ search_path·임시 객체 하이재킹 (S1–S5) ═══════════════
-- S1(모든 함수의 search_path 고정 lint)은 scripts/db-test.sh 가 lint_search_path.sql 로 실행한다.
-- S4) app_rw 는 임시 테이블을 만들 수 없다 (TEMPORARY 를 PUBLIC 에서 회수)
SET ROLE app_rw;
SELECT t.err('S4 app_rw CREATE TEMP TABLE', $q$CREATE TEMP TABLE s4_probe (x int)$q$, '42501');
RESET ROLE;

-- 아래 S2/S3 는 방어의 두 번째 겹을 본다: TEMPORARY 를 일부러 되돌려 줘도 함수의 search_path 고정만으로 막혀야 한다
DO $$ BEGIN EXECUTE format('GRANT TEMPORARY ON DATABASE %I TO app_rw', current_database()); END $$;
SET ROLE app_rw;

-- S2a) 임시 store_grant 로 Alice 에게 인사 store curator 를 만들어 준다 → 진짜 role(없음)
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', NULL);
CREATE TEMP TABLE store_grant (LIKE public.store_grant) ON COMMIT DROP;
INSERT INTO pg_temp.store_grant (store_id, principal_id, role, tenant_id) VALUES
 ('00000000-0000-0000-0000-00000000f002','00000000-0000-0000-0000-0000000000a1','curator','00000000-0000-0000-0000-000000000001');
SELECT t.eq('S2a temp store_grant: alice role on hr', $q$SELECT t.role('00000000-0000-0000-0000-00000000f002')$q$, 'NULL');
SELECT t.eq('S2e temp store_grant: alice role on sales is still her real one', $q$SELECT t.role('00000000-0000-0000-0000-00000000f001')$q$, 'contributor');
COMMIT;

-- S2b) 임시 principal/store_grant 에만 있는 사용자는 begin_request 를 통과하지 못한다
BEGIN;
CREATE TEMP TABLE principal (id uuid, tenant_id uuid, kind principal_kind, external_id text, display_name text, active boolean) ON COMMIT DROP;
INSERT INTO pg_temp.principal (id, tenant_id, kind, external_id, display_name, active) VALUES
 ('00000000-0000-0000-0000-0000000000a9','00000000-0000-0000-0000-000000000001','user','forged','Forged',true);
SELECT t.err('S2b begin_request for a user that exists only in a temp principal', $q$SELECT t.ctx('00000000-0000-0000-0000-0000000000a9', NULL)$q$, '28000');
COMMIT;

-- S2c) 임시 group_member 로 Dave(sales reader)를 sales 그룹에 넣는다 → 여전히 reader
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000f1', NULL);
CREATE TEMP TABLE group_member (LIKE public.group_member) ON COMMIT DROP;
INSERT INTO pg_temp.group_member (group_id, member_id) VALUES
 ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000f1');
SELECT t.eq('S2c temp group_member: dave role on sales', $q$SELECT t.role('00000000-0000-0000-0000-00000000f001')$q$, 'reader');
COMMIT;
RESET ROLE;

-- S2d) 비활성화된 sales 그룹을 임시 principal 로 되살려도 Alice 는 role 을 얻지 못한다
UPDATE principal SET active = false WHERE external_id = 'sales' AND kind = 'group';
SET ROLE app_rw;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', NULL);
CREATE TEMP TABLE principal AS SELECT id, tenant_id, kind, 'hidden'::text AS external_id, display_name, active FROM public.principal;
UPDATE pg_temp.principal SET active = true;
SELECT t.eq('S2d temp principal revives deactivated group: alice role on sales', $q$SELECT t.role('00000000-0000-0000-0000-00000000f001')$q$, 'NULL');
COMMIT;
DROP TABLE pg_temp.principal;
RESET ROLE;
UPDATE principal SET active = true WHERE external_id = 'sales' AND kind = 'group';

-- S3) pg_temp 의 함수로 ctx_user / current_setting 을 가리려 해도 효과가 없다 (함수 조회는 pg_temp 를 보지 않는다)
SET ROLE app_rw;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', NULL);
CREATE FUNCTION pg_temp.ctx_user() RETURNS uuid LANGUAGE sql AS $$ SELECT '00000000-0000-0000-0000-0000000000b1'::uuid $$;
CREATE FUNCTION pg_temp.current_setting(text, boolean) RETURNS text LANGUAGE sql AS $$ SELECT '00000000-0000-0000-0000-0000000000b1'::text $$;
SELECT t.eq('S3 temp function shadowing: alice role on hr', $q$SELECT t.role('00000000-0000-0000-0000-00000000f002')$q$, 'NULL');
COMMIT;
RESET ROLE;
DO $$ BEGIN EXECUTE format('REVOKE TEMPORARY ON DATABASE %I FROM app_rw', current_database()); END $$;

-- S5) closure 의 active 검사는 begin_request 를 거치지 않고 직접 확인한다 (t.closure = app_sec.closure, v1.0 은 principal_closure)
CREATE FUNCTION t.closure(p uuid) RETURNS SETOF uuid LANGUAGE plpgsql AS $$
BEGIN
  IF to_regprocedure('app_sec.closure(uuid)') IS NOT NULL THEN RETURN QUERY SELECT app_sec.closure(p);
  ELSE RETURN QUERY SELECT principal_closure(p); END IF;
END $$;
SELECT t.eq('S5a closure of alice = alice + sales', $q$SELECT count(*)::text FROM t.closure('00000000-0000-0000-0000-0000000000a1')$q$, '2');
UPDATE principal SET active = false WHERE external_id = 'sales' AND kind = 'group';
SELECT t.eq('S5b closure of alice with sales deactivated', $q$SELECT count(*)::text FROM t.closure('00000000-0000-0000-0000-0000000000a1')$q$, '1');
UPDATE principal SET active = true WHERE external_id = 'sales' AND kind = 'group';
UPDATE principal SET active = false WHERE external_id = 'alice';
SELECT t.eq('S5c closure of deactivated alice (member of an active group)', $q$SELECT count(*)::text FROM t.closure('00000000-0000-0000-0000-0000000000a1')$q$, '0');
UPDATE principal SET active = true WHERE external_id = 'alice';
SELECT t.eq('S5d closure of reactivated alice', $q$SELECT count(*)::text FROM t.closure('00000000-0000-0000-0000-0000000000a1')$q$, '2');

-- ═══ 주체/권한 테이블 RLS (N11) ═══════════════
-- 사전 데이터(소유자 권한): 다른 테넌트의 사용자, store, grant
INSERT INTO principal (id, tenant_id, kind, external_id, display_name) VALUES
 ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-000000000002','user','zed','Zed(타 테넌트)');
INSERT INTO store (id, tenant_id, kind, slug, description) VALUES ('00000000-0000-0000-0000-00000000f009','00000000-0000-0000-0000-000000000002','team','zed','타 테넌트 지식');
INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES ('00000000-0000-0000-0000-00000000f009','00000000-0000-0000-0000-000000000091','curator','00000000-0000-0000-0000-000000000002');
INSERT INTO principal (id, tenant_id, kind, external_id, display_name, active) VALUES
 ('00000000-0000-0000-0000-0000000000a8','00000000-0000-0000-0000-000000000001','user','ghost','Ghost(비활성)', false);
SET ROLE app_rw;
SELECT t.err('N14a app_rw selects principal.external_id', $q$SELECT external_id FROM principal$q$, '42501');
SELECT t.err('N14b app_rw selects * from principal', $q$SELECT * FROM principal$q$, '42501');
SELECT t.eq('N14c app_rw selects the other principal columns', $q$SELECT count(*)::text FROM (SELECT id, tenant_id, kind, display_name, active FROM principal LIMIT 0) AS s$q$, '0');
SELECT t.eq('N15a resolve_principal: active user', $q$SELECT app_sec.resolve_principal('00000000-0000-0000-0000-000000000001', 'user', 'alice')::text$q$, '00000000-0000-0000-0000-0000000000a1');
SELECT t.eq('N15b resolve_principal: inactive user', $q$SELECT coalesce(app_sec.resolve_principal('00000000-0000-0000-0000-000000000001', 'user', 'ghost')::text, 'NULL')$q$, 'NULL');
SELECT t.eq('N15c resolve_principal: wrong kind', $q$SELECT coalesce(app_sec.resolve_principal('00000000-0000-0000-0000-000000000001', 'agent', 'alice')::text, 'NULL')$q$, 'NULL');
SELECT t.eq('N15d resolve_principal: other tenant', $q$SELECT coalesce(app_sec.resolve_principal('00000000-0000-0000-0000-000000000002', 'user', 'alice')::text, 'NULL')$q$, 'NULL');
SELECT t.eq('N15e resolve_principal: agent kind in the right tenant', $q$SELECT app_sec.resolve_principal('00000000-0000-0000-0000-000000000001', 'agent', 'sales-bot')::text$q$, '00000000-0000-0000-0000-0000000000d1');
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t.eq('N11a alice sees principals of another tenant', $q$SELECT count(*)::text FROM principal WHERE tenant_id = '00000000-0000-0000-0000-000000000002'$q$, '0');
SELECT t.eq('N11b alice still sees same-tenant principals (display names)', $q$SELECT count(*)::text FROM principal WHERE id = '00000000-0000-0000-0000-0000000000b1'$q$, '1');
SELECT t.eq('N11c alice sees carol group membership', $q$SELECT count(*)::text FROM group_member WHERE member_id = '00000000-0000-0000-0000-0000000000c1'$q$, '0');
SELECT t.eq('N11d alice sees her own group membership', $q$SELECT count(*)::text FROM group_member WHERE member_id = '00000000-0000-0000-0000-0000000000a1'$q$, '1');
SELECT t.eq('N11e alice sees the hr store', $q$SELECT count(*)::text FROM store WHERE id = '00000000-0000-0000-0000-00000000f002'$q$, '0');
SELECT t.eq('N11f alice sees a store of another tenant', $q$SELECT count(*)::text FROM store WHERE tenant_id = '00000000-0000-0000-0000-000000000002'$q$, '0');
SELECT t.eq('N11g alice sees her own store', $q$SELECT count(*)::text FROM store WHERE id = '00000000-0000-0000-0000-00000000f001'$q$, '1');
SELECT t.eq('N11h alice sees grants of the hr store', $q$SELECT count(*)::text FROM store_grant WHERE store_id = '00000000-0000-0000-0000-00000000f002'$q$, '0');
SELECT t.eq('N11i alice sees carol curator grant (not a curator herself)', $q$SELECT count(*)::text FROM store_grant WHERE principal_id = '00000000-0000-0000-0000-0000000000c1'$q$, '0');
SELECT t.eq('N11j alice sees the grant her group holds', $q$SELECT count(*)::text FROM store_grant WHERE principal_id = '00000000-0000-0000-0000-0000000000e1'$q$, '1');
SELECT t.eq('N11k alice sees grants of another tenant', $q$SELECT count(*)::text FROM store_grant WHERE tenant_id = '00000000-0000-0000-0000-000000000002'$q$, '0');
SELECT t.eq('N11l principal_closure(carol) called by alice', $q$SELECT count(*)::text FROM principal_closure('00000000-0000-0000-0000-0000000000c1')$q$, '0');
SELECT t.eq('N11m principal_closure(alice) called by alice', $q$SELECT count(*)::text FROM principal_closure('00000000-0000-0000-0000-0000000000a1')$q$, '2');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000c1', NULL);
SELECT t.eq('N11n curator carol sees the bot grant on her store', $q$SELECT count(*)::text FROM store_grant WHERE store_id = '00000000-0000-0000-0000-00000000f001' AND principal_id = '00000000-0000-0000-0000-0000000000d1'$q$, '1');
SELECT t.eq('N11o curator carol sees the members of the sales group', $q$SELECT count(*)::text FROM group_member WHERE group_id = '00000000-0000-0000-0000-0000000000e1'$q$, '2');
SELECT t.eq('N11p curator carol sees grants of the hr store', $q$SELECT count(*)::text FROM store_grant WHERE store_id = '00000000-0000-0000-0000-00000000f002'$q$, '0');
COMMIT;
BEGIN; SELECT t.ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t.eq('N11q alice with the bot: closure(bot) is the bot alone', $q$SELECT count(*)::text FROM principal_closure('00000000-0000-0000-0000-0000000000d1')$q$, '1');
COMMIT;
BEGIN; SELECT t.ctx(NULL, NULL);
SELECT t.eq('N11r no context: principal rows', $q$SELECT count(*)::text FROM principal$q$, '0');
SELECT t.eq('N11s no context: store_grant rows', $q$SELECT count(*)::text FROM store_grant$q$, '0');
COMMIT;

RESET ROLE;

ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
DROP SCHEMA t CASCADE;
