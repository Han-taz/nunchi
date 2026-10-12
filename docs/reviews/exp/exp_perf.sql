-- 성능: 행마다 effective_role() 3회 호출되는 RLS 정책 비용 측정
\set QUIET on
\timing on
-- 20 store, 각 store 10k 행 = 200k 행. Alice 그룹(sales)에 10개 store contributor 부여
INSERT INTO store (id, tenant_id, kind, slug, description)
SELECT ('00000000-0000-0000-0000-0000000' || lpad(to_hex(i),5,'0'))::uuid, '00000000-0000-0000-0000-000000000001', 'team', 'perf'||i, 'perf'
FROM generate_series(1,20) i;
INSERT INTO store_grant
SELECT ('00000000-0000-0000-0000-0000000' || lpad(to_hex(i),5,'0'))::uuid, '00000000-0000-0000-0000-0000000000e1', 'contributor'
FROM generate_series(1,10) i;
INSERT INTO store_grant
SELECT ('00000000-0000-0000-0000-0000000' || lpad(to_hex(i),5,'0'))::uuid, '00000000-0000-0000-0000-0000000000d1', 'contributor'
FROM generate_series(1,20) i;
INSERT INTO memory (tenant_id, store_id, kind, status, title, body, source_refs, created_by)
SELECT '00000000-0000-0000-0000-000000000001',
       ('00000000-0000-0000-0000-0000000' || lpad(to_hex(1 + (g % 20)),5,'0'))::uuid,
       'fact', 'active', 'title '||g, 'body text number '||g||' lorem ipsum 고객 갱신 담당자', '[{"uri":"https://x/"}]',
       '00000000-0000-0000-0000-0000000000d1'
FROM generate_series(1,200000) g;
ANALYZE memory; ANALYZE store_grant; ANALYZE group_member;
\echo '--- owner (RLS 우회) baseline: 전체 count'
SELECT count(*) FROM memory;
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='00000000-0000-0000-0000-0000000000d1';
\echo '--- app_rw Alice+bot: 전체 count (RLS)'
SELECT count(*) FROM memory;
\echo '--- app_rw Alice+bot: 단일 store 전문검색 (index 조건 있어도 정책 함수가 행마다 평가되는지)'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, SUMMARY ON)
SELECT id, title FROM memory WHERE store_id='00000000-0000-0000-0000-000000000003' AND search_tsv @@ to_tsquery('simple','고객') LIMIT 20;
\echo '--- app_rw Alice+bot: 전체 전문검색 (stores 미지정, 설계서의 memory.search 기본)'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, SUMMARY ON)
SELECT id, title FROM memory WHERE search_tsv @@ to_tsquery('simple','고객') ORDER BY updated_at DESC LIMIT 20;
COMMIT;
RESET ROLE;
