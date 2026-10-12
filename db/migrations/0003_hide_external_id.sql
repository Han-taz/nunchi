-- Forward migration 0003: hide principal.external_id from app_rw and add the SECURITY DEFINER lookup that replaces it.
-- Function body is copied from db/schema.sql (the schema-drift job compares the two).

-- 토큰의 subject(발급 테넌트, 종류, external_id)를 principal id 로 바꾼다. begin_request 이전, 컨텍스트가 없는 시점에 쓴다.
-- principal.external_id 는 app_rw 에 열려 있지 않으므로(아래 컬럼 GRANT) 이 함수가 유일한 조회 경로다.
-- 활성 principal 만 돌려주고 그 밖에는 NULL 이다. 테넌트와 종류가 정확히 일치해야 한다.
CREATE FUNCTION app_sec.resolve_principal(p_issuer_tenant uuid, p_kind principal_kind, p_external_id text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT id FROM principal
  WHERE tenant_id = p_issuer_tenant AND kind = p_kind AND external_id = p_external_id AND active
$$;
REVOKE ALL ON FUNCTION app_sec.resolve_principal(uuid, principal_kind, text) FROM public, app_rw;
GRANT EXECUTE ON FUNCTION app_sec.resolve_principal(uuid, principal_kind, text) TO app_rw;

-- principal.external_id(IdP subject, SCIM id)는 숨긴다: 컬럼 단위 GRANT 에서 뺀다. SELECT * 는 42501 이다.
REVOKE SELECT ON principal FROM app_rw;
GRANT SELECT (id, tenant_id, kind, display_name, active) ON principal TO app_rw;
