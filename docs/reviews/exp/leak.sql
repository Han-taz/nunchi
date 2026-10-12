\set QUIET on
\pset footer off
\echo '--- L1 owner(RLS 미적용): @@ 검색 계획'
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF) SELECT id FROM memory WHERE search_tsv @@ to_tsquery('simple','199999') LIMIT 20;
\echo '--- L2 app_rw(RLS 적용, 원본 정책): @@ 검색 계획'
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='';
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF) SELECT id FROM memory WHERE search_tsv @@ to_tsquery('simple','199999') LIMIT 20;
\echo '--- L3 app_rw: jsonb @> (memory:// 역방향 계보, memory_sources_idx) 계획'
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF) SELECT id FROM memory WHERE source_refs @> '[{"uri":"memory://00000000-0000-0000-0000-0000000aa001"}]';
COMMIT;
RESET ROLE;
\echo '--- L4 leakproof 여부'
SELECT proname, proleakproof FROM pg_proc WHERE proname IN ('ts_match_vq','jsonb_contains','uuid_eq','texteq');
\echo '--- L5 ts_match_vq 를 LEAKPROOF 로 표시 후 app_rw 계획'
ALTER FUNCTION ts_match_vq(tsvector, tsquery) LEAKPROOF;
SET ROLE app_rw;
BEGIN; SET LOCAL app.user_id='00000000-0000-0000-0000-0000000000a1'; SET LOCAL app.agent_id='';
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF) SELECT id FROM memory WHERE search_tsv @@ to_tsquery('simple','199999') LIMIT 20;
COMMIT;
RESET ROLE;
