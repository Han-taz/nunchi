-- 추가 취약점 검증 (smoke_test.sql 실행 후 상태에서 실행)
\set QUIET on
\pset footer off
\set T1 '00000000-0000-0000-0000-000000000001'
\set ALICE '00000000-0000-0000-0000-0000000000a1'
\set BOB   '00000000-0000-0000-0000-0000000000b1'
\set CAROL '00000000-0000-0000-0000-0000000000c1'
\set BOT   '00000000-0000-0000-0000-0000000000d1'
\set GSALES '00000000-0000-0000-0000-0000000000e1'
\set SALES '00000000-0000-0000-0000-00000000f001'
\set HR    '00000000-0000-0000-0000-00000000f002'
\set HRMEM '00000000-0000-0000-0000-0000000aa001'
\set BB1   '00000000-0000-0000-0000-0000000bb001'

-- 준비: Dave(영업 reader), 비활성 사용자 Eve(hr curator였다가 퇴사)
INSERT INTO principal (id, tenant_id, kind, external_id, display_name, active) VALUES
 ('00000000-0000-0000-0000-0000000000f1', :'T1', 'user', 'dave', 'Dave(영업 reader)', true),
 ('00000000-0000-0000-0000-0000000000f2', :'T1', 'user', 'eve',  'Eve(퇴사, hr curator)', false);
INSERT INTO store_grant VALUES (:'SALES', '00000000-0000-0000-0000-0000000000f1', 'reader'),
                               (:'HR',    '00000000-0000-0000-0000-0000000000f2', 'curator');
ANALYZE;

\echo '=== E1 (X1 확인) Bob(HR curator)+sales-bot 의 실효권한 ==='
BEGIN; SET LOCAL app.user_id=:'BOB'; SET LOCAL app.agent_id=:'BOT';
SELECT 'sales: ' || coalesce(effective_role(:'SALES')::text,'NULL') AS bob_bot_sales,
       'hr: '    || coalesce(effective_role(:'HR')::text,'NULL')    AS bob_bot_hr;
COMMIT;

\echo '=== E2 세션 변수 누수: SET(LOCAL 아님)은 트랜잭션 종료 후에도 남음 ==='
SET ROLE app_rw;
SET app.user_id = :'CAROL'; SET app.agent_id = '';
BEGIN; SELECT 'next txn still curator? ' || (effective_role(:'SALES') = 'curator') AS leak; COMMIT;
-- SET LOCAL을 트랜잭션 밖에서 호출하면 경고만 나고 무시됨 → 이전 세션 값이 그대로 사용됨
SET LOCAL app.user_id = :'ALICE';
SELECT 'after SET LOCAL outside txn, identity = ' || current_setting('app.user_id') AS ident;
RESET app.user_id; RESET app.agent_id; RESET ROLE;

\echo '=== E18 app.user_id 에 group/agent principal id 를 넣어도 통과 (kind 미검사) ==='
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id=:'GSALES'; SET LOCAL app.agent_id='';
SELECT 'as group principal, role on sales = ' || coalesce(effective_role(:'SALES')::text,'NULL') AS r; COMMIT;
BEGIN; SET LOCAL app.user_id=:'BOT'; SET LOCAL app.agent_id='';
SELECT 'as agent-as-user, role on sales = ' || coalesce(effective_role(:'SALES')::text,'NULL') AS r; COMMIT;
RESET ROLE;

\echo '=== E13 app.user_id 미설정 시 동작 (fail-closed 인가?) ==='
SET ROLE app_rw;
DO $$ BEGIN
  PERFORM count(*) FROM memory;
  RAISE NOTICE 'E13: query succeeded without identity (BAD)';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'E13: error (fail-closed via exception): %', SQLERRM;
END $$;
RESET ROLE;

