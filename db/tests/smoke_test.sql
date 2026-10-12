-- RLS 동작 검증용 스모크 테스트
\set ON_ERROR_STOP on
-- app_rw 역할과 최소 권한 GRANT 는 schema.sql 에 있다

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
INSERT INTO store_grant VALUES
 ('00000000-0000-0000-0000-00000000f001','00000000-0000-0000-0000-0000000000e1','contributor'),
 ('00000000-0000-0000-0000-00000000f001','00000000-0000-0000-0000-0000000000c1','curator'),
 ('00000000-0000-0000-0000-00000000f001','00000000-0000-0000-0000-0000000000d1','contributor'),
 ('00000000-0000-0000-0000-00000000f002','00000000-0000-0000-0000-0000000000b1','curator');
INSERT INTO memory (id, tenant_id, store_id, kind, status, title, body, source_refs, created_by) VALUES
 ('00000000-0000-0000-0000-0000000aa001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f002',
  'fact','active','연봉 밴드 정책','비공개','[{"uri":"https://hr/x"}]','00000000-0000-0000-0000-0000000000b1');

SET ROLE app_rw;

-- 1) Alice+영업봇: hr store 안 보여야 함
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='00000000-0000-0000-0000-0000000000d1';
SELECT 'T1 alice sees hr rows = ' || count(*) FROM memory; COMMIT;

-- 2) 영업봇이 Alice 대리로 제안 (proposed) → 성공
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='00000000-0000-0000-0000-0000000000d1';
INSERT INTO memory (id, tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
VALUES ('00000000-0000-0000-0000-0000000bb001','00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001',
 'fact','A사 갱신 담당자 변경','김OO → 이OO','[{"uri":"https://crm/acct/A"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1');
SELECT 'T2 propose ok'; COMMIT;

-- 3) 영업봇이 active 로 바로 쓰기 시도 → RLS 거부
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='00000000-0000-0000-0000-0000000000d1';
SAVEPOINT s;
DO $$ BEGIN
  INSERT INTO memory (tenant_id, store_id, kind, status, title, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','active','우회','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000a1');
  RAISE NOTICE 'T3 FAIL: active insert allowed';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'T3 blocked direct active write (ok)';
END $$;
COMMIT;

-- 4) Alice(contributor)는 승인 불가 → 0 rows updated
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='';
WITH u AS (UPDATE memory SET status='active' WHERE id='00000000-0000-0000-0000-0000000bb001' RETURNING 1)
SELECT 'T4 alice approve rows = ' || count(*) FROM u; COMMIT;

-- 5) Carol(curator) 승인 → 1 row
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000c1'; SET LOCAL app.agent_id='';
WITH u AS (UPDATE memory SET status='active' WHERE id='00000000-0000-0000-0000-0000000bb001' RETURNING 1)
SELECT 'T5 carol approve rows = ' || count(*) FROM u; COMMIT;

-- 6) Carol이 영업봇과 함께여도 봇 권한이 contributor라 승인 불가 (교집합)
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000c1'; SET LOCAL app.agent_id='00000000-0000-0000-0000-0000000000d1';
WITH u AS (UPDATE memory SET title=title WHERE id='00000000-0000-0000-0000-0000000bb001' RETURNING 1)
SELECT 'T6 carol+bot curate rows = ' || count(*) FROM u; COMMIT;

-- 7) 버전 기록 수정 금지
RESET ROLE;
INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot)
VALUES ('00000000-0000-0000-0000-0000000bb001',1,'propose','00000000-0000-0000-0000-0000000000d1','{"title":"x"}');
DO $$ BEGIN
  UPDATE memory_version SET reason='tamper';
  RAISE NOTICE 'T7 FAIL';
EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'T7 version tamper blocked (ok)';
END $$;
UPDATE memory_version SET snapshot = NULL;  -- redact 허용
SELECT 'T7b redact ok, snapshot null = ' || (snapshot IS NULL) FROM memory_version;

-- ═══ 회귀 테스트 X1–X6 (보안 수정 검증) ═══════════════════
-- 헬퍼: t_eq = 쿼리 결과(text) 비교, t_err = 실행 시 SQLSTATE 비교('ok' = 성공). 호출자 권한으로 실행됨.
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

-- 사전 데이터(소유자 권한): 다른 tenant, hr/sales 버전·리뷰 행
INSERT INTO tenant (id, name) VALUES ('00000000-0000-0000-0000-000000000002', 'other');
INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot, reason) VALUES
 ('00000000-0000-0000-0000-0000000aa001',1,'propose','00000000-0000-0000-0000-0000000000b1','{"title":"hr"}','original');
