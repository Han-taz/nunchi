-- Forward migration 0002: RLS on principal/group_member/store/store_grant, caller-bound principal_closure,
-- and a bounded app_sec.search.
-- Function bodies are copied from db/schema.sql (the schema-drift job compares the two). See docs/design section 5.

-- 비활성 principal(사용자/에이전트)과 비활성 그룹은 아무 권한도 주지 않는다.
-- app_sec.closure 는 내부용(소유자 전용)이다. principal_closure 는 app_rw 에 열려 있으므로 호출자 자신(사용자·에이전트)의
-- 폐쇄 집합만 돌려준다: 남의 그룹 소속을 이 함수로 열람할 수 없다.
CREATE FUNCTION app_sec.closure(p uuid) RETURNS SETOF uuid LANGUAGE sql
STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT id FROM principal WHERE id = p AND active
  UNION
  SELECT gm.group_id FROM group_member gm
    JOIN principal g ON g.id = gm.group_id AND g.active
   WHERE gm.member_id = p
     AND EXISTS (SELECT 1 FROM principal u WHERE u.id = p AND u.active)
$$;
CREATE OR REPLACE FUNCTION principal_closure(p uuid) RETURNS SETOF uuid LANGUAGE sql
STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT app_sec.closure(p)
  WHERE p IN (app_sec.ctx_user(), app_sec.ctx_agent())
$$;

REVOKE ALL ON FUNCTION app_sec.closure(uuid) FROM public, app_rw;

CREATE OR REPLACE FUNCTION app_sec.my_store_roles() RETURNS TABLE (store_id uuid, role store_role)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  WITH ctx AS (SELECT app_sec.ctx_user() AS u, app_sec.ctx_agent() AS a, app_sec.ctx_tenant() AS t),
  ur AS (
    SELECT g.store_id, max(g.role) AS role FROM ctx, store_grant AS g
    WHERE ctx.u IS NOT NULL AND g.tenant_id = ctx.t AND g.principal_id IN (SELECT app_sec.closure(ctx.u))
    GROUP BY g.store_id
  ),
  ar AS (
    SELECT g.store_id, max(g.role) AS role FROM ctx, store_grant AS g
    WHERE ctx.a IS NOT NULL AND g.tenant_id = ctx.t AND g.principal_id IN (SELECT app_sec.closure(ctx.a))
    GROUP BY g.store_id
  )
  SELECT ur.store_id, CASE WHEN ctx.a IS NULL THEN ur.role ELSE least(ur.role, ar.role) END
  FROM ctx, ur
  LEFT JOIN ar ON ar.store_id = ur.store_id
  WHERE ctx.a IS NULL OR ar.role IS NOT NULL
$$;

-- ── 주체/권한 테이블 RLS: 테넌트 경계와 need-to-know ──
-- my_store_roles, closure, begin_request 는 SECURITY DEFINER(소유자)라 이 정책을 거치지 않고 읽는다.
-- principal: 같은 테넌트의 principal 은 모두 보인다 (표시 이름 해석에 필요). store 공유 여부로 좁히지 않는다.
-- group_member: 내 소속(사용자 또는 에이전트)과, 내가 curator 인 store 에 grant 된 그룹의 구성원.
-- store: my_stores() 에 있는 store(role 무관). 목록 API 도 이 집합만 본다.
-- store_grant: 내 폐쇄 집합(나와 내 그룹)의 grant 와, 내가 curator 인 store 의 모든 grant.
ALTER TABLE principal ENABLE ROW LEVEL SECURITY;
ALTER TABLE principal FORCE ROW LEVEL SECURITY;
ALTER TABLE group_member ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_member FORCE ROW LEVEL SECURITY;
ALTER TABLE store ENABLE ROW LEVEL SECURITY;
ALTER TABLE store FORCE ROW LEVEL SECURITY;
ALTER TABLE store_grant ENABLE ROW LEVEL SECURITY;
ALTER TABLE store_grant FORCE ROW LEVEL SECURITY;

