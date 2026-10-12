-- RLS 동작 검증용 스모크 테스트
\set ON_ERROR_STOP on
-- app_rw 역할과 최소 권한 GRANT 는 schema.sql 에 있다

-- 헬퍼: t_eq = 쿼리 결과(text) 비교, t_err = 실행 시 SQLSTATE 비교('ok' = 성공). 호출자 권한으로 실행됨.
-- t_ctx = 요청 컨텍스트 시작. 새 스키마에서는 app_sec.begin_request, v1.0 취약 스키마에서는 옛 방식(트랜잭션 로컬
--         app.user_id/app.agent_id)으로 같은 사용자를 흉내 내서 mutation gate 가 같은 테스트를 양쪽에 돌릴 수 있게 한다.
--         user 가 NULL 이면 컨텍스트 없음(빈 값)이다.
-- t_role = 현재 컨텍스트의 한 store 에 대한 실효 role (my_store_roles 또는 v1.0 effective_role)
CREATE FUNCTION t_eq(label text, q text, expected text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  EXECUTE q INTO r;
  IF coalesce(r, 'NULL') = expected THEN RAISE NOTICE '% = % (ok)', label, expected;
  ELSE RAISE NOTICE '% FAIL: expected %, got %', label, expected, coalesce(r, 'NULL'); END IF;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE '% FAIL: error % %', label, SQLSTATE, SQLERRM;
END $$;
CREATE FUNCTION t_err(label text, q text, expected text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE s text := 'ok';
BEGIN
  BEGIN EXECUTE q; EXCEPTION WHEN OTHERS THEN s := SQLSTATE; END;
  IF s = expected THEN RAISE NOTICE '% -> % (ok)', label, expected;
  ELSE RAISE NOTICE '% FAIL: expected %, got %', label, expected, s; END IF;
END $$;

CREATE FUNCTION t_ctx(u uuid, a uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF u IS NOT NULL AND to_regprocedure('app_sec.begin_request(uuid,uuid)') IS NOT NULL THEN
    PERFORM app_sec.begin_request(u, a);
  ELSE
    PERFORM set_config('app.user_id', coalesce(u::text, ''), true);
    PERFORM set_config('app.agent_id', coalesce(a::text, ''), true);
  END IF;
END $$;
-- t_ctx_soft = t_ctx, but a refused begin_request (inactive principal) leaves no context instead of aborting the script.
CREATE FUNCTION t_ctx_soft(u uuid, a uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM t_ctx(u, a);
EXCEPTION WHEN invalid_authorization_specification THEN
  NULL;
END $$;
CREATE FUNCTION t_role(s uuid) RETURNS text LANGUAGE plpgsql AS $$
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
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT 'T1 alice sees hr rows = ' || count(*) FROM memory; COMMIT;

-- 2) 영업봇이 Alice 대리로 제안 (proposed) → 성공
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
INSERT INTO memory (id, tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
VALUES ('00000000-0000-0000-0000-0000000bb001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001',
 'fact','A사 갱신 담당자 변경','김OO → 이OO','[{"uri":"https://crm/acct/A"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1');
SELECT 'T2 propose ok'; COMMIT;

-- 3) 영업봇이 active 로 바로 쓰기 시도 → 성공하되 트리거가 proposed 로 덮어쓴다
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t_eq('T3 bot insert with status=active is stored as', $q$WITH i AS (
  INSERT INTO memory (tenant_id, store_id, kind, status, title, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','active','우회','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')
  RETURNING status) SELECT status::text FROM i$q$, 'proposed');
COMMIT;

-- 4) Alice(contributor)는 승인 불가 → 0 rows updated
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', NULL);
WITH u AS (UPDATE memory SET status='active' WHERE id='00000000-0000-0000-0000-0000000bb001' RETURNING 1)
SELECT 'T4 alice approve rows = ' || count(*) FROM u; COMMIT;

-- 5) Carol(curator) 승인 → 1 row
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000c1', NULL);
WITH u AS (UPDATE memory SET status='active' WHERE id='00000000-0000-0000-0000-0000000bb001' RETURNING 1)
SELECT 'T5 carol approve rows = ' || count(*) FROM u; COMMIT;

-- 6) Carol이 영업봇과 함께여도 봇 권한이 contributor라 승인 불가 (교집합)
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000d1');
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
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000d1');
SELECT t_eq('X1a bob(hr)+sales-bot role on sales', $q$SELECT t_role('00000000-0000-0000-0000-00000000f001')$q$, 'NULL');
SELECT t_eq('X1b bob+sales-bot role on hr (bot has no grant)', $q$SELECT t_role('00000000-0000-0000-0000-00000000f002')$q$, 'NULL');
SELECT t_eq('X1c bob+sales-bot visible memory rows', $q$SELECT count(*)::text FROM memory$q$, '0');
COMMIT;
BEGIN; SELECT t_ctx(NULL, NULL);
SELECT t_eq('X1d empty user_id role', $q$SELECT t_role('00000000-0000-0000-0000-00000000f001')$q$, 'NULL');
SELECT t_eq('X1e empty user_id visible rows', $q$SELECT count(*)::text FROM memory$q$, '0');
COMMIT;
BEGIN; SELECT t_ctx(NULL, '00000000-0000-0000-0000-0000000000d1');
SELECT t_eq('X1f agent only (no user) role', $q$SELECT t_role('00000000-0000-0000-0000-00000000f001')$q$, 'NULL');
COMMIT;
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000c1', NULL);
SELECT t_eq('X1g carol alone still curator (no regression)', $q$SELECT t_role('00000000-0000-0000-0000-00000000f001')$q$, 'curator');
COMMIT;

-- X2) 작성자 위조 불가: created_by / on_behalf_of / tenant_id 바인딩
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t_err('X2a bot forges created_by=carol', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','forged','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000a1')$q$, '42501');
SELECT t_err('X2b bot forges on_behalf_of=carol', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','forged','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000c1')$q$, '42501');
SELECT t_err('X2c bot omits on_behalf_of', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','forged','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1')$q$, '42501');
SELECT t_err('X2d wrong tenant_id', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000f001','fact','t','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, '42501');
SELECT t_err('X2e honest bot proposal', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','honest','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, 'ok');
COMMIT;
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t_err('X2f human forges created_by=carol', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','forged','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000c1')$q$, '42501');
SELECT t_err('X2g human sets on_behalf_of', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','forged','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000c1')$q$, '42501');
SELECT t_err('X2h honest human proposal', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','honest','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000a1')$q$, 'ok');
COMMIT;

-- X3) app_rw 는 권한/주체 테이블을 쓸 수 없다 (스스로 curator 부여 불가)
BEGIN;
SELECT t_err('X3a app_rw self-grant via store_grant INSERT', $q$INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES ('00000000-0000-0000-0000-00000000f002','00000000-0000-0000-0000-0000000000a1','curator','00000000-0000-0000-0000-000000000001')$q$, '42501');
SELECT t_err('X3b app_rw store_grant UPDATE', $q$UPDATE store_grant SET role='curator'$q$, '42501');
SELECT t_err('X3c app_rw store_grant DELETE', $q$DELETE FROM store_grant$q$, '42501');
SELECT t_err('X3d app_rw principal UPDATE (re-activate)', $q$UPDATE principal SET active=true$q$, '42501');
SELECT t_err('X3e app_rw group_member INSERT', $q$INSERT INTO group_member VALUES ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000b1')$q$, '42501');
SELECT t_err('X3f app_rw memory_version DELETE', $q$DELETE FROM memory_version$q$, '42501');
SELECT t_err('X3g app_rw memory_version reason UPDATE (no column grant)', $q$UPDATE memory_version SET reason='x'$q$, '42501');
ROLLBACK;

-- X4) 버전/리뷰는 부모 memory 가 보일 때만 보인다
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t_eq('X4a alice+bot hr memory_version rows', $q$SELECT count(*)::text FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000aa001'$q$, '0');
SELECT t_eq('X4b alice+bot hr review rows', $q$SELECT count(*)::text FROM review WHERE memory_id='00000000-0000-0000-0000-0000000aa001'$q$, '0');
SELECT t_eq('X4c alice+bot sees sales memory_version rows (own store visible)', $q$SELECT (count(*) >= 1)::text FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000bb001'$q$, 'true');
SELECT t_eq('X4d alice+bot sales review rows', $q$SELECT count(*)::text FROM review$q$, '1');
SELECT t_err('X4e insert version on hr memory', $q$INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot) VALUES ('00000000-0000-0000-0000-0000000aa001',2,'edit','00000000-0000-0000-0000-0000000000d1','{}')$q$, '42501');
SELECT t_err('X4f insert review on hr memory', $q$INSERT INTO review (memory_id, reviewer_id, verdict) VALUES ('00000000-0000-0000-0000-0000000aa001','00000000-0000-0000-0000-0000000000d1','comment')$q$, '42501');
SELECT t_err('X4g version actor forged as carol', $q$INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot) VALUES ('00000000-0000-0000-0000-0000000bb001',2,'edit','00000000-0000-0000-0000-0000000000c1','{}')$q$, '42501');
SELECT t_err('X4h insert version on sales memory (triggers only)', $q$INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot) VALUES ('00000000-0000-0000-0000-0000000bb001',2,'edit','00000000-0000-0000-0000-0000000000d1','{"title":"v2"}')$q$, '42501');
SELECT t_err('X4i bot comment review on sales memory (decision function only)', $q$INSERT INTO review (memory_id, reviewer_id, verdict) VALUES ('00000000-0000-0000-0000-0000000bb001','00000000-0000-0000-0000-0000000000d1','comment')$q$, '42501');
SELECT t_err('X4j bot approve review (needs curator)', $q$INSERT INTO review (memory_id, reviewer_id, verdict) VALUES ('00000000-0000-0000-0000-0000000bb001','00000000-0000-0000-0000-0000000000d1','approve')$q$, '42501');
COMMIT;
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000b1', NULL);
SELECT t_eq('X4k bob(hr) sees hr version', $q$SELECT (count(*) >= 1)::text FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000aa001'$q$, 'true');
SELECT t_eq('X4l bob(hr) sees no sales version/review', $q$SELECT (SELECT count(*) FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000bb001') + (SELECT count(*) FROM review WHERE memory_id='00000000-0000-0000-0000-0000000bb001')$q$, '0');
COMMIT;

-- X5) redact 는 curator 만, snapshot 외 컬럼(reason 포함) 변경 불가 / review 는 append-only
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t_err('X5a contributor alice redact (no UPDATE privilege)', $q$UPDATE memory_version SET snapshot=NULL WHERE memory_id='00000000-0000-0000-0000-0000000bb001' AND version=2$q$, '42501');
COMMIT;
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000c1', NULL);
SELECT t_err('X5b curator carol redact (only the delete trigger redacts)', $q$UPDATE memory_version SET snapshot=NULL WHERE memory_id='00000000-0000-0000-0000-0000000bb001' AND version=2$q$, '42501');
COMMIT;
RESET ROLE;
SELECT t_err('X5c redact + rewrite reason (owner)', $q$UPDATE memory_version SET snapshot=NULL, reason='rewritten' WHERE reason='original'$q$, 'P0001');
SELECT t_err('X5d redact + change at', $q$UPDATE memory_version SET snapshot=NULL, at=now()+interval '1 day' WHERE reason='original'$q$, 'P0001');
SELECT t_err('X5e un-redact (NULL -> value)', $q$UPDATE memory_version SET snapshot='{"x":1}' WHERE memory_id='00000000-0000-0000-0000-0000000bb001' AND version=2$q$, 'P0001');
SELECT t_err('X5f plain redact keeps reason', $q$UPDATE memory_version SET snapshot=NULL WHERE reason='original'$q$, 'ok');
SELECT t_eq('X5g reason intact after redact', $q$SELECT reason FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000aa001'$q$, 'original');
SELECT t_err('X5h review UPDATE blocked', $q$UPDATE review SET note='tamper'$q$, 'P0001');
SELECT t_err('X5i review DELETE blocked', $q$DELETE FROM review$q$, 'P0001');

-- X6) 비활성 principal/그룹은 아무 권한도 주지 않는다
UPDATE principal SET active=false WHERE external_id='carol';
SET ROLE app_rw;
BEGIN; SELECT t_ctx_soft('00000000-0000-0000-0000-0000000000c1', NULL);
SELECT t_eq('X6a deactivated carol role', $q$SELECT t_role('00000000-0000-0000-0000-00000000f001')$q$, 'NULL');
SELECT t_eq('X6b deactivated carol visible rows', $q$SELECT count(*)::text FROM memory$q$, '0');
COMMIT;
RESET ROLE;
UPDATE principal SET active=true WHERE external_id='carol';
UPDATE principal SET active=false WHERE external_id='sales' AND kind='group';
SET ROLE app_rw;
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t_eq('X6c alice via deactivated group sales', $q$SELECT t_role('00000000-0000-0000-0000-00000000f001')$q$, 'NULL');
COMMIT;
RESET ROLE;
UPDATE principal SET active=true WHERE external_id='sales' AND kind='group';
UPDATE principal SET active=false WHERE external_id='sales-bot';
SET ROLE app_rw;
BEGIN; SELECT t_ctx_soft('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t_eq('X6d alice + deactivated sales-bot', $q$SELECT t_role('00000000-0000-0000-0000-00000000f001')$q$, 'NULL');
COMMIT;
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t_eq('X6e alice alone unaffected', $q$SELECT t_role('00000000-0000-0000-0000-00000000f001')$q$, 'contributor');
COMMIT;
RESET ROLE;
UPDATE principal SET active=true WHERE external_id='sales-bot';
SET ROLE app_rw;
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t_eq('X6f reactivated -> contributor again', $q$SELECT t_role('00000000-0000-0000-0000-00000000f001')$q$, 'contributor');
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
SELECT t_eq('A10a app_rw login/bypassrls/inherit', $q$SELECT rolcanlogin || '/' || rolbypassrls || '/' || rolinherit FROM pg_roles WHERE rolname = 'app_rw'$q$, 'true/false/false');
SELECT t_eq('A10b tables with FORCE ROW LEVEL SECURITY', $q$SELECT string_agg(relname::text, ',' ORDER BY relname) FROM pg_class WHERE relforcerowsecurity$q$, 'deleted_hash,memory,memory_version,review');

SET ROLE app_rw;

-- A1) 컨텍스트는 begin_request 만 만들 수 있다 (N1, N2)
SELECT t_err('F3a inactive user Eve', $q$SELECT t_ctx('00000000-0000-0000-0000-0000000000f2', NULL)$q$, '28000');
SELECT t_err('F3b group id as user (N2a)', $q$SELECT t_ctx('00000000-0000-0000-0000-0000000000e1', NULL)$q$, '28000');
SELECT t_err('F3c agent id as user (N2b)', $q$SELECT t_ctx('00000000-0000-0000-0000-0000000000d1', NULL)$q$, '28000');
SELECT t_err('F3d user id as agent', $q$SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000c1')$q$, '28000');
SET app.user_id = '00000000-0000-0000-0000-0000000000c1'; SET app.agent_id = '';
SET app.tenant_id = '00000000-0000-0000-0000-000000000001'; SET app.ctx_xid = '1';
BEGIN;
SELECT t_eq('F4 session-level SET with forged ctx_xid sees rows (N1)', $q$SELECT count(*)::text FROM memory$q$, '0');
COMMIT;
RESET app.user_id; RESET app.agent_id; RESET app.tenant_id; RESET app.ctx_xid;

-- A2) 교집합: Bob(hr curator, sales reader) + sales-bot(contributor) = sales 의 reader 만
RESET ROLE;
INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES
 ('00000000-0000-0000-0000-00000000f001','00000000-0000-0000-0000-0000000000b1','reader','00000000-0000-0000-0000-000000000001');
SET ROLE app_rw;
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000d1');
SELECT t_eq('F1 bob(hr curator, sales reader)+sales-bot roles', $q$SELECT coalesce(string_agg(s.slug || '=' || t_role(s.id), ',' ORDER BY s.slug), 'none') FROM store AS s WHERE t_role(s.id) IS NOT NULL$q$, 'sales=reader');
COMMIT;
RESET ROLE;
DELETE FROM store_grant WHERE principal_id = '00000000-0000-0000-0000-0000000000b1' AND store_id = '00000000-0000-0000-0000-00000000f001';
SET ROLE app_rw;

-- A6) proposed 는 대리된 사용자 본인에게만 보인다 (N7)
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
INSERT INTO memory (id, tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
VALUES ('00000000-0000-0000-0000-0000000cc002', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000f001', 'note', '민감한 초안', 'draft', '[]', '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1');
COMMIT;
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000d1');
SELECT t_eq('F6a dave(reader)+same bot sees alice proposal (N7a)', $q$SELECT count(*)::text FROM memory WHERE id = '00000000-0000-0000-0000-0000000cc002'$q$, '0');
COMMIT;
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t_eq('F6b alice without agent sees own proposal (N7b)', $q$SELECT count(*)::text FROM memory WHERE id = '00000000-0000-0000-0000-0000000cc002'$q$, '1');
COMMIT;

-- A5) 테넌트 경계는 복합 FK (N8). 소유자 권한으로도 교차 테넌트 행은 만들 수 없다
RESET ROLE;
BEGIN;
SELECT t_err('N8a cross-tenant principal in grant', $q$INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES ('00000000-0000-0000-0000-00000000f002','00000000-0000-0000-0000-0000000000ff','curator','00000000-0000-0000-0000-000000000001')$q$, '23503');
ROLLBACK;
BEGIN;
SELECT t_err('N8b grant on a store of another tenant', $q$INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES ('00000000-0000-0000-0000-00000000f002','00000000-0000-0000-0000-0000000000ff','curator','00000000-0000-0000-0000-000000000002')$q$, '23503');
ROLLBACK;
BEGIN;
SELECT t_err('N8c memory whose tenant differs from its store', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by) VALUES ('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-00000000f001','note','t','x','[]','00000000-0000-0000-0000-0000000000a1')$q$, '23503');
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
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000d1');
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
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t_eq('F5 client status=active and content_hash are replaced', $q$WITH i AS (
  INSERT INTO memory (id, tenant_id, store_id, kind, status, title, body, source_refs, created_by, on_behalf_of, content_hash)
  VALUES ('00000000-0000-0000-0000-0000000cc001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','active','F5','본문 F5','[{"uri":"https://crm/1"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1','client-hash')
  RETURNING status, content_hash, body) SELECT status || '/' || (content_hash = app_sec.content_hmac(body)) FROM i$q$, 'proposed/true');
COMMIT;

-- 존재 오라클 차단: 못 읽는 행과 없는 행은 같은 오류 (N3)
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t_err('F7a supersedes an hr memory (exists, unreadable)', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of, supersedes_id)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000aa001')$q$, '23503');
SELECT t_err('F7b supersedes a random uuid (absent)', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of, supersedes_id)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000dead')$q$, '23503');
SELECT t_err('F7h supersedes a readable memory of another store', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of, supersedes_id)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000ff001')$q$, '23503');
SELECT t_err('F7c memory:// citation of an hr memory', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"memory://00000000-0000-0000-0000-0000000aa001"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, '23503');
SELECT t_err('F7d memory:// citation of a random uuid', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"memory://00000000-0000-0000-0000-00000000dead"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, '23503');
SELECT t_err('F7e memory:// citation that is not a uuid', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"memory://not-a-uuid"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, '23503');
SELECT t_eq('F7f citing an external memory makes the derived memory external (N11)', $q$WITH i AS (
  INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"memory://00000000-0000-0000-0000-0000000ee001"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')
  RETURNING origin) SELECT origin::text FROM i$q$, 'external');
SELECT t_eq('F7g citing an internal memory keeps it internal', $q$WITH i AS (
  INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','y','[{"uri":"memory://00000000-0000-0000-0000-0000000bb001"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')
  RETURNING origin) SELECT origin::text FROM i$q$, 'internal');
ROLLBACK;

-- A3, A4) 감사·삭제 해시·리뷰는 앱이 직접 쓰지 못한다 (N4, N6)
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t_err('F8a deleted_hash INSERT into hr (N4a)', $q$INSERT INTO deleted_hash (store_id, content_hash, reason) VALUES ('00000000-0000-0000-0000-00000000f002','h1','censor')$q$, '42501');
SELECT t_err('F8b bot inserts an approve version as itself (N6a)', $q$INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot) VALUES ('00000000-0000-0000-0000-0000000bb001', 9, 'approve', '00000000-0000-0000-0000-0000000000d1', '{"forged":true}')$q$, '42501');
SELECT t_err('F8c memory_version UPDATE', $q$UPDATE memory_version SET snapshot = NULL$q$, '42501');
SELECT t_err('F8d bot inserts an approve review (N6b)', $q$INSERT INTO review (memory_id, reviewer_id, verdict) VALUES ('00000000-0000-0000-0000-0000000bb001','00000000-0000-0000-0000-0000000000d1','approve')$q$, '42501');
SELECT t_eq('N4b alice+bot reads deleted_hash rows', $q$SELECT count(*)::text FROM deleted_hash$q$, '0');
ROLLBACK;
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', NULL);
SELECT t_err('N6c contributor inserts an approve version in her own name', $q$INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot) VALUES ('00000000-0000-0000-0000-0000000bb001', 9, 'approve', '00000000-0000-0000-0000-0000000000a1', '{"forged":true}')$q$, '42501');
ROLLBACK;
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000b1', NULL);
SELECT t_eq('N4c hr curator bob reads hr deleted_hash rows', $q$SELECT count(*)::text FROM deleted_hash$q$, '1');
ROLLBACK;

-- A8, A9) 승인 → origin 세탁 → 작성자 변경 → 삭제 → 소생 → 체인 검증
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000c1', NULL); SET LOCAL app.reason = 'looks good';
UPDATE memory SET status = 'active' WHERE id = '00000000-0000-0000-0000-0000000cc001' AND version = 1;
SELECT t_eq('F9a approved: version / versions logged', $q$SELECT version || '/' || (SELECT count(*) FROM memory_version WHERE memory_id = '00000000-0000-0000-0000-0000000cc001') FROM memory WHERE id = '00000000-0000-0000-0000-0000000cc001'$q$, '2/2');
UPDATE memory SET origin = 'external' WHERE id = '00000000-0000-0000-0000-0000000cc001';
SELECT t_err('F9b launder origin external -> internal (N5a)', $q$UPDATE memory SET origin = 'internal' WHERE id = '00000000-0000-0000-0000-0000000cc001'$q$, 'P0001');
SELECT t_err('F9c rewrite created_by (N5a)', $q$UPDATE memory SET created_by = '00000000-0000-0000-0000-0000000000a1' WHERE id = '00000000-0000-0000-0000-0000000cc001'$q$, 'P0001');
SET LOCAL app.reason = 'PII erasure request #42';
UPDATE memory SET status = 'deleted' WHERE id = '00000000-0000-0000-0000-0000000cc001';
SELECT t_eq('F9d deleted: body null / snapshots all null / deleted_hash rows', $q$SELECT (body IS NULL) || '/' || (SELECT bool_and(snapshot IS NULL) FROM memory_version WHERE memory_id = '00000000-0000-0000-0000-0000000cc001') || '/' || (SELECT count(*) FROM deleted_hash WHERE store_id = '00000000-0000-0000-0000-00000000f001') FROM memory WHERE id = '00000000-0000-0000-0000-0000000cc001'$q$, 'true/true/1');
SELECT t_err('F9e resurrect deleted -> active with a new body (N5b)', $q$UPDATE memory SET status = 'active', body = '되살림' WHERE id = '00000000-0000-0000-0000-0000000cc001'$q$, 'P0001');
SELECT t_eq('F9f chain valid', $q$SELECT app_sec.verify_chain('00000000-0000-0000-0000-0000000cc001')::text$q$, 'true');
SELECT t_eq('F9g ops in order', $q$SELECT string_agg(op::text, ',' ORDER BY id) FROM memory_version WHERE memory_id = '00000000-0000-0000-0000-0000000cc001'$q$, 'propose,approve,edit,delete');
COMMIT;

-- A4) 삭제된 본문의 공백만 바꾼 재제안은 막힌다
BEGIN; SELECT t_ctx('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000d1');
SELECT t_err('F10 re-propose of deleted content with different whitespace', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','again','본문  F5','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1')$q$, '23505');
ROLLBACK;

-- A9) 체인은 변조를 드러낸다: 소유자가 트리거를 끄고 actor 를 바꾸면 verify_chain 이 false
RESET ROLE;
BEGIN;
ALTER TABLE memory_version DISABLE TRIGGER memory_version_append_only;
UPDATE memory_version SET actor_id = '00000000-0000-0000-0000-0000000000b1' WHERE memory_id = '00000000-0000-0000-0000-0000000cc001' AND op = 'approve';
SELECT t_eq('F9h tampered actor breaks the chain', $q$SELECT app_sec.verify_chain('00000000-0000-0000-0000-0000000cc001')::text$q$, 'false');
ROLLBACK;
DROP FUNCTION t_eq(text, text, text); DROP FUNCTION t_err(text, text, text); DROP FUNCTION t_ctx_soft(uuid, uuid); DROP FUNCTION t_ctx(uuid, uuid); DROP FUNCTION t_role(uuid);