\echo '=== E3 FK 존재 오라클 + 크로스 store supersedes 링크 (Alice+bot, sales contributor) ==='
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id=:'ALICE'; SET LOCAL app.agent_id=:'BOT';
SAVEPOINT a;
DO $$ BEGIN
  INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, supersedes_id)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','probe','x',
          '[{"uri":"memory://00000000-0000-0000-0000-0000000aa001"}]','00000000-0000-0000-0000-0000000000d1',
          '00000000-0000-0000-0000-0000000aa001');
  RAISE NOTICE 'E3a: HR memory id EXISTS (insert ok) -> cross-store supersedes link created';
EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'E3a: id does not exist';
END $$;
DO $$ BEGIN
  INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, supersedes_id)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','probe2','x',
          '[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000dead');
  RAISE NOTICE 'E3b: random id exists?? (unexpected)';
EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'E3b: random id does NOT exist (FK error) -> oracle confirmed';
END $$;
SELECT 'E3c: can Alice read the HR row she linked? rows=' || count(*) FROM memory WHERE id=:'HRMEM';
COMMIT;
RESET ROLE;

\echo '=== E4 deleted_hash: 타 store 에 검열용 해시 삽입 / 전체 열람 / PK 충돌 오라클 ==='
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id=:'ALICE'; SET LOCAL app.agent_id=:'BOT';
INSERT INTO deleted_hash (store_id, content_hash, reason) VALUES (:'HR', encode(sha256('연봉 밴드 정책'),'hex'), 'censor');
SELECT 'E4a: Alice inserted deleted_hash into HR store: rows visible=' || count(*) FROM deleted_hash WHERE store_id=:'HR';
DO $$ BEGIN
  INSERT INTO deleted_hash (store_id, content_hash, reason) VALUES ('00000000-0000-0000-0000-00000000f002', encode(sha256('연봉 밴드 정책'),'hex'), 'probe');
EXCEPTION WHEN unique_violation THEN RAISE NOTICE 'E4b: unique_violation -> confirms this content was deleted in HR store (oracle)';
END $$;
COMMIT;
RESET ROLE;

\echo '=== E7 proposed 가시성: 같은 봇을 쓰는 다른 사용자(Dave, reader)가 Alice 의 제안을 봄 / Alice 혼자서는 못 봄 ==='
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id=:'ALICE'; SET LOCAL app.agent_id=:'BOT';
INSERT INTO memory (id, tenant_id, store_id, kind, title, body, source_refs, created_by, on_behalf_of)
VALUES ('00000000-0000-0000-0000-0000000bb002', :'T1', :'SALES', 'fact', 'Alice 의 미승인 제안', '민감한 초안', '[{"uri":"https://crm/x"}]', :'BOT', :'ALICE');
COMMIT;
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000f1'; SET LOCAL app.agent_id=:'BOT';
SELECT 'E7a: Dave(reader)+bot sees Alice proposal rows=' || count(*) FROM memory WHERE id='00000000-0000-0000-0000-0000000bb002'; COMMIT;
BEGIN; SET LOCAL app.user_id=:'ALICE'; SET LOCAL app.agent_id='';
SELECT 'E7b: Alice alone sees her own proposal rows=' || count(*) FROM memory WHERE id='00000000-0000-0000-0000-0000000bb002'; COMMIT;
RESET ROLE;

\echo '=== E5 curator 세탁/소생: origin, created_by, store 이동, deleted→active 복원 ==='
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id=:'CAROL'; SET LOCAL app.agent_id='';
UPDATE memory SET origin='external', source_refs='[{"uri":"https://evil.example/doc"}]' WHERE id=:'BB1';
UPDATE memory SET origin='internal', created_by=:'ALICE', source_refs='[{"uri":"https://crm/official"}]', gate_result='{"pass":true}' WHERE id=:'BB1';
SELECT 'E5a: laundered origin=' || origin || ' created_by=' || created_by || ' version=' || version FROM memory WHERE id=:'BB1';
UPDATE memory SET status='deleted', body=NULL WHERE id=:'BB1';
UPDATE memory SET status='active', body='되살린 본문' WHERE id=:'BB1';
SELECT 'E5b: resurrected status=' || status || ' body=' || body FROM memory WHERE id=:'BB1';
SAVEPOINT s;
DO $$ BEGIN
  UPDATE memory SET store_id='00000000-0000-0000-0000-00000000f002' WHERE id='00000000-0000-0000-0000-0000000bb001';
  RAISE NOTICE 'E5c: moved sales memory into HR store (BAD)';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'E5c: move to HR store blocked (WITH CHECK = USING) ok';
