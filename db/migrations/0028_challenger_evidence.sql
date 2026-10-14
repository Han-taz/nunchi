-- Forward migration 0028: challenger, memory_evidence, store_autonomy, basis, promote_at (design v1.3 U32a).
-- Statements are copied from db/schema.sql (the schema-drift job compares the two).
-- ALTER TYPE ... ADD VALUE cannot be used again inside the transaction that adds it, and the migration runner
-- applies every pending migration in one transaction. The challenger index and the promote_at check use the new
-- value, so memory_status and memory_op are replaced by new types, as 0006 did. Everything that holds the old types
-- is dropped first and recreated below in its final form.
ALTER TYPE memory_status RENAME TO memory_status_old;
ALTER TYPE memory_op RENAME TO memory_op_old;
CREATE TYPE memory_status AS ENUM (
  'proposed', 'provisional', 'challenger', 'active', 'superseded', 'rejected', 'expired', 'deleted'
);
-- 현재 상태에 이른 근거 (v1.3 §3.1)
CREATE TYPE promotion_basis AS ENUM ('agreed', 'stated', 'timer', 'agent', 'user_store', 'migrated');
CREATE TYPE memory_op AS ENUM (
  'propose', 'auto_activate', 'approve', 'confirm', 'reject', 'retract',
  'edit', 'supersede', 'expire', 'delete', 'redact', 'reconfirm', 'promote'
);

DROP POLICY memory_read ON memory;
DROP POLICY memory_propose ON memory;
ALTER TABLE memory DROP CONSTRAINT memory_check;
DROP INDEX memory_live_key_uidx;
DROP FUNCTION
app_sec.search(text, uuid[], memory_status_old[], memory_kind[], real[], text, real, integer);
DROP FUNCTION app_sec.write_version(memory, memory_op_old, uuid, text);
DROP FUNCTION app_sec.quorum(memory, memory_status_old);
DROP FUNCTION app_sec.is_stale(memory_status_old, uuid, memory_kind, timestamptz);
DROP FUNCTION app_sec.memory_as_of(uuid, uuid, text, date);
ALTER TABLE memory_transition
ALTER COLUMN from_status TYPE memory_status USING from_status::text::memory_status,
ALTER COLUMN to_status TYPE memory_status USING to_status::text::memory_status,
ALTER COLUMN op TYPE memory_op USING op::text::memory_op;
ALTER TABLE approval_tier_rule
ALTER COLUMN initial_status TYPE memory_status USING initial_status::text::memory_status;
ALTER TABLE trust_rule ALTER COLUMN op TYPE memory_op USING op::text::memory_op;
ALTER TABLE memory_version ALTER COLUMN op TYPE memory_op USING op::text::memory_op;
ALTER TABLE memory ALTER COLUMN status DROP DEFAULT;
ALTER TABLE memory ALTER COLUMN status TYPE memory_status USING status::text::memory_status;
ALTER TABLE memory ALTER COLUMN status SET DEFAULT 'proposed';
DROP TYPE memory_status_old;
DROP TYPE memory_op_old;

ALTER TABLE memory
ADD COLUMN basis promotion_basis,
ADD COLUMN promote_at timestamptz,
ADD CONSTRAINT memory_check CHECK (status <> 'deleted' OR body IS null),
ADD CONSTRAINT memory_promote_at_state CHECK (promote_at IS null OR status IN ('provisional', 'challenger'));
-- 한 스토어 안에서 키마다 살아 있는 기억은 최대 하나다. 교체는 decide() 가 이전 행을 먼저 superseded 로 바꾼 뒤 새 행을 활성화한다
CREATE UNIQUE INDEX memory_live_key_uidx ON memory (store_id, subject_id, attribute)
WHERE status IN ('active', 'provisional');
-- 키마다 열린 변경 제안(challenger)은 하나다. 살아 있는 행과는 별개의 유일성이다
CREATE UNIQUE INDEX memory_challenger_uidx ON memory (store_id, subject_id, attribute)
WHERE status = 'challenger';

