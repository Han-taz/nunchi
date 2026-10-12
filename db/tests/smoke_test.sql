-- RLS 동작 검증용 스모크 테스트
\set ON_ERROR_STOP on
CREATE ROLE app_rw NOLOGIN;
GRANT USAGE ON SCHEMA public TO app_rw;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO app_rw;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_rw;

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
  INSERT INTO memory (tenant_id, store_id, kind, status, title, source_refs, created_by)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','active','우회','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1');
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
