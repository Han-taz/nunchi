-- Forward migration 0018: pgvector, memory_embedding and the worker fill functions.
-- Needs the pgvector extension on the server (CI and compose use the pgvector/pgvector:pg16 image).
-- Function bodies and the table are copied from db/schema.sql (the schema-drift job compares the two).

CREATE EXTENSION IF NOT EXISTS vector;
-- ── 임베딩 (v1.2 §5, §7) ──
-- memory_embedding: 기억 하나당 벡터 한 줄. app_rw 에는 표 권한도 정책도 없어서 search 와 워커 함수로만 읽고 쓴다.
-- updated_at 은 임베딩한 시점의 memory.updated_at 이다. 본문이 바뀌면 둘이 달라져서 워커가 다시 채운다.
-- 벡터는 512차원 고정이다. 인덱스는 아직 없다: 정확한 순차 검색이 가시성 필터와 함께 항상 맞고, 규모가 커지면 HNSW 를 단다.
CREATE TABLE memory_embedding (
  memory_id uuid PRIMARY KEY REFERENCES memory (id) ON DELETE CASCADE,
  model text NOT NULL,
  dim integer NOT NULL,
  embedding vector(512) NOT NULL,
  updated_at timestamptz NOT NULL
);
ALTER TABLE memory_embedding ENABLE ROW LEVEL SECURITY;
ALTER TABLE memory_embedding FORCE ROW LEVEL SECURITY;

-- 워커 전용: 살아 있는 행(active, provisional) 가운데 임베딩이 없거나, 다른 모델이거나, 본문이 바뀐 것. 최근 행부터
CREATE FUNCTION app_sec.memories_to_embed(p_model text, p_limit integer) RETURNS TABLE (
  id uuid, title text, body text, updated_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT m.id, m.title, m.body, m.updated_at
  FROM memory AS m LEFT JOIN memory_embedding AS e ON e.memory_id = m.id
  WHERE m.status IN ('active', 'provisional')
    AND (e.memory_id IS NULL OR e.model <> p_model OR e.updated_at IS DISTINCT FROM m.updated_at)
  ORDER BY m.updated_at DESC, m.id
  LIMIT p_limit;
$$;
-- 워커 전용: 벡터 저장(멱등). p_source_updated 는 memories_to_embed 가 준 updated_at 그대로다
CREATE FUNCTION app_sec.put_embedding(p_memory uuid, p_model text, p_embedding real[], p_source_updated timestamptz)
RETURNS void
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  INSERT INTO memory_embedding (memory_id, model, dim, embedding, updated_at)
  SELECT m.id, p_model, array_length(p_embedding, 1), p_embedding::vector(512), p_source_updated FROM memory AS m WHERE m.id = p_memory
  ON CONFLICT (memory_id) DO UPDATE
    SET model = excluded.model, dim = excluded.dim, embedding = excluded.embedding, updated_at = excluded.updated_at;
$$;
REVOKE ALL ON FUNCTION app_sec.memories_to_embed(text, integer) FROM public, app_rw;
REVOKE ALL ON FUNCTION app_sec.put_embedding(uuid, text, real[], timestamptz) FROM public, app_rw;
GRANT EXECUTE ON FUNCTION app_sec.memories_to_embed(text, integer) TO nunchi_worker;
GRANT EXECUTE ON FUNCTION app_sec.put_embedding(uuid, text, real[], timestamptz) TO nunchi_worker;