INSERT INTO review (memory_id, reviewer_id, verdict, note) VALUES
 ('00000000-0000-0000-0000-0000000aa001','00000000-0000-0000-0000-0000000000b1','comment','hr 전용'),
 ('00000000-0000-0000-0000-0000000bb001','00000000-0000-0000-0000-0000000000c1','comment','sales 리뷰');

SET ROLE app_rw;

-- X1) 한쪽 권한이 없으면 교집합은 무권한 (least 의 NULL 무시 방지) + 미설정/빈 값은 fail-closed
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000b1'; SET LOCAL app.agent_id='00000000-0000-0000-0000-0000000000d1';
SELECT t_eq('X1a bob(hr)+sales-bot role on sales', $q$SELECT effective_role('00000000-0000-0000-0000-00000000f001')::text$q$, 'NULL');
SELECT t_eq('X1b bob+sales-bot role on hr (bot has no grant)', $q$SELECT effective_role('00000000-0000-0000-0000-00000000f002')::text$q$, 'NULL');
SELECT t_eq('X1c bob+sales-bot visible memory rows', $q$SELECT count(*)::text FROM memory$q$, '0');
COMMIT;
BEGIN; SET LOCAL app.user_id=''; SET LOCAL app.agent_id='';
SELECT t_eq('X1d empty user_id role', $q$SELECT effective_role('00000000-0000-0000-0000-00000000f001')::text$q$, 'NULL');
SELECT t_eq('X1e empty user_id visible rows', $q$SELECT count(*)::text FROM memory$q$, '0');
COMMIT;
BEGIN; SET LOCAL app.user_id=''; SET LOCAL app.agent_id='00000000-0000-0000-0000-0000000000d1';
SELECT t_eq('X1f agent only (no user) role', $q$SELECT effective_role('00000000-0000-0000-0000-00000000f001')::text$q$, 'NULL');
COMMIT;
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000c1'; SET LOCAL app.agent_id='';
SELECT t_eq('X1g carol alone still curator (no regression)', $q$SELECT effective_role('00000000-0000-0000-0000-00000000f001')::text$q$, 'curator');
COMMIT;

