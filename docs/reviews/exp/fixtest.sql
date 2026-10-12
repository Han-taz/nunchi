\set QUIET on
\pset footer off
\set ALICE '00000000-0000-0000-0000-0000000000a1'
\set BOB   '00000000-0000-0000-0000-0000000000b1'
\set CAROL '00000000-0000-0000-0000-0000000000c1'
\set BOT   '00000000-0000-0000-0000-0000000000d1'
\set DAVE  '00000000-0000-0000-0000-0000000000f1'
\set EVE   '00000000-0000-0000-0000-0000000000f2'
\set SALES '00000000-0000-0000-0000-00000000f001'
\set HR    '00000000-0000-0000-0000-00000000f002'
\set HRMEM '00000000-0000-0000-0000-0000000aa001'

SET ROLE app_rw;
\echo '--- F1 Bob(hr curator)+sales-bot: NULL-safe 교집합'
BEGIN; SELECT app_sec.begin_request(:'BOB', :'BOT');
SELECT string_agg(s.slug || '=' || r.role, ', ') AS bob_bot_roles FROM app_sec.my_store_roles() r JOIN store s ON s.id=r.store_id; COMMIT;
\echo '--- F2 Alice+bot: 교집합 contributor / Carol+bot: contributor / Carol: curator'
BEGIN; SELECT app_sec.begin_request(:'ALICE', :'BOT'); SELECT s.slug||'='||r.role FROM app_sec.my_store_roles() r JOIN store s ON s.id=r.store_id WHERE s.slug IN ('sales','hr'); COMMIT;
BEGIN; SELECT app_sec.begin_request(:'CAROL', :'BOT'); SELECT s.slug||'='||r.role FROM app_sec.my_store_roles() r JOIN store s ON s.id=r.store_id WHERE s.slug IN ('sales','hr'); COMMIT;
BEGIN; SELECT app_sec.begin_request(:'CAROL'); SELECT s.slug||'='||r.role FROM app_sec.my_store_roles() r JOIN store s ON s.id=r.store_id WHERE s.slug IN ('sales','hr'); COMMIT;
\echo '--- F3 비활성 Eve / group id 를 user 로 / agent 를 user 로 → 거부'
DO $$ BEGIN PERFORM app_sec.begin_request('00000000-0000-0000-0000-0000000000f2'); RAISE NOTICE 'F3a FAIL'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'F3a Eve rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM app_sec.begin_request('00000000-0000-0000-0000-0000000000e1'); RAISE NOTICE 'F3b FAIL'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'F3b group-as-user rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM app_sec.begin_request('00000000-0000-0000-0000-0000000000d1'); RAISE NOTICE 'F3c FAIL'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'F3c agent-as-user rejected: %', SQLERRM; END $$;
\echo '--- F4 세션 레벨 SET 으로 흉내낸 컨텍스트 / 이전 트랜잭션에서 누수된 컨텍스트 → 권한 없음'
SET app.user_id=:'CAROL'; SET app.agent_id=''; SET app.tenant_id='00000000-0000-0000-0000-000000000001'; SET app.ctx_xid='1';
BEGIN; SELECT 'F4a leaked/forged session ctx → visible rows = ' || count(*) FROM memory; COMMIT;
RESET app.user_id; RESET app.agent_id; RESET app.tenant_id; RESET app.ctx_xid;
\echo '--- F5 저자 위조: Alice+bot 이 created_by=Carol 로 INSERT → 트리거가 세션값으로 덮어씀'
BEGIN; SELECT app_sec.begin_request(:'ALICE', :'BOT');
INSERT INTO memory (id, tenant_id, store_id, kind, title, body, source_refs, created_by, status, content_hash, gate_result)
VALUES ('00000000-0000-0000-0000-0000000cc001', '00000000-0000-0000-0000-000000000002', :'SALES', 'fact', 'F5', '본문 F5', '[{"uri":"https://crm/1"}]', :'CAROL', 'active', 'client-hash', '{"pass":true}');
SELECT 'F5 stored: created_by=' || (created_by = :'BOT') || ' on_behalf_of=' || (on_behalf_of = :'ALICE') || ' status=' || status || ' tenant_ok=' || (tenant_id='00000000-0000-0000-0000-000000000001') || ' hash_server=' || (content_hash <> 'client-hash') FROM memory WHERE id='00000000-0000-0000-0000-0000000cc001';
COMMIT;
\echo '--- F6 proposed 가시성: Dave+bot 못 봄 / Alice 혼자 봄'
BEGIN; SELECT app_sec.begin_request(:'DAVE', :'BOT'); SELECT 'F6a Dave+bot sees = ' || count(*) FROM memory WHERE id='00000000-0000-0000-0000-0000000cc001'; COMMIT;
BEGIN; SELECT app_sec.begin_request(:'ALICE');        SELECT 'F6b Alice alone sees = ' || count(*) FROM memory WHERE id='00000000-0000-0000-0000-0000000cc001'; COMMIT;
\echo '--- F7 FK 오라클: HR memory 를 supersedes / memory:// 근거로 → 모두 "not found" 로 동일 응답'
BEGIN; SELECT app_sec.begin_request(:'ALICE', :'BOT');
DO $$ BEGIN INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, supersedes_id) VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000aa001'); RAISE NOTICE 'F7a FAIL'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'F7a existing-but-unreadable: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, supersedes_id) VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-00000000dead'); RAISE NOTICE 'F7b FAIL'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'F7b nonexistent:            %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by) VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','p','x','[{"uri":"memory://00000000-0000-0000-0000-0000000aa001"}]','00000000-0000-0000-0000-0000000000d1'); RAISE NOTICE 'F7c FAIL'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'F7c memory:// to HR:        %', SQLERRM; END $$;
ROLLBACK;
\echo '--- F8 deleted_hash / memory_version / review / store_grant 직접 쓰기 → 권한 거부'
BEGIN; SELECT app_sec.begin_request(:'ALICE', :'BOT');
DO $$ BEGIN INSERT INTO deleted_hash VALUES ('00000000-0000-0000-0000-00000000f002','h',now(),'x'); RAISE NOTICE 'F8a FAIL'; EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'F8a deleted_hash insert denied'; END $$;
DO $$ BEGIN INSERT INTO memory_version (memory_id, version, op, actor_id) VALUES ('00000000-0000-0000-0000-0000000aa001',5,'approve','00000000-0000-0000-0000-0000000000c1'); RAISE NOTICE 'F8b FAIL'; EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'F8b memory_version insert denied'; END $$;
DO $$ BEGIN UPDATE memory_version SET snapshot=NULL; RAISE NOTICE 'F8c FAIL'; EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'F8c memory_version update denied'; END $$;
DO $$ BEGIN INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES ('00000000-0000-0000-0000-00000000f002','00000000-0000-0000-0000-0000000000a1','curator','00000000-0000-0000-0000-000000000001'); RAISE NOTICE 'F8d FAIL'; EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'F8d self-grant denied'; END $$;
SELECT 'F8e Alice sees HR version rows = ' || count(*) FROM memory_version WHERE memory_id=:'HRMEM';
COMMIT;
\echo '--- F9 curator 흐름: 승인(버전/감사 자동) → origin 세탁 시도 → 삭제 → 소생 시도 → 체인 검증'
BEGIN; SELECT app_sec.begin_request(:'CAROL'); SET LOCAL app.reason='looks good';
UPDATE memory SET status='active' WHERE id='00000000-0000-0000-0000-0000000cc001' AND version=1;
SELECT 'F9a approved version=' || version || ' versions logged=' || (SELECT count(*) FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000cc001') FROM memory WHERE id='00000000-0000-0000-0000-0000000cc001';
UPDATE memory SET origin='external' WHERE id='00000000-0000-0000-0000-0000000cc001';
DO $$ BEGIN UPDATE memory SET origin='internal' WHERE id='00000000-0000-0000-0000-0000000cc001'; RAISE NOTICE 'F9b FAIL'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'F9b launder blocked: %', SQLERRM; END $$;
DO $$ BEGIN UPDATE memory SET created_by='00000000-0000-0000-0000-0000000000a1' WHERE id='00000000-0000-0000-0000-0000000cc001'; RAISE NOTICE 'F9c FAIL'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'F9c created_by rewrite blocked: %', SQLERRM; END $$;
SET LOCAL app.reason='PII erasure request #42';
UPDATE memory SET status='deleted' WHERE id='00000000-0000-0000-0000-0000000cc001';
SELECT 'F9d deleted: title=' || title || ' body_null=' || (body IS NULL) || ' snapshots_redacted=' || (SELECT bool_and(snapshot IS NULL) FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000cc001') || ' deleted_hash=' || (SELECT count(*) FROM deleted_hash WHERE store_id=:'SALES') FROM memory WHERE id='00000000-0000-0000-0000-0000000cc001';
DO $$ BEGIN UPDATE memory SET status='active', body='되살림' WHERE id='00000000-0000-0000-0000-0000000cc001'; RAISE NOTICE 'F9e FAIL'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'F9e resurrect blocked: %', SQLERRM; END $$;
SELECT 'F9f chain valid = ' || app_sec.verify_chain('00000000-0000-0000-0000-0000000cc001');
SELECT version, op, actor_id = :'CAROL' AS by_carol, reason, left(prev_hash,8) prev, left(row_hash,8) row FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000cc001' ORDER BY id;
COMMIT;
\echo '--- F10 재제안 차단: 같은 본문을 다시 제안'
BEGIN; SELECT app_sec.begin_request(:'ALICE', :'BOT');
DO $$ BEGIN INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by) VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','again','본문  F5','[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1'); RAISE NOTICE 'F10 FAIL'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'F10 re-propose of deleted content blocked: %', SQLERRM; END $$;
ROLLBACK;
\echo '--- F11 성능: 200k 행 count / 전 store 전문검색 (수정 후)'
\timing on
BEGIN; SELECT app_sec.begin_request(:'ALICE', :'BOT');
SELECT count(*) FROM memory;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, SUMMARY ON) SELECT id, title FROM memory WHERE search_tsv @@ to_tsquery('simple','199999') ORDER BY updated_at DESC LIMIT 20;
COMMIT;
\timing off
RESET ROLE;