-- 증거 (v1.3 §6): 전이와 reconfirm 의 근거 메시지. append-only 다 (삭제 때 author_name 을 지우는 예외는 U32b).
-- 해시 체인에는 sha256 을 memory_version.reason 의 evidence:<hex> 로 묶는다 (그 함수는 U33).
CREATE TABLE memory_evidence (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  memory_id uuid NOT NULL REFERENCES memory (id),
  version integer NOT NULL,   -- 이 증거가 만든 memory_version 의 version
  op memory_op NOT NULL,
  uri text,                   -- 게시물 permalink 또는 memory://<id>. 타이머 승격은 NULL
  post_id text,               -- 플랫폼 게시물 id. MCP 는 NULL, 타이머 승격은 digest 커서 값
  author text,                -- 플랫폼 사용자 id 또는 MCP principal id
  author_name text,           -- 기록 시점의 표시 이름
  said_at timestamptz,        -- 게시물 작성 시각
  basis promotion_basis NOT NULL,
  UNIQUE (memory_id, op, post_id)
);
-- store 별 승격 기간 (v1.3 §3.1). 행이 없으면 24시간. 앱 롤에는 권한이 없다
CREATE TABLE store_autonomy (
  store_id uuid PRIMARY KEY REFERENCES store (id),
  promote_after interval NOT NULL DEFAULT '24 hours' CHECK (promote_after > interval '0')
);

CREATE TRIGGER memory_evidence_append_only BEFORE UPDATE OR DELETE ON memory_evidence
FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
ALTER TABLE memory_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE memory_evidence FORCE ROW LEVEL SECURITY;
CREATE POLICY memory_evidence_read ON memory_evidence FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM memory AS m
    WHERE m.id = memory_evidence.memory_id
  )
);

-- 읽기: reader 이상. provisional 은 active 와 같이 reader 에게 보인다 (검토 전이라는 표시는 status 가 한다).
-- proposed 는 대리된 사용자 본인(에이전트 유무 무관) 또는 사람 작성자와 curator만,
-- deleted/rejected 는 curator만. 봇을 공유하는 다른 사용자는 남의 proposed 를 보지 못한다.
CREATE POLICY memory_read ON memory FOR SELECT USING (
  tenant_id = app_sec.ctx_tenant() AND (
    (
      status IN ('active', 'provisional', 'superseded', 'expired')
      AND store_id IN (SELECT app_sec.my_stores('reader'))
    )
    OR store_id IN (SELECT app_sec.my_stores('curator'))
    OR (
      status = 'proposed' AND coalesce(on_behalf_of, created_by) = app_sec.ctx_user()
      AND store_id IN (SELECT app_sec.my_stores('reader'))
    )
  )
);

-- 제안: contributor 이상. 최초 상태는 트리거가 정한 tier 의 approval_tier_rule 값과 같아야 한다 (클라이언트는 고를 수 없다).
-- 작성자 바인딩: 에이전트면 created_by=에이전트, on_behalf_of=사용자 / 아니면 created_by=사용자, on_behalf_of=NULL
CREATE POLICY memory_propose ON memory FOR INSERT WITH CHECK (
  status = (
    SELECT r.initial_status FROM approval_tier_rule AS r
    WHERE r.tier = memory.tier
  ) AND version = 1
  AND tenant_id = app_sec.ctx_tenant()
  AND store_id IN (SELECT app_sec.my_stores('contributor'))
  AND created_by = coalesce(app_sec.ctx_agent(), app_sec.ctx_user())
  AND on_behalf_of IS NOT DISTINCT FROM (CASE WHEN app_sec.ctx_agent() IS NOT null THEN app_sec.ctx_user() END)
);

