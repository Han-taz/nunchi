-- Forward migration 0014: memory freshness (design v1.2 section 4).
-- freshness_default / store_freshness, app_sec.mark_expired / stale_memories,
-- and app_sec.search returning stale + last_confirmed_at.
-- Bodies are copied from db/schema.sql (the schema-drift job compares the two).
-- active -> expired already exists as a system transition.

-- ── 신선도 (v1.2 §4) ──
-- kind 별 기본 유효 기간(일). 행이 없는 kind(decision, note)는 오래돼도 stale 이 아니다. store_freshness 가 스토어별로 덮어쓴다.
-- 두 표 모두 앱 롤에는 권한이 없고, 아래 SECURITY DEFINER 함수만 읽는다.
CREATE TABLE freshness_default (
  kind memory_kind PRIMARY KEY,
  days integer NOT NULL CHECK (days > 0)
);
INSERT INTO freshness_default (kind, days) VALUES ('fact', 180), ('procedure', 90);
CREATE TABLE store_freshness (
  store_id uuid NOT NULL REFERENCES store (id),
  kind memory_kind NOT NULL,
  days integer NOT NULL CHECK (days > 0),
  PRIMARY KEY (store_id, kind)
);


-- 한 (store, kind) 의 유효 기간(일). 스토어 덮어쓰기가 기본값보다 앞선다. NULL = 만료 없음
CREATE FUNCTION app_sec.freshness_days(p_store uuid, p_kind memory_kind) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT coalesce(
    (SELECT s.days FROM store_freshness AS s WHERE s.store_id = p_store AND s.kind = p_kind),
    (SELECT d.days FROM freshness_default AS d WHERE d.kind = p_kind));
$$;
-- stale = 살아 있는 행(active, provisional)이고 마지막 확인일 + 유효 기간이 지났다. search 와 stale_memories 가 같은 식을 쓴다
CREATE FUNCTION app_sec.is_stale(
  p_status memory_status, p_store uuid, p_kind memory_kind, p_confirmed timestamptz
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT p_status IN ('active', 'provisional')
    AND coalesce(p_confirmed + make_interval(days => app_sec.freshness_days(p_store, p_kind)) < now(), false);
$$;
-- 워커 전용(컨텍스트 없음 = system 역할): valid_to 가 오늘 이전인 active 행을 expired 로. 옮긴 행 수를 돌려준다
CREATE FUNCTION app_sec.mark_expired() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  UPDATE memory SET status = 'expired' WHERE status = 'active' AND valid_to < current_date;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
-- 워커 전용: 확인 카드 대상. 가장 오래 확인 안 된 순
CREATE FUNCTION app_sec.stale_memories(p_limit integer) RETURNS TABLE (
  id uuid, tenant_id uuid, store_id uuid, kind memory_kind, title text,
  last_confirmed_at timestamptz, ttl_days integer
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT m.id, m.tenant_id, m.store_id, m.kind, m.title, m.last_confirmed_at, app_sec.freshness_days(m.store_id, m.kind)
  FROM memory AS m
  WHERE app_sec.is_stale(m.status, m.store_id, m.kind, m.last_confirmed_at)
  ORDER BY m.last_confirmed_at, m.id
  LIMIT p_limit;
$$;
REVOKE ALL ON FUNCTION app_sec.freshness_days(uuid, memory_kind) FROM public, app_rw;
REVOKE ALL ON FUNCTION app_sec.is_stale(memory_status, uuid, memory_kind, timestamptz) FROM public, app_rw;
REVOKE ALL ON FUNCTION app_sec.mark_expired() FROM public, app_rw;
REVOKE ALL ON FUNCTION app_sec.stale_memories(integer) FROM public, app_rw;

DROP FUNCTION app_sec.search(text, uuid[], memory_status[], memory_kind[]);
-- ── 검색: pg_trgm (v1.2 §5) ──
-- 한국어는 조사가 붙고 띄어쓰기가 흔들려서 simple FTS 가 '담당자' 로 '담당자는' 을 못 찾는다. trigram 은 부분 문자열로 맞는다.
-- 질의는 두 가지로 맞춘다: 원문, 그리고 공백을 뺀 형태('배포 절차' 로 '배포절차는' 을 찾기 위해). 둘 중 하나가 word_similarity 0.3 이상이면 후보다.
-- 점수 = word_similarity 의 큰 쪽 × 상태 가중치(provisional 0.7, 그 밖 1.0). 인덱스는 title || ' ' || body 식 하나에 건다.
-- RLS 아래에서는 연산자가 non-LEAKPROOF 라 인덱스를 못 쓴다(N10). 그래서 SECURITY DEFINER 함수로 제공하고
-- memory_read 정책과 같은 가시성 규칙을 my_stores() 로 직접 적용한다. 1000자를 넘기면 22023 으로 거부한다.
-- 기본 status 는 active 만이다. 가시성 규칙이 정책과 어긋나지 않는지는 smoke_test 의 N10 이 사용자별로 비교한다.
-- stale 과 last_confirmed_at 을 함께 준다(§4: 에이전트가 오래된 사실을 단정하지 않게).
-- 결과는 점수 순 50건까지. 본문은 돌려주지 않고 id 로 RLS 아래에서 다시 읽는다.
CREATE FUNCTION app_sec.search(
  p_query text,
  p_stores uuid[] DEFAULT null,
  p_statuses memory_status[] DEFAULT ARRAY['active']::memory_status[],
  p_kinds memory_kind[] DEFAULT null
) RETURNS TABLE (
  id uuid, store_id uuid, kind memory_kind, title text, status memory_status, score real,
  stale boolean, last_confirmed_at timestamptz
)
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
       * CASE m.status WHEN 'provisional' THEN 0.7 ELSE 1.0 END)::real AS score,
      app_sec.is_stale(m.status, m.store_id, m.kind, m.last_confirmed_at) AS stale, m.last_confirmed_at
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