END $$;
UPDATE memory SET tenant_id = gen_random_uuid() WHERE id=:'BB1' AND false; -- (FK 때문에 임의 tenant 불가; 아래 E9에서 별도 확인)
COMMIT;
RESET ROLE;

\echo '=== E6 감사 로그 파괴/위조: contributor 세션에서 memory_version 전체 redact, 가짜 approve 버전/리뷰 삽입 ==='
RESET ROLE;
INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot, reason)
VALUES (:'HRMEM', 1, 'propose', :'BOB', '{"title":"연봉 밴드 정책","body":"비공개"}', 'orig');
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id=:'ALICE'; SET LOCAL app.agent_id=:'BOT';
SELECT 'E6a: Alice reads HR version snapshot: ' || snapshot::text FROM memory_version WHERE memory_id=:'HRMEM';
WITH u AS (UPDATE memory_version SET snapshot=NULL RETURNING 1) SELECT 'E6b: Alice redacted ALL version rows: ' || count(*) FROM u;
INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot, reason)
VALUES (:'BB1', 2, 'approve', :'CAROL', '{"title":"forged"}', 'forged approval by alice');
INSERT INTO review (memory_id, reviewer_id, verdict, note) VALUES (:'HRMEM', :'BOB', 'approve', 'forged');
SELECT 'E6c: forged approve rows by Carol/Bob now in audit: ' || count(*) FROM memory_version mv WHERE reason LIKE 'forged%';
COMMIT;
RESET ROLE;

\echo '=== E9 테넌트 경계: 타 테넌트 principal 에게 grant, 타 테넌트 store 의 memory 에 tenant_id 불일치 ==='
INSERT INTO tenant (id, name) VALUES ('00000000-0000-0000-0000-000000000002', 'evilcorp');
INSERT INTO principal (id, tenant_id, kind, external_id, display_name) VALUES
 ('00000000-0000-0000-0000-0000000000ff', '00000000-0000-0000-0000-000000000002', 'user', 'mallory', 'Mallory(타 테넌트)');
SET ROLE app_rw;  -- X3: app_rw 가 grant 를 쓸 수 있음
INSERT INTO store_grant VALUES (:'HR', '00000000-0000-0000-0000-0000000000ff', 'curator');
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000ff'; SET LOCAL app.agent_id='';
SELECT 'E9a: cross-tenant Mallory reads HR rows=' || count(*) FROM memory WHERE store_id=:'HR';
INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by)
VALUES ('00000000-0000-0000-0000-000000000002', :'HR', 'note', 'tenant mismatch row', 'x', '[]', '00000000-0000-0000-0000-0000000000ff');
SELECT 'E9b: memory.tenant_id != store.tenant_id accepted: ' || count(*) FROM memory m JOIN store s ON s.id=m.store_id WHERE m.tenant_id<>s.tenant_id;
COMMIT;
RESET ROLE;

\echo '=== E8 통계/카탈로그 부채널 (pg_stats, reltuples) ==='
SET ROLE app_rw;
SELECT 'E8a: pg_stats rows visible for memory = ' || count(*) FROM pg_stats WHERE tablename='memory';
SELECT 'E8b: pg_class.reltuples(memory) = ' || reltuples || ', n_live_tup=' || (SELECT n_live_tup FROM pg_stat_user_tables WHERE relname='memory') FROM pg_class WHERE relname='memory';
RESET ROLE;

\echo '=== E6d 비활성(퇴사) Eve 가 여전히 hr curator (X6 확인) ==='
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000f2'; SET LOCAL app.agent_id='';
SELECT 'Eve(active=false) role on hr = ' || coalesce(effective_role(:'HR')::text,'NULL'); COMMIT;
RESET ROLE;
