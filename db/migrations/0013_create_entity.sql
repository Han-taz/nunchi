-- Forward migration 0013: app_sec.create_entity, the one write path for entity + alias (design v1.2 section 6, step 4).
-- The function body is copied from db/schema.sql (the schema-drift job compares the two).

-- entity 생성: 수집 파이프라인이 모르는 주제를 만날 때 쓴다. 테넌트는 요청 문맥에서 오고 별칭은 resolve_entity 와 같게 정규화된다.
-- 이미 있는 이름이면 새로 만들지 않고 그 entity 를 돌려준다 (재시도에 안전). entity 승인은 이후 큐레이터 단위의 몫이다.
CREATE FUNCTION app_sec.create_entity(p_name text, p_kind text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  v_tenant uuid := app_sec.ctx_tenant();
  v_id uuid;
BEGIN
  IF v_tenant IS NULL OR app_sec.ctx_user() IS NULL THEN
    RAISE EXCEPTION 'no request context' USING ERRCODE = '42501';
  END IF;
  IF app_sec.norm_text(p_name) = '' THEN
    RAISE EXCEPTION 'empty entity name' USING ERRCODE = '22023';
  END IF;
  SELECT a.entity_id INTO v_id FROM entity_alias AS a
  WHERE a.tenant_id = v_tenant AND a.alias_norm = app_sec.norm_text(p_name);
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  INSERT INTO entity (tenant_id, kind, canonical_name) VALUES (v_tenant, p_kind, btrim(p_name)) RETURNING id INTO v_id;
  INSERT INTO entity_alias (tenant_id, entity_id, alias_norm) VALUES (v_tenant, v_id, p_name);
  RETURN v_id;
END $$;

GRANT EXECUTE ON FUNCTION app_sec.create_entity(text, text) TO app_rw;
