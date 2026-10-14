-- Forward migration 0032: 증거 해시 체인과 쓰기 도우미 (design v1.3 U33d).
-- 쓰는 함수가 증거 행들의 sha256 을 app.reason 에 evidence:<hex> 로 넣고, verify_chain 이 표에서 다시 계산해 맞춘다.
-- 결정 2: 살아 있는 행이 철회되거나 만료되면 그 키의 열린 challenger 가 provisional 이 된다.
-- 전이 표에 challenger -> provisional promote 를 더하고, 워커의 mark_expired 가 만료 뒤 같은 일을 한다.
-- 함수 본문은 db/schema.sql 에서 그대로 복사했다 (schema-drift 가 둘을 비교한다).
INSERT INTO memory_transition (from_status, to_status, op, by_roles)
VALUES ('challenger', 'provisional', 'promote', '{contributor,system}');

-- 증거 (v1.3 §6): 한 줄의 정본 표기와 그 묶음의 sha256. remember() 가 쓰기 전에 입력으로 만들고 verify_chain 이 표에서 같은 함수로 만든다.
-- author_name 은 넣지 않는다: 기억을 삭제할 때 지워지는 열이라 넣으면 삭제가 체인을 깬다. 묶음은 줄을 정렬해 해시하므로 행 순서와 무관하다.
CREATE FUNCTION app_sec.evidence_line(
  p_uri text, p_post_id text, p_author text, p_said_at timestamptz, p_basis promotion_basis
) RETURNS text LANGUAGE sql STABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT concat_ws('|', coalesce(p_uri, ''), coalesce(p_post_id, ''), coalesce(p_author, ''), coalesce(extract(EPOCH FROM p_said_at)::text, ''), p_basis::text)
$$;
CREATE FUNCTION app_sec.evidence_digest(p_lines text[]) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT encode(sha256(convert_to(coalesce(string_agg(l, E'\n' ORDER BY l COLLATE "C"), ''), 'UTF8')), 'hex') FROM unnest(p_lines) AS l
$$;

-- 체인 검증. 호출자의 RLS 가 적용되므로 보이는 버전만 검증한다 (없거나 못 보면 NULL).
-- reason 이 evidence:<hex> 인 버전은 그 버전의 증거 행(같은 memory, version, op)의 묶음 해시도 맞아야 한다: 증거를 고치면 false 다.
CREATE OR REPLACE FUNCTION app_sec.verify_chain(p_mem uuid) RETURNS boolean LANGUAGE sql
STABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT bool_and(
    row_hash = encode(
      sha256(convert_to(concat_ws('|', prev_hash, memory_id, version, op, actor_id, snapshot_hash, extract(EPOCH FROM at), coalesce(reason, '')), 'UTF8')),
      'hex'
    )
    AND prev_hash IS NOT DISTINCT FROM expected_prev
    AND coalesce(
      substring(reason FROM '^evidence:([0-9a-f]{64})$') = app_sec.evidence_digest(ARRAY(
        SELECT app_sec.evidence_line(e.uri, e.post_id, e.author, e.said_at, e.basis)
        FROM memory_evidence AS e WHERE e.memory_id = x.memory_id AND e.version = x.version AND e.op = x.op
      )),
      true
    )
  )
  FROM (
    SELECT v.*, lag(row_hash) OVER (ORDER BY id) AS expected_prev
    FROM memory_version AS v WHERE memory_id = p_mem
  ) AS x
$$;

-- ── 쓰기 도우미 (v1.3 §5.1): remember() 가 부르는 내부 함수. 모두 app_rw 가 부를 수 없다 ──

-- 상태를 옮기고 버전 기록에 op 와 사유를 남긴다. 교체는 호출자가 이전 행을 먼저 superseded 로 옮긴 뒤 새 행을 active 로 옮긴다.
CREATE FUNCTION app_sec.move(
  p_id uuid, p_to memory_status, p_op memory_op, p_reason text,
  p_basis promotion_basis DEFAULT null, p_supersedes uuid DEFAULT null
) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  PERFORM set_config('app.op', p_op::text, true);
  PERFORM set_config('app.reason', coalesce(p_reason, ''), true);
  UPDATE memory SET
    status = p_to,
    valid_to = CASE WHEN p_to IN ('superseded', 'expired') THEN current_date ELSE valid_to END,
    valid_from = CASE WHEN p_supersedes IS NOT NULL THEN coalesce(valid_from, current_date) ELSE valid_from END,
    supersedes_id = coalesce(p_supersedes, supersedes_id),
    basis = coalesce(p_basis, basis),
    conflict_with = CASE WHEN p_to = 'provisional' THEN NULL ELSE conflict_with END
  WHERE id = p_id;
