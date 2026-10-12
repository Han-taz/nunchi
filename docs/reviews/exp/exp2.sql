\set QUIET on
\pset footer off
\echo '=== E3b FK 오라클: 존재하지 않는 id ==='
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='00000000-0000-0000-0000-0000000000d1';
DO $$ BEGIN
  INSERT INTO memory (tenant_id, store_id, kind, title, body, source_refs, created_by, supersedes_id)
  VALUES ('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-00000000f001','fact','probe2','x',
          '[{"uri":"x"}]','00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-00000000dead');
  RAISE NOTICE 'E3b: random id exists?? (unexpected)';
EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'E3b: nonexistent id -> FK error (distinguishable from E3a) => existence oracle';
END $$;
COMMIT;
RESET ROLE;
\echo '=== E6 (재실행) 감사 로그 파괴/위조 ==='
INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot, reason)
VALUES ('00000000-0000-0000-0000-0000000aa001', 2, 'edit', '00000000-0000-0000-0000-0000000000b1', '{"title":"연봉 밴드 정책","body":"비공개 v2"}', 'orig');
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='00000000-0000-0000-0000-0000000000d1';
SELECT 'E6a: Alice(sales) reads HR version snapshot: ' || snapshot::text FROM memory_version WHERE memory_id='00000000-0000-0000-0000-0000000aa001' AND snapshot IS NOT NULL;
WITH u AS (UPDATE memory_version SET snapshot=NULL WHERE snapshot IS NOT NULL RETURNING 1) SELECT 'E6b: Alice redacted HR version rows: ' || count(*) FROM u;
INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot, reason)
VALUES ('00000000-0000-0000-0000-0000000bb001', 9, 'approve', '00000000-0000-0000-0000-0000000000c1', '{"title":"forged"}', 'forged approval attributed to Carol');
INSERT INTO review (memory_id, reviewer_id, verdict, note) VALUES ('00000000-0000-0000-0000-0000000aa001', '00000000-0000-0000-0000-0000000000b1', 'approve', 'forged');
SELECT 'E6c: forged audit rows (actor=Carol / reviewer=Bob) inserted by Alice session: ' || ((SELECT count(*) FROM memory_version WHERE reason LIKE 'forged%') + (SELECT count(*) FROM review WHERE note='forged'));
COMMIT;
RESET ROLE;
