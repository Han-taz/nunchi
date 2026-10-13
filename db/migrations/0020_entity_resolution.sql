-- Forward migration 0020: entity resolution helpers (U19): add_entity_alias, entity_matches, attribute_matches.
-- The function body is copied from db/schema.sql (the schema-drift job compares the two).

-- 별칭 추가: 서버가 같은 대상이라 판정한 새 표기를 남긴다. entity 는 요청 테넌트 것이어야 하고, 이미 있는 별칭은 그대로 둔다 (재시도에 안전).
CREATE FUNCTION app_sec.add_entity_alias(p_entity uuid, p_name text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  v_tenant uuid := app_sec.ctx_tenant();
BEGIN
  IF v_tenant IS NULL OR app_sec.ctx_user() IS NULL THEN
    RAISE EXCEPTION 'no request context' USING ERRCODE = '42501';
  END IF;
  IF app_sec.norm_text(p_name) = '' THEN
    RAISE EXCEPTION 'empty alias' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM entity AS e WHERE e.id = p_entity AND e.tenant_id = v_tenant) THEN
    RAISE EXCEPTION 'unknown entity' USING ERRCODE = '42501';
  END IF;
  INSERT INTO entity_alias (tenant_id, entity_id, alias_norm) VALUES (v_tenant, p_entity, p_name)
  ON CONFLICT (tenant_id, alias_norm) DO NOTHING;
END $$;

-- 별칭 유사도 조회: app_rw 는 pg_trgm 함수를 직접 못 쓰므로 SECURITY DEFINER 로 주고 테넌트를 직접 건다 (entity 정책과 같은 가시성).
-- sim 은 철자 전체의 유사도, word_sim 은 긴 원문 안에 별칭이 나오는 정도다.
CREATE FUNCTION app_sec.entity_matches(p_text text, p_limit integer)
RETURNS TABLE (entity_id uuid, canonical_name text, alias_norm text, sim real, word_sim real)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT a.entity_id, e.canonical_name, a.alias_norm,
    similarity(a.alias_norm, app_sec.norm_text(p_text)), word_similarity(a.alias_norm, app_sec.norm_text(p_text))
  FROM entity_alias AS a JOIN entity AS e ON e.tenant_id = a.tenant_id AND e.id = a.entity_id
  WHERE a.tenant_id = app_sec.ctx_tenant() AND app_sec.ctx_user() IS NOT NULL
  ORDER BY greatest(similarity(a.alias_norm, app_sec.norm_text(p_text)), word_similarity(a.alias_norm, app_sec.norm_text(p_text))) DESC, a.alias_norm
  LIMIT p_limit
$$;
-- 같은 주제의 살아 있는 속성 중 p_name 과 비슷한 것. 읽을 수 있는 스토어만 본다 (search 의 vis 와 같은 규칙).
CREATE FUNCTION app_sec.attribute_matches(p_store uuid, p_subject uuid, p_name text, p_limit integer)
RETURNS TABLE (attribute text, sim real)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT m.attribute, max(similarity(m.attribute, app_sec.norm_text(p_name)))::real AS sim
  FROM memory AS m
  WHERE m.tenant_id = app_sec.ctx_tenant() AND m.store_id = p_store AND m.subject_id = p_subject
    AND m.status IN ('active', 'provisional') AND m.attribute IS NOT NULL
    AND m.store_id IN (SELECT app_sec.my_stores('reader'))
  GROUP BY m.attribute
  ORDER BY sim DESC, m.attribute
  LIMIT p_limit
$$;

GRANT EXECUTE ON FUNCTION app_sec.add_entity_alias(uuid, text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.entity_matches(text, integer) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.attribute_matches(uuid, uuid, text, integer) TO app_rw;
