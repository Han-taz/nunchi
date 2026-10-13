-- Forward migration 0019: app_sec.search fuses trigram and vector ranks (RRF) when a query embedding is given.
-- The function body is copied from db/schema.sql (the schema-drift job compares the two).

DROP FUNCTION app_sec.search(text, uuid[], memory_status[], memory_kind[]);

-- ── 검색: pg_trgm + pgvector 하이브리드 (v1.2 §5) ──
-- 한국어는 조사가 붙고 띄어쓰기가 흔들려서 simple FTS 가 '담당자' 로 '담당자는' 을 못 찾는다. trigram 은 부분 문자열로 맞는다.
-- 질의는 두 가지로 맞춘다: 원문, 그리고 공백을 뺀 형태('배포 절차' 로 '배포절차는' 을 찾기 위해). 둘 중 하나가 word_similarity 0.3 이상이면 후보다.
-- 임베딩 질의(p_embedding, p_model)를 주면 코사인 거리 0.6 이하(유사도 0.4 이상)인 행을 벡터 순위로 따로 매기고,
-- 두 순위를 RRF(k=60)로 합친다. 질의 벡터는 real[] 로 받아 함수 안에서 vector(512) 로 바꾼다
-- (app_rw 가 vector 입출력 함수를 직접 실행하지 않아도 된다).
-- 합친 점수는 2/61(두 목록 모두 1위일 때의 값)로 나눠 0..1 로 맞춘다. 임베딩 질의가 없으면 예전 그대로 trigram 점수다.
-- 상태 가중치(provisional 0.7, 그 밖 1.0)는 순위를 합친 뒤에 곱한다. 인덱스는 title || ' ' || body 식 하나에 건다.
-- RLS 아래에서는 연산자가 non-LEAKPROOF 라 인덱스를 못 쓴다(N10). 그래서 SECURITY DEFINER 함수로 제공하고
-- memory_read 정책과 같은 가시성 규칙을 my_stores() 로 직접 적용한다(vis). 벡터 목록도 vis 를 거치므로 보이지 않는 스토어의 임베딩은 나오지 않는다.
-- 1000자를 넘기면 22023 으로 거부한다. 기본 status 는 active 만이다. 가시성 규칙이 정책과 어긋나지 않는지는 smoke_test 의 N10 이 사용자별로 비교한다.
-- stale 과 last_confirmed_at 을 함께 준다(§4: 에이전트가 오래된 사실을 단정하지 않게).
-- 결과는 점수 순 50건까지. 본문은 돌려주지 않고 id 로 RLS 아래에서 다시 읽는다.
CREATE FUNCTION app_sec.search(
  p_query text,
  p_stores uuid[] DEFAULT null,
  p_statuses memory_status[] DEFAULT ARRAY['active']::memory_status[],
  p_kinds memory_kind[] DEFAULT null,
  p_embedding real[] DEFAULT null,
  p_model text DEFAULT null
) RETURNS TABLE (
  id uuid, store_id uuid, kind memory_kind, title text, status memory_status, score real,
  stale boolean, last_confirmed_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
#variable_conflict use_column
DECLARE v_q text; v_squeezed text; v_old_threshold text; v_vec vector(512);
BEGIN
  IF length(p_query) > 1000 THEN
    RAISE EXCEPTION 'search query too long: at most 1000 characters' USING ERRCODE = '22023';
  END IF;
  v_q := btrim(p_query);
  v_squeezed := regexp_replace(v_q, '\s+', '', 'g');
  IF v_squeezed = '' THEN
    RETURN;
  END IF;
  v_vec := p_embedding::vector(512);
  v_old_threshold := coalesce(current_setting('pg_trgm.word_similarity_threshold', true), '0.6');
  PERFORM set_config('pg_trgm.word_similarity_threshold', '0.3', true);
  RETURN QUERY
    WITH vis AS NOT MATERIALIZED (
      SELECT m.id, m.store_id, m.kind, m.title, m.status, m.body, m.last_confirmed_at
      FROM memory AS m
      WHERE
        m.tenant_id = app_sec.ctx_tenant()
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
    ),
    tri AS (
      SELECT s.id, s.sim, row_number() OVER (ORDER BY s.sim DESC, s.id) AS rk
      FROM (
        SELECT v.id, greatest(word_similarity(v_q, v.title || ' ' || coalesce(v.body, '')),
                              word_similarity(v_squeezed, v.title || ' ' || coalesce(v.body, ''))) AS sim
        FROM vis AS v
        WHERE v_q <% (v.title || ' ' || coalesce(v.body, '')) OR v_squeezed <% (v.title || ' ' || coalesce(v.body, ''))
      ) AS s
    ),
    vec AS (
      SELECT v.id, row_number() OVER (ORDER BY e.embedding <=> v_vec, v.id) AS rk
      FROM vis AS v JOIN memory_embedding AS e ON e.memory_id = v.id
      WHERE v_vec IS NOT NULL AND e.model = p_model AND (e.embedding <=> v_vec) <= 0.6
    )
    SELECT v.id, v.store_id, v.kind, v.title, v.status,
      (CASE WHEN v_vec IS NULL THEN t.sim
            ELSE (coalesce(1.0 / (60 + t.rk), 0) + coalesce(1.0 / (60 + x.rk), 0)) * 61 / 2 END
       * CASE v.status WHEN 'provisional' THEN 0.7 ELSE 1.0 END)::real AS score,
      app_sec.is_stale(v.status, v.store_id, v.kind, v.last_confirmed_at) AS stale, v.last_confirmed_at
    FROM tri AS t FULL JOIN vec AS x ON x.id = t.id
    JOIN vis AS v ON v.id = coalesce(t.id, x.id)
    ORDER BY score DESC, v.id
    LIMIT 50;
  PERFORM set_config('pg_trgm.word_similarity_threshold', v_old_threshold, true);
END $$;
REVOKE ALL ON FUNCTION app_sec.search(text, uuid[], memory_status[], memory_kind[], real[], text) FROM public, app_rw;
GRANT EXECUTE ON FUNCTION app_sec.search(text, uuid[], memory_status[], memory_kind[], real[], text) TO app_rw;