END $$;

-- 증거를 쓴다. 쓰기 직전에 app.reason 에 넣은 evidence:<hex> 와 같은 입력이어야 verify_chain 이 맞는다.
CREATE FUNCTION app_sec.evidence_reason(p_basis promotion_basis, p_ev jsonb) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT 'evidence:' || app_sec.evidence_digest(ARRAY(
    SELECT app_sec.evidence_line(e ->> 'uri', e ->> 'post_id', e ->> 'author', (e ->> 'said_at')::timestamptz, p_basis)
    FROM jsonb_array_elements(p_ev) AS e
  ))
$$;
CREATE FUNCTION app_sec.record_evidence(p_memory uuid, p_op memory_op, p_basis promotion_basis, p_ev jsonb) RETURNS void
LANGUAGE sql SET search_path = pg_catalog, public, pg_temp AS $$
  INSERT INTO memory_evidence (memory_id, version, op, uri, post_id, author, author_name, said_at, basis)
  SELECT p_memory, (SELECT m.version FROM memory AS m WHERE m.id = p_memory), p_op,
    e ->> 'uri', e ->> 'post_id', e ->> 'author', e ->> 'author_name', (e ->> 'said_at')::timestamptz, p_basis
  FROM jsonb_array_elements(p_ev) AS e
$$;
-- 같은 게시물은 같은 op 로 한 번만 센다: 이미 기록된 (memory, op, post_id) 증거를 뺀 나머지
CREATE FUNCTION app_sec.new_evidence(p_memory uuid, p_op memory_op, p_ev jsonb) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p_ev) AS e
  WHERE e ->> 'post_id' IS NULL OR NOT EXISTS (
    SELECT 1 FROM memory_evidence AS x WHERE x.memory_id = p_memory AND x.op = p_op AND x.post_id = e ->> 'post_id'
  )
$$;

-- 고아 challenger (결정 2): 키의 살아 있는 행이 철회되거나 만료돼 비면 그 키의 열린 challenger 가 임시 살아 있는 행(provisional)이 된다.
-- promote_at 과 증거는 그대로다. 키마다 살아 있는 행은 하나뿐이다.
CREATE FUNCTION app_sec.adopt_orphan_challenger(p_store uuid, p_subject uuid, p_attribute text) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE c uuid;
BEGIN
  SELECT m.id INTO c FROM memory AS m
  WHERE m.store_id = p_store AND m.subject_id = p_subject AND m.attribute = p_attribute AND m.status = 'challenger'
    AND NOT EXISTS (
      SELECT 1 FROM memory AS l
      WHERE l.store_id = p_store AND l.subject_id = p_subject AND l.attribute = p_attribute AND l.status IN ('active', 'provisional')
    )
  FOR UPDATE;
  IF c IS NOT NULL THEN
    PERFORM app_sec.move(c, 'provisional', 'promote', 'orphaned');
  END IF;
END $$;

-- 워커 전용(컨텍스트 없음 = system 역할): valid_to 가 오늘 이전인 active 행을 expired 로. 옮긴 행 수를 돌려준다
CREATE OR REPLACE FUNCTION app_sec.mark_expired() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE n integer;
BEGIN
  PERFORM set_config('app.op', 'expire', true);
  WITH ex AS (
    UPDATE memory SET status = 'expired' WHERE status = 'active' AND valid_to < current_date RETURNING 1
  )
  SELECT count(*) INTO n FROM ex;
  -- 살아 있는 행이 만료돼 키가 빈 challenger 는 임시 살아 있는 행이 된다 (결정 2)
  PERFORM app_sec.adopt_orphan_challenger(c.store_id, c.subject_id, c.attribute)
  FROM (SELECT DISTINCT store_id, subject_id, attribute FROM memory WHERE status = 'challenger') AS c;
  RETURN n;
END $$;

GRANT EXECUTE ON FUNCTION app_sec.evidence_line(text, text, text, timestamptz, promotion_basis) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.evidence_digest(text[]) TO app_rw;
