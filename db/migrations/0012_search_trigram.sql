-- Forward migration 0012: app_sec.search matches with pg_trgm instead of simple FTS (Korean particles, spacing).
-- Function body and index are copied from db/schema.sql (the schema-drift job compares the two).

CREATE EXTENSION IF NOT EXISTS pg_trgm;
DROP FUNCTION app_sec.search(text, uuid[], memory_status[], memory_kind[]);
DROP INDEX memory_search_idx;
ALTER TABLE memory DROP COLUMN search_tsv;
CREATE INDEX memory_search_idx ON memory USING gin ((title || ' ' || coalesce(body, '')) gin_trgm_ops);

-- ── 검색: pg_trgm (v1.2 §5) ──
-- 한국어는 조사가 붙고 띄어쓰기가 흔들려서 simple FTS 가 '담당자' 로 '담당자는' 을 못 찾는다. trigram 은 부분 문자열로 맞는다.
-- 질의는 두 가지로 맞춘다: 원문, 그리고 공백을 뺀 형태('배포 절차' 로 '배포절차는' 을 찾기 위해). 둘 중 하나가 word_similarity 0.3 이상이면 후보다.
-- 점수 = word_similarity 의 큰 쪽 × 상태 가중치(provisional 0.7, 그 밖 1.0). 인덱스는 title || ' ' || body 식 하나에 건다.
-- RLS 아래에서는 연산자가 non-LEAKPROOF 라 인덱스를 못 쓴다(N10). 그래서 SECURITY DEFINER 함수로 제공하고
-- memory_read 정책과 같은 가시성 규칙을 my_stores() 로 직접 적용한다. 1000자를 넘기면 22023 으로 거부한다.
-- 기본 status 는 active 만이다. 가시성 규칙이 정책과 어긋나지 않는지는 smoke_test 의 N10 이 사용자별로 비교한다.
-- 결과는 점수 순 50건까지. 본문은 돌려주지 않고 id 로 RLS 아래에서 다시 읽는다.
CREATE FUNCTION app_sec.search(
  p_query text,
  p_stores uuid[] DEFAULT null,
  p_statuses memory_status[] DEFAULT ARRAY['active']::memory_status[],
  p_kinds memory_kind[] DEFAULT null
) RETURNS TABLE (id uuid, store_id uuid, kind memory_kind, title text, status memory_status, score real)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
#variable_conflict use_column
DECLARE v_q text; v_squeezed text; v_old_threshold text;
BEGIN
  IF length(p_query) > 1000 THEN
    RAISE EXCEPTION 'search query too long: at most 1000 characters' USING ERRCODE = '22023';
  END IF;
  v_q := btrim(p_query);
  v_squeezed := regexp_replace(v_q, '\s+', '', 'g');
  IF v_squeezed = '' THEN
    RETURN;
  END IF;
  v_old_threshold := coalesce(current_setting('pg_trgm.word_similarity_threshold', true), '0.6');
  PERFORM set_config('pg_trgm.word_similarity_threshold', '0.3', true);
  RETURN QUERY
    SELECT m.id, m.store_id, m.kind, m.title, m.status,
      (greatest(word_similarity(v_q, m.title || ' ' || coalesce(m.body, '')),
                word_similarity(v_squeezed, m.title || ' ' || coalesce(m.body, '')))
       * CASE m.status WHEN 'provisional' THEN 0.7 ELSE 1.0 END)::real AS score
    FROM memory AS m
    WHERE
      m.tenant_id = app_sec.ctx_tenant()
      AND (v_q <% (m.title || ' ' || coalesce(m.body, '')) OR v_squeezed <% (m.title || ' ' || coalesce(m.body, '')))
      AND (p_stores IS NULL OR m.store_id = ANY (p_stores))
      AND m.status = ANY (coalesce(p_statuses, ARRAY['active']::memory_status[]))
      AND (p_kinds IS NULL OR m.kind = ANY (p_kinds))
      AND (
        (m.status IN ('active', 'provisional', 'superseded', 'expired') AND m.store_id IN (SELECT app_sec.my_stores('reader')))
        OR m.store_id IN (SELECT app_sec.my_stores('curator'))
        OR (
          m.status = 'proposed' AND coalesce(m.on_behalf_of, m.created_by) = app_sec.ctx_user()
          AND m.store_id IN (SELECT app_sec.my_stores('reader'))
        )
      )
    ORDER BY score DESC, m.id
    LIMIT 50;
  PERFORM set_config('pg_trgm.word_similarity_threshold', v_old_threshold, true);
END $$;
REVOKE ALL ON FUNCTION app_sec.search(text, uuid[], memory_status[], memory_kind[]) FROM public, app_rw;
GRANT EXECUTE ON FUNCTION app_sec.search(text, uuid[], memory_status[], memory_kind[]) TO app_rw;