-- X2) 작성자 위조 불가: created_by / on_behalf_of / tenant_id 바인딩
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='00000000-0000-0000-0000-0000000000d1';
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
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='';
SELECT t_err('X2f human forges created_by=carol', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','forged','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000c1')$q$, '42501');
SELECT t_err('X2g human sets on_behalf_of', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','forged','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000c1')$q$, '42501');
SELECT t_err('X2h honest human proposal', $q$INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','honest','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000a1')$q$, 'ok');
COMMIT;

-- X3) app_rw 는 권한/주체 테이블을 쓸 수 없다 (스스로 curator 부여 불가)
BEGIN;
SELECT t_err('X3a app_rw self-grant via store_grant INSERT', $q$INSERT INTO store_grant VALUES ('00000000-0000-0000-0000-00000000f002','00000000-0000-0000-0000-0000000000a1','curator')$q$, '42501');
SELECT t_err('X3b app_rw store_grant UPDATE', $q$UPDATE store_grant SET role='curator'$q$, '42501');
SELECT t_err('X3c app_rw store_grant DELETE', $q$DELETE FROM store_grant$q$, '42501');
SELECT t_err('X3d app_rw principal UPDATE (re-activate)', $q$UPDATE principal SET active=true$q$, '42501');
SELECT t_err('X3e app_rw group_member INSERT', $q$INSERT INTO group_member VALUES ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000b1')$q$, '42501');
SELECT t_err('X3f app_rw memory_version DELETE', $q$DELETE FROM memory_version$q$, '42501');
SELECT t_err('X3g app_rw memory_version reason UPDATE (no column grant)', $q$UPDATE memory_version SET reason='x'$q$, '42501');
COMMIT;

-- X4) 버전/리뷰는 부모 memory 가 보일 때만 보인다
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='00000000-0000-0000-0000-0000000000d1';
SELECT t_eq('X4a alice+bot hr memory_version rows', $q$SELECT count(*)::text FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000aa001'$q$, '0');
SELECT t_eq('X4b alice+bot hr review rows', $q$SELECT count(*)::text FROM review WHERE memory_id='00000000-0000-0000-0000-0000000aa001'$q$, '0');
SELECT t_eq('X4c alice+bot sales memory_version rows (own store visible)', $q$SELECT count(*)::text FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000bb001'$q$, '1');
SELECT t_eq('X4d alice+bot sales review rows', $q$SELECT count(*)::text FROM review$q$, '1');
SELECT t_err('X4e insert version on hr memory', $q$INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot) VALUES ('00000000-0000-0000-0000-0000000aa001',2,'edit','00000000-0000-0000-0000-0000000000d1','{}')$q$, '42501');
SELECT t_err('X4f insert review on hr memory', $q$INSERT INTO review (memory_id, reviewer_id, verdict) VALUES ('00000000-0000-0000-0000-0000000aa001','00000000-0000-0000-0000-0000000000d1','comment')$q$, '42501');
SELECT t_err('X4g version actor forged as carol', $q$INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot) VALUES ('00000000-0000-0000-0000-0000000bb001',2,'edit','00000000-0000-0000-0000-0000000000c1','{}')$q$, '42501');
SELECT t_err('X4h insert version on sales memory', $q$INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot) VALUES ('00000000-0000-0000-0000-0000000bb001',2,'edit','00000000-0000-0000-0000-0000000000d1','{"title":"v2"}')$q$, 'ok');
SELECT t_err('X4i bot comment review on sales memory', $q$INSERT INTO review (memory_id, reviewer_id, verdict) VALUES ('00000000-0000-0000-0000-0000000bb001','00000000-0000-0000-0000-0000000000d1','comment')$q$, 'ok');
SELECT t_err('X4j bot approve review (needs curator)', $q$INSERT INTO review (memory_id, reviewer_id, verdict) VALUES ('00000000-0000-0000-0000-0000000bb001','00000000-0000-0000-0000-0000000000d1','approve')$q$, '42501');
COMMIT;
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000b1'; SET LOCAL app.agent_id='';
SELECT t_eq('X4k bob(hr) sees hr version', $q$SELECT count(*)::text FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000aa001'$q$, '1');
SELECT t_eq('X4l bob(hr) sees no sales version/review', $q$SELECT (SELECT count(*) FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000bb001') + (SELECT count(*) FROM review WHERE memory_id='00000000-0000-0000-0000-0000000bb001')$q$, '0');
COMMIT;

-- X5) redact 는 curator 만, snapshot 외 컬럼(reason 포함) 변경 불가 / review 는 append-only
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='';
SELECT t_eq('X5a contributor alice redact rows', $q$WITH u AS (UPDATE memory_version SET snapshot=NULL WHERE memory_id='00000000-0000-0000-0000-0000000bb001' AND version=2 RETURNING 1) SELECT count(*)::text FROM u$q$, '0');
COMMIT;
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000c1'; SET LOCAL app.agent_id='';
SELECT t_eq('X5b curator carol redact rows', $q$WITH u AS (UPDATE memory_version SET snapshot=NULL WHERE memory_id='00000000-0000-0000-0000-0000000bb001' AND version=2 RETURNING 1) SELECT count(*)::text FROM u$q$, '1');
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
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000c1'; SET LOCAL app.agent_id='';
SELECT t_eq('X6a deactivated carol role', $q$SELECT effective_role('00000000-0000-0000-0000-00000000f001')::text$q$, 'NULL');
SELECT t_eq('X6b deactivated carol visible rows', $q$SELECT count(*)::text FROM memory$q$, '0');
COMMIT;
RESET ROLE;
UPDATE principal SET active=true WHERE external_id='carol';
UPDATE principal SET active=false WHERE external_id='sales' AND kind='group';
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='';
SELECT t_eq('X6c alice via deactivated group sales', $q$SELECT effective_role('00000000-0000-0000-0000-00000000f001')::text$q$, 'NULL');
COMMIT;
RESET ROLE;
UPDATE principal SET active=true WHERE external_id='sales' AND kind='group';
UPDATE principal SET active=false WHERE external_id='sales-bot';
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='00000000-0000-0000-0000-0000000000d1';
SELECT t_eq('X6d alice + deactivated sales-bot', $q$SELECT effective_role('00000000-0000-0000-0000-00000000f001')::text$q$, 'NULL');
COMMIT;
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='';
SELECT t_eq('X6e alice alone unaffected', $q$SELECT effective_role('00000000-0000-0000-0000-00000000f001')::text$q$, 'contributor');
COMMIT;
RESET ROLE;
UPDATE principal SET active=true WHERE external_id='sales-bot';
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='00000000-0000-0000-0000-0000000000d1';
SELECT t_eq('X6f reactivated -> contributor again', $q$SELECT effective_role('00000000-0000-0000-0000-00000000f001')::text$q$, 'contributor');
COMMIT;
RESET ROLE;
DROP FUNCTION t_eq(text,text,text); DROP FUNCTION t_err(text,text,text);