-- 감사 체인: 행마다 직전 row_hash 에 이어 붙인다. 같은 memory 의 동시 기록은 advisory lock 으로 줄 세운다.
-- 시각은 epoch 로 해시한다 (세션 TimeZone 에 따라 text 표기가 달라지는 것을 피함)
CREATE FUNCTION app_sec.write_version(p_mem memory, p_op memory_op, p_actor uuid, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  snap jsonb;
  prev text;
  shash text;
  ts timestamptz := clock_timestamp();
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(p_mem.id::text, 0));
  snap := CASE WHEN p_op IN ('delete', 'redact') THEN NULL
    ELSE jsonb_build_object(
      'title', p_mem.title, 'body', p_mem.body, 'status', p_mem.status,
      'source_refs', p_mem.source_refs, 'origin', p_mem.origin, 'store_id', p_mem.store_id
    ) END;
  shash := encode(sha256(convert_to(coalesce(snap::text, ''), 'UTF8')), 'hex');
  SELECT row_hash INTO prev FROM memory_version WHERE memory_id = p_mem.id ORDER BY id DESC LIMIT 1;
  INSERT INTO memory_version (memory_id, version, op, actor_id, snapshot, reason, at, snapshot_hash, prev_hash, row_hash)
  VALUES (
    p_mem.id, p_mem.version, p_op, p_actor, snap, p_reason, ts, shash, prev,
    encode(
      sha256(
        convert_to(concat_ws('|', prev, p_mem.id, p_mem.version, p_op, p_actor, shash, extract(EPOCH FROM ts), coalesce(p_reason, '')), 'UTF8')
      ),
      'hex'
    )
  );
END $$;

