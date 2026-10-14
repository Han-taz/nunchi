-- Forward migration 0037: 읽기 표면 (design v1.3 U37).
-- 1) challenger 를 reader 에게 보이게 한다 (memory_read 정책과 app_sec.search 의 vis 를 함께 바꾼다).
-- 2) app_sec.search 가 challenger 를 살아 있는 행에 접어 pending_* 로 돌려주고 basis, promote_at, flags, 키를 함께 준다.
-- 3) app_sec.decide: MCP confirm/retract (contributor, 에이전트 허용, 증거 필수).
-- 함수 본문과 정책은 db/schema.sql 에서 그대로 복사했다 (schema-drift 가 둘을 비교한다).
DROP POLICY memory_read ON memory;
-- 읽기: reader 이상. provisional 과 challenger 는 active 와 같이 reader 에게 보인다 (검토 전이라는 표시는 status 가 한다).
-- challenger(살아 있는 값과 다른 값의 제안)는 search 가 살아 있는 행에 pending_change 로 붙여 보여 주므로 reader 가 읽을 수 있어야 한다.
-- proposed 는 대리된 사용자 본인(에이전트 유무 무관) 또는 사람 작성자와 curator만,
-- deleted/rejected 는 curator만. 봇을 공유하는 다른 사용자는 남의 proposed 를 보지 못한다.
-- app_sec.search 의 vis 와 같은 가시성이다 (smoke_test 의 N10 이 사용자별로 비교한다).
CREATE POLICY memory_read ON memory FOR SELECT USING (
  tenant_id = app_sec.ctx_tenant() AND (
    (
      status IN ('active', 'provisional', 'challenger', 'superseded', 'expired')
      AND store_id IN (SELECT app_sec.my_stores('reader'))
    )
    OR store_id IN (SELECT app_sec.my_stores('curator'))
    OR (
      status = 'proposed' AND coalesce(on_behalf_of, created_by) = app_sec.ctx_user()
      AND store_id IN (SELECT app_sec.my_stores('reader'))
    )
  )
);