CREATE POLICY principal_read ON principal FOR SELECT USING (tenant_id = app_sec.ctx_tenant());

CREATE POLICY group_member_read ON group_member FOR SELECT USING (
  member_id IN (app_sec.ctx_user(), app_sec.ctx_agent())
  OR group_id IN (
    SELECT g.principal_id FROM store_grant AS g
    WHERE g.store_id IN (SELECT app_sec.my_stores('curator'))
  )
);

CREATE POLICY store_read ON store FOR SELECT USING (
  tenant_id = app_sec.ctx_tenant() AND id IN (SELECT app_sec.my_stores('reader'))
);

CREATE POLICY store_grant_read ON store_grant FOR SELECT USING (
  tenant_id = app_sec.ctx_tenant() AND (
    principal_id IN (
      SELECT principal_closure(app_sec.ctx_user())
      UNION
      SELECT principal_closure(app_sec.ctx_agent())
    )
    OR store_id IN (SELECT app_sec.my_stores('curator'))
  )
);

-- ── 검색: RLS 아래에서는 @@ 가 non-LEAKPROOF 라 GIN 인덱스를 못 쓴다 (N10) ──
-- 인덱스를 쓰는 SECURITY DEFINER 함수로 제공하고, memory_read 정책과 같은 가시성 규칙을 my_stores() 로 직접 적용한다.
-- websearch_to_tsquery 비용은 항 수에 제곱으로 늘어난다(30k 항에 CPU 9.6초).
-- 1000자를 넘거나 tsquery 노드(항과 연산자)가 64개를 넘으면 22023 으로 거부한다.
-- 공백 분리 항 수는 NBSP·쉼표 구분을 못 세므로 노드 수로 센다.
-- 기본 status 는 active 만이다. 가시성 규칙이 정책과 어긋나지 않는지는 smoke_test 의 N10 이 사용자별로 비교한다.
-- 결과는 점수 순 50건까지. 본문은 돌려주지 않고 id 로 RLS 아래에서 다시 읽는다.
CREATE OR REPLACE FUNCTION app_sec.search(
  p_query text,
  p_stores uuid[] DEFAULT null,
  p_statuses memory_status[] DEFAULT ARRAY['active']::memory_status[]
) RETURNS TABLE (id uuid, store_id uuid, kind memory_kind, title text, status memory_status, score real)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
#variable_conflict use_column
DECLARE v_tsq tsquery;
BEGIN
  IF length(p_query) > 1000 THEN
    RAISE EXCEPTION 'search query too long: at most 1000 characters' USING ERRCODE = '22023';
  END IF;
  v_tsq := websearch_to_tsquery('simple', p_query);
  IF numnode(v_tsq) > 64 THEN
    RAISE EXCEPTION 'search query too complex: at most 64 tsquery nodes' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  WITH q AS (SELECT v_tsq AS tsq)
    SELECT m.id, m.store_id, m.kind, m.title, m.status, ts_rank(m.search_tsv, q.tsq) AS score
    FROM q, memory AS m
    WHERE
      m.tenant_id = app_sec.ctx_tenant()
      AND m.search_tsv @@ q.tsq
      AND (p_stores IS NULL OR m.store_id = ANY (p_stores))
      AND m.status = ANY (coalesce(p_statuses, ARRAY['active']::memory_status[]))
      AND (
        (m.status IN ('active', 'superseded', 'expired') AND m.store_id IN (SELECT app_sec.my_stores('reader')))
        OR m.store_id IN (SELECT app_sec.my_stores('curator'))
        OR (
          m.status = 'proposed' AND coalesce(m.on_behalf_of, m.created_by) = app_sec.ctx_user()
          AND m.store_id IN (SELECT app_sec.my_stores('reader'))
        )
      )
    ORDER BY score DESC, m.id
    LIMIT 50;
END $$;