-- 정족수: 이 전이를 뒷받침하는 review(verdict = 전이의 op)의 서로 다른 비저자 reviewer 수와 필요한 수.
-- 결정 시점에 reviewer(와 via_agent)가 지금도 그 store 의 curator 인 review 만 센다: 역할을 잃은 curator 의 이전 승인은 세지 않는다.
-- 다른 사람의 grant 를 읽어야 해서 SECURITY DEFINER 이고, 호출자가 그 store 의 curator 일 때만 0 이상을 돌려준다(그 외는 0).
-- 활성화(to = active)는 등급의 approvals_needed, 반려/회수는 1.
CREATE FUNCTION app_sec.quorum(p_mem memory, p_to memory_status) RETURNS TABLE (have integer, needed integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT
    (
      SELECT count(DISTINCT v.reviewer_id)::integer FROM review AS v, memory AS m
      WHERE
        m.id = p_mem.id
        AND m.store_id IN (SELECT app_sec.my_stores('curator'))
        AND v.memory_id = m.id
        AND v.version = m.version
        AND v.verdict = (SELECT t.op::text FROM memory_transition AS t WHERE t.from_status = m.status AND t.to_status = p_to)
        AND v.reviewer_id NOT IN (m.created_by, coalesce(m.on_behalf_of, m.created_by))
        AND EXISTS (
          SELECT 1 FROM store_grant AS g
          WHERE g.store_id = m.store_id AND g.tenant_id = m.tenant_id AND g.role = 'curator' AND g.principal_id IN (SELECT app_sec.closure(v.reviewer_id))
        )
        AND (
          v.via_agent_id IS NULL OR EXISTS (
            SELECT 1 FROM store_grant AS g
            WHERE g.store_id = m.store_id AND g.tenant_id = m.tenant_id AND g.role = 'curator' AND g.principal_id IN (SELECT app_sec.closure(v.via_agent_id))
          )
        )
    ),
    CASE WHEN p_to = 'active' THEN (SELECT r.approvals_needed FROM approval_tier_rule AS r WHERE r.tier = p_mem.tier)::integer ELSE 1 END
$$;

-- stale = 살아 있는 행(active, provisional)이고 마지막 확인일 + 유효 기간이 지났다. search 와 stale_memories 가 같은 식을 쓴다
CREATE FUNCTION app_sec.is_stale(
  p_status memory_status, p_store uuid, p_kind memory_kind, p_confirmed timestamptz
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT p_status IN ('active', 'provisional')
    AND coalesce(p_confirmed + make_interval(days => app_sec.freshness_days(p_store, p_kind)) < now(), false);
$$;

-- 키의 이력: 그 날짜에 유효했던 기억 하나. 호출자의 RLS 가 적용된다. valid_from 이 없으면 처음부터, valid_to 는 배타적 끝이다
CREATE FUNCTION app_sec.memory_as_of(p_store uuid, p_subject uuid, p_attribute text, p_as_of date)
RETURNS TABLE (id uuid, title text, body text, status memory_status, valid_from date, valid_to date)
LANGUAGE sql STABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT m.id, m.title, m.body, m.status, m.valid_from, m.valid_to FROM memory AS m
  WHERE m.store_id = p_store AND m.subject_id = p_subject AND m.attribute = app_sec.norm_text(p_attribute)
    AND m.status IN ('active', 'provisional', 'superseded', 'expired')
    AND (m.valid_from IS NULL OR m.valid_from <= p_as_of)
    AND (m.valid_to IS NULL OR p_as_of < m.valid_to)
  ORDER BY m.valid_from DESC NULLS LAST, m.created_at DESC
  LIMIT 1
$$;

-- ── 검색: pg_trgm + pgvector 하이브리드 (v1.2 §5) ──
-- 한국어는 조사가 붙고 띄어쓰기가 흔들려서 simple FTS 가 '담당자' 로 '담당자는' 을 못 찾는다. trigram 은 부분 문자열로 맞는다.
-- 질의는 두 가지로 맞춘다: 원문, 그리고 공백을 뺀 형태('배포 절차' 로 '배포절차는' 을 찾기 위해). 둘 중 하나가 word_similarity 0.3 이상이면 후보다.
-- 임베딩 질의(p_embedding, p_model)를 주면 코사인 유사도가 p_floor(기본 0.4) 이상인 행을 벡터 순위로 따로 매기고,
-- 두 순위를 RRF(k = p_rrf_k, 기본 60)로 합친다. 질의 벡터는 real[] 로 받아 함수 안에서 vector(512) 로 바꾼다
-- (app_rw 가 vector 입출력 함수를 직접 실행하지 않아도 된다).
-- 합친 점수는 2/(k+1)(두 목록 모두 1위일 때의 값)로 나눠 0..1 로 맞춘다. 임베딩 질의가 없으면 예전 그대로 trigram 점수다.
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
  p_model text DEFAULT null,
  p_floor real DEFAULT 0.4,
  p_rrf_k integer DEFAULT 60
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
      WHERE v_vec IS NOT NULL AND e.model = p_model AND (e.embedding <=> v_vec) <= 1 - p_floor
    )
    SELECT v.id, v.store_id, v.kind, v.title, v.status,
      (CASE WHEN v_vec IS NULL THEN t.sim
            ELSE (coalesce(1.0 / (p_rrf_k + t.rk), 0) + coalesce(1.0 / (p_rrf_k + x.rk), 0)) * (p_rrf_k + 1) / 2 END
       * CASE v.status WHEN 'provisional' THEN 0.7 ELSE 1.0 END)::real AS score,
      app_sec.is_stale(v.status, v.store_id, v.kind, v.last_confirmed_at) AS stale, v.last_confirmed_at
    FROM tri AS t FULL JOIN vec AS x ON x.id = t.id
    JOIN vis AS v ON v.id = coalesce(t.id, x.id)
    ORDER BY score DESC, v.id
    LIMIT 50;
  PERFORM set_config('pg_trgm.word_similarity_threshold', v_old_threshold, true);
END $$;

GRANT SELECT ON memory_evidence TO app_rw;
REVOKE ALL ON FUNCTION app_sec.write_version(memory, memory_op, uuid, text) FROM public, app_rw;
REVOKE ALL ON FUNCTION app_sec.is_stale(memory_status, uuid, memory_kind, timestamptz) FROM public, app_rw;
REVOKE ALL ON FUNCTION app_sec.quorum(memory, memory_status) FROM public, app_rw;
REVOKE ALL ON FUNCTION app_sec.memory_as_of(uuid, uuid, text, date) FROM public, app_rw;
REVOKE ALL ON FUNCTION
app_sec.search(text, uuid[], memory_status[], memory_kind[], real[], text, real, integer)
FROM public, app_rw;
GRANT EXECUTE ON FUNCTION app_sec.quorum(memory, memory_status) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.memory_as_of(uuid, uuid, text, date) TO app_rw;
GRANT EXECUTE ON FUNCTION
app_sec.search(text, uuid[], memory_status[], memory_kind[], real[], text, real, integer)
TO app_rw;