DROP FUNCTION app_sec.search(text, uuid[], memory_status[], memory_kind[], real[], text, real, integer);
-- 검색: pg_trgm + pgvector 하이브리드 (v1.2 §5), 변경 제안(challenger) 접기 (v1.3 §8)
-- 한국어는 조사가 붙고 띄어쓰기가 흔들려서 simple FTS 가 '담당자' 로 '담당자는' 을 못 찾는다. trigram 은 부분 문자열로 맞는다.
-- 질의는 두 가지로 맞춘다: 원문, 그리고 공백을 뺀 형태('배포 절차' 로 '배포절차는' 을 찾기 위해). 둘 중 하나가 word_similarity 0.3 이상이면 후보다.
-- 임베딩 질의(p_embedding, p_model)를 주면 코사인 유사도가 p_floor(기본 0.4) 이상인 행을 벡터 순위로 따로 매기고,
-- 두 순위를 RRF(k = p_rrf_k, 기본 60)로 합친다. 질의 벡터는 real[] 로 받아 함수 안에서 vector(512) 로 바꾼다
-- (app_rw 가 vector 입출력 함수를 직접 실행하지 않아도 된다).
-- 합친 점수는 2/(k+1)(두 목록 모두 1위일 때의 값)로 나눠 0..1 로 맞춘다. 임베딩 질의가 없으면 예전 그대로 trigram 점수다.
-- 상태 가중치(provisional 0.7, 그 밖 1.0)는 순위를 합치고 접은 뒤 결과 행의 상태로 곱한다. 인덱스는 title || ' ' || body 식 하나에 건다.
-- challenger 는 p_statuses 에 없어도 찾는다. 질의가 challenger 본문에만 맞아도 같은 키의 살아 있는 행(p_statuses 에 드는 active, provisional)이
-- 결과로 나오고, 그 행에 pending_* 로 열린 challenger 가 붙는다. 살아 있는 행이 결과에 못 드는 challenger 는 버린다.
-- p_statuses 에 challenger 를 넣으면 challenger 도 자기 행으로 나온다.
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
  p_model text DEFAULT null,
  p_floor real DEFAULT 0.4,
  p_rrf_k integer DEFAULT 60
) RETURNS TABLE (
  id uuid, store_id uuid, kind memory_kind, title text, status memory_status, score real,
  stale boolean, last_confirmed_at timestamptz,
  subject_id uuid, attribute text, basis promotion_basis, promote_at timestamptz, flags integer,
  pending_id uuid, pending_title text, pending_value text, pending_promote_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
#variable_conflict use_column
DECLARE v_q text; v_squeezed text; v_old_threshold text; v_vec vector(512); v_st memory_status[];
BEGIN
  IF length(p_query) > 1000 THEN
    RAISE EXCEPTION 'search query too long: at most 1000 characters' USING ERRCODE = '22023';
  END IF;
  v_q := btrim(p_query);
  v_squeezed := regexp_replace(v_q, '\s+', '', 'g');
  IF v_squeezed = '' THEN
    RETURN;
  END IF;
  v_st := coalesce(p_statuses, ARRAY['active']::memory_status[]);
  v_vec := p_embedding::vector(512);
  v_old_threshold := coalesce(current_setting('pg_trgm.word_similarity_threshold', true), '0.6');
  PERFORM set_config('pg_trgm.word_similarity_threshold', '0.3', true);
  RETURN QUERY
    WITH vis AS NOT MATERIALIZED (
      SELECT m.id, m.store_id, m.kind, m.title, m.status, m.body, m.subject_id, m.attribute
      FROM memory AS m
      WHERE
        m.tenant_id = app_sec.ctx_tenant()
        AND (p_stores IS NULL OR m.store_id = ANY (p_stores))
        AND (m.status = ANY (v_st) OR m.status = 'challenger')
        AND (p_kinds IS NULL OR m.kind = ANY (p_kinds))
        AND (
          (m.status IN ('active', 'provisional', 'challenger', 'superseded', 'expired') AND m.store_id IN (SELECT app_sec.my_stores('reader')))
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
      WHERE v_vec IS NOT NULL AND e.model = p_model AND (e.embedding <=> v_vec) <= 1 - p_floor
    ),
    hit AS (
      SELECT v.id, v.status, v.store_id, v.subject_id, v.attribute,
        CASE WHEN v_vec IS NULL THEN t.sim
             ELSE (coalesce(1.0 / (p_rrf_k + t.rk), 0) + coalesce(1.0 / (p_rrf_k + x.rk), 0)) * (p_rrf_k + 1) / 2 END AS raw
      FROM tri AS t FULL JOIN vec AS x ON x.id = t.id
      JOIN vis AS v ON v.id = coalesce(t.id, x.id)
    ),
    folded AS (
      SELECT CASE
          WHEN h.status = 'challenger' AND NOT ('challenger' = ANY (v_st)) THEN
            (SELECT l.id FROM memory AS l
             WHERE l.tenant_id = app_sec.ctx_tenant() AND l.store_id = h.store_id AND l.subject_id = h.subject_id
               AND l.attribute = h.attribute AND l.status IN ('active', 'provisional') AND l.status = ANY (v_st))
          ELSE h.id
        END AS target,
        h.raw
      FROM hit AS h
    )
    SELECT m.id, m.store_id, m.kind, m.title, m.status,
      (g.raw * CASE m.status WHEN 'provisional' THEN 0.7 ELSE 1.0 END)::real AS score,
      app_sec.is_stale(m.status, m.store_id, m.kind, m.last_confirmed_at) AS stale, m.last_confirmed_at,
      m.subject_id, m.attribute, m.basis, m.promote_at,
      CASE WHEN jsonb_typeof(m.gate_result -> 'flags') = 'array' THEN jsonb_array_length(m.gate_result -> 'flags') ELSE 0 END AS flags,
      c.id, c.title, c.value, c.promote_at
    FROM (SELECT f.target, max(f.raw) AS raw FROM folded AS f WHERE f.target IS NOT NULL GROUP BY f.target) AS g
    JOIN memory AS m ON m.id = g.target
    LEFT JOIN memory AS c ON c.status = 'challenger' AND c.tenant_id = m.tenant_id AND c.store_id = m.store_id
      AND c.subject_id = m.subject_id AND c.attribute = m.attribute AND m.status IN ('active', 'provisional')
    ORDER BY score DESC, m.id
    LIMIT 50;
  PERFORM set_config('pg_trgm.word_similarity_threshold', v_old_threshold, true);
END $$;
GRANT EXECUTE ON FUNCTION
app_sec.search(text, uuid[], memory_status[], memory_kind[], real[], text, real, integer)
TO app_rw;

-- MCP decide (v1.3 §8): contributor 이상이면 사람이든 에이전트든 provisional/challenger 를 확정(confirm)하거나 모든 살아 있는 행을 철회(retract)한다.
-- 증거(source_refs)는 필수이고, 작성자는 호출자로 고정한다 (클라이언트가 보낸 author 는 무시한다).
-- 기존 증거에 이미 있는 작성자의 confirm 은 4행처럼 reconfirm 만 한다: 혼자서 확정하지 못한다. active 행의 confirm 도 reconfirm 이다.
-- 결과: applied(r_status = 새 상태), reconfirmed, refused(r_reason = stale 이면 expected_version 이 다름, not_live 이면 대상이 없거나 살아 있지 않거나 contributor 가 아님).
CREATE FUNCTION app_sec.decide(p_memory uuid, p_verdict text, p_expected_version integer, p_evidence jsonb)
RETURNS TABLE (r_outcome text, r_status memory_status, r_reason text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  me uuid := app_sec.ctx_user();
  v_who text := app_sec.ctx_user()::text;
  v_ev jsonb;
  v_fresh jsonb;
  tgt memory;
  live memory;
  chal memory;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'no user context' USING ERRCODE = '28000';
  END IF;
  IF p_verdict NOT IN ('confirm', 'retract') THEN
    RAISE EXCEPTION 'unknown verdict %', p_verdict USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(coalesce(p_evidence, '[]'::jsonb)) = 0 THEN
    RAISE EXCEPTION 'decide needs at least one source ref' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO tgt FROM memory AS m
  WHERE m.id = p_memory AND m.tenant_id = app_sec.ctx_tenant() AND m.store_id IN (SELECT app_sec.my_stores('contributor'))
  FOR UPDATE;
  IF NOT found OR tgt.status NOT IN ('provisional', 'challenger', 'active') THEN
    RETURN QUERY SELECT 'refused'::text, tgt.status, 'not_live'::text;
    RETURN;
  END IF;
  IF tgt.version <> p_expected_version THEN
    RETURN QUERY SELECT 'refused'::text, tgt.status, 'stale'::text;
    RETURN;
  END IF;
  v_ev := (
    SELECT jsonb_agg(jsonb_build_object(
      'uri', e ->> 'uri', 'author', v_who,
      'author_name', (SELECT p.display_name FROM principal AS p WHERE p.id = me), 'said_at', clock_timestamp()::text
    ))
    FROM jsonb_array_elements(p_evidence) AS e
  );

  IF p_verdict = 'retract' THEN
    PERFORM app_sec.move(
      tgt.id, CASE WHEN tgt.status = 'active' THEN 'expired'::memory_status ELSE 'rejected'::memory_status END,
      'retract', app_sec.evidence_reason('agent', v_ev)
    );
    PERFORM app_sec.record_evidence(tgt.id, 'retract', 'agent', v_ev);
    IF tgt.status IN ('active', 'provisional') AND tgt.subject_id IS NOT NULL THEN
      PERFORM app_sec.adopt_orphan_challenger(tgt.store_id, tgt.subject_id, tgt.attribute);
    END IF;
    r_outcome := 'applied';
  ELSIF tgt.status = 'active' OR EXISTS (SELECT 1 FROM memory_evidence AS x WHERE x.memory_id = tgt.id AND x.author = v_who) THEN
    IF tgt.status = 'active' AND tgt.subject_id IS NOT NULL THEN
      SELECT * INTO chal FROM memory AS m
      WHERE m.store_id = tgt.store_id AND m.subject_id = tgt.subject_id AND m.attribute = tgt.attribute AND m.status = 'challenger'
      FOR UPDATE;
      IF found THEN
        PERFORM app_sec.move(chal.id, 'rejected', 'retract', 'reaffirmed');
      END IF;
    END IF;
    v_fresh := app_sec.new_evidence(tgt.id, 'reconfirm', v_ev);
    PERFORM set_config('app.op', 'reconfirm', true);
    PERFORM set_config('app.reason', app_sec.evidence_reason('agent', v_fresh), true);
    UPDATE memory SET last_confirmed_at = clock_timestamp() WHERE id = tgt.id;
    PERFORM app_sec.record_evidence(tgt.id, 'reconfirm', 'agent', v_fresh);
    r_outcome := 'reconfirmed';
  ELSE
    IF tgt.status = 'challenger' THEN
      SELECT * INTO live FROM memory AS m
      WHERE m.store_id = tgt.store_id AND m.subject_id = tgt.subject_id AND m.attribute = tgt.attribute AND m.status IN ('active', 'provisional')
      FOR UPDATE;
      PERFORM app_sec.move(live.id, 'superseded', 'supersede', 'superseded by ' || tgt.id);
      PERFORM app_sec.move(tgt.id, 'active', 'confirm', app_sec.evidence_reason('agent', v_ev), 'agent', live.id);
    ELSE
      PERFORM app_sec.move(tgt.id, 'active', 'confirm', app_sec.evidence_reason('agent', v_ev), 'agent');
    END IF;
    PERFORM app_sec.record_evidence(tgt.id, 'confirm', 'agent', v_ev);
    r_outcome := 'applied';
  END IF;
  PERFORM set_config('app.op', '', true);
  PERFORM set_config('app.reason', '', true);
  SELECT m.status INTO r_status FROM memory AS m WHERE m.id = tgt.id;
  RETURN NEXT;
END $$;
GRANT EXECUTE ON FUNCTION app_sec.decide(uuid, text, integer, jsonb) TO app_rw;
