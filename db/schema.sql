-- Team Memory Core — schema v1 (PostgreSQL 16+)
-- 원칙: store = 권한 경계, 변경은 append-only 버전, 범위는 인증 컨텍스트가 주입(app.* 세션 변수)

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── 주체(사람/그룹/에이전트) ─────────────────────────────
CREATE TABLE tenant (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TYPE principal_kind AS ENUM ('user', 'group', 'agent');

CREATE TABLE principal (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenant (id),
  kind principal_kind NOT NULL,
  external_id text NOT NULL,              -- IdP subject / SCIM id / agent client id
  display_name text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  UNIQUE (tenant_id, kind, external_id)
);

-- SCIM 그룹 동기화 결과 (user ∈ group)
CREATE TABLE group_member (
  group_id uuid NOT NULL REFERENCES principal (id) ON DELETE CASCADE,
  member_id uuid NOT NULL REFERENCES principal (id) ON DELETE CASCADE,
  PRIMARY KEY (group_id, member_id)
);

-- ── store = 접근 경계 ───────────────────────────────────
CREATE TYPE store_kind AS ENUM ('org', 'team', 'project', 'user');

CREATE TABLE store (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenant (id),
  kind store_kind NOT NULL,
  slug text NOT NULL,
  description text NOT NULL,              -- 에이전트에게 노출되는 설명
  auto_approve boolean NOT NULL DEFAULT false,  -- user store만 true 허용 (CHECK)
  archived_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, slug),
  CHECK (auto_approve = false OR kind = 'user')
);

CREATE TYPE store_role AS ENUM ('reader', 'contributor', 'curator');
-- reader: 읽기 / contributor: 읽기+제안 / curator: 승인·대체·삭제

CREATE TABLE store_grant (
  store_id uuid NOT NULL REFERENCES store (id) ON DELETE CASCADE,
  principal_id uuid NOT NULL REFERENCES principal (id) ON DELETE CASCADE,  -- user/group/agent
  role store_role NOT NULL,
  PRIMARY KEY (store_id, principal_id)
);

-- ── 메모리 ───────────────────────────────────────────────
CREATE TYPE memory_kind AS ENUM ('fact', 'decision', 'procedure', 'note');
CREATE TYPE memory_status AS ENUM ('proposed', 'active', 'superseded', 'rejected', 'expired', 'deleted');
CREATE TYPE memory_origin AS ENUM ('internal', 'external');

CREATE TABLE memory (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenant (id),
  store_id uuid NOT NULL REFERENCES store (id),
  kind memory_kind NOT NULL,
  status memory_status NOT NULL DEFAULT 'proposed',
  title text NOT NULL,                 -- 목록/검색 노출용 한 줄
  body text,                          -- 삭제 시 NULL (tombstone)
  source_refs jsonb NOT NULL DEFAULT '[]',   -- [{uri, system, inherit_acl:bool}], memory://<id> 포함
  owner_id uuid REFERENCES principal (id), -- 정정 책임자
  origin memory_origin NOT NULL DEFAULT 'internal',
  valid_from date,
  valid_to date,
  supersedes_id uuid REFERENCES memory (id),
  created_by uuid NOT NULL REFERENCES principal (id),  -- 작성 주체(에이전트 or 사람)
  on_behalf_of uuid REFERENCES principal (id),           -- 에이전트가 대리한 사용자
  session_ref text,                                    -- 에이전트 세션/런 ID
  gate_result jsonb NOT NULL DEFAULT '{}',             -- 쓰기 게이트 결과
  content_hash text,                                    -- sha256(normalized body)
  version integer NOT NULL DEFAULT 1,              -- 낙관적 잠금
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  search_tsv tsvector GENERATED ALWAYS AS
  (to_tsvector('simple', coalesce(title, '') || ' ' || coalesce(body, ''))) STORED,
  CHECK (status <> 'deleted' OR body IS null),
  CHECK (kind = 'note' OR jsonb_array_length(source_refs) > 0)  -- note 외에는 출처 필수
);

CREATE INDEX memory_store_status_idx ON memory (store_id, status);
CREATE INDEX memory_search_idx ON memory USING gin (search_tsv);
CREATE INDEX memory_sources_idx ON memory USING gin (source_refs jsonb_path_ops);  -- 역방향 계보 조회
CREATE INDEX memory_hash_idx ON memory (store_id, content_hash);

-- 삭제된 내용 재유입 방지 (정리 작업·재제안이 되살리지 못하게)
CREATE TABLE deleted_hash (
  store_id uuid NOT NULL REFERENCES store (id),
  content_hash text NOT NULL,
  deleted_at timestamptz NOT NULL DEFAULT now(),
  reason text NOT NULL,
  PRIMARY KEY (store_id, content_hash)
);

-- append-only 버전 기록 = 감사 로그
CREATE TYPE memory_op AS ENUM ('propose', 'approve', 'reject', 'edit', 'supersede', 'expire', 'delete', 'redact');

CREATE TABLE memory_version (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  memory_id uuid NOT NULL REFERENCES memory (id),
  version integer NOT NULL,
  op memory_op NOT NULL,
  actor_id uuid NOT NULL REFERENCES principal (id),
  snapshot jsonb,          -- 당시 title/body/meta. redact·delete 시 NULL
  reason text,
  at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (memory_id, version, op)
);

-- 리뷰 기록 (사람 승인 / 리뷰 에이전트 주석)
CREATE TABLE review (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  memory_id uuid NOT NULL REFERENCES memory (id),
  reviewer_id uuid NOT NULL REFERENCES principal (id),
  verdict text NOT NULL CHECK (verdict IN ('approve', 'reject', 'comment')),
  note text,
  at timestamptz NOT NULL DEFAULT now()
);

-- 버전/리뷰 테이블은 수정·삭제 금지. 예외: memory_version.snapshot 을 NULL 로 만드는 redact 만 허용
-- (snapshot 을 뺀 모든 컬럼이 동일해야 함. 컬럼이 추가돼도 자동으로 비교 대상에 포함)
CREATE FUNCTION forbid_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION '% is append-only', TG_TABLE_NAME; END IF;
  IF TG_TABLE_NAME <> 'memory_version' THEN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
  END IF;
  IF NOT (OLD.snapshot IS NOT NULL AND NEW.snapshot IS NULL
          AND to_jsonb(OLD) - 'snapshot' = to_jsonb(NEW) - 'snapshot') THEN
    RAISE EXCEPTION 'memory_version: only redaction (snapshot -> NULL) allowed';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER memory_version_append_only BEFORE UPDATE OR DELETE ON memory_version
FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER review_append_only BEFORE UPDATE OR DELETE ON review
FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- ── 권한: 실효 권한 = 사용자 권한 ∩ 에이전트 권한 ──────────
-- 앱이 트랜잭션마다 SET LOCAL app.user_id / app.agent_id 를 인증 토큰에서 설정. 모델은 관여 불가.
-- fail-closed: 미설정·빈 문자열은 NULL (오류도, 권한도 아님)
CREATE FUNCTION app_user() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('app.user_id', true), '')::uuid
$$;
CREATE FUNCTION app_agent() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('app.agent_id', true), '')::uuid
$$;

-- 비활성 principal(사용자/에이전트)과 비활성 그룹은 아무 권한도 주지 않는다
CREATE FUNCTION principal_closure(p uuid) RETURNS SETOF uuid LANGUAGE sql STABLE AS $$
  SELECT id FROM principal WHERE id = p AND active
  UNION
  SELECT gm.group_id FROM group_member gm
    JOIN principal g ON g.id = gm.group_id AND g.active
   WHERE gm.member_id = p
     AND EXISTS (SELECT 1 FROM principal u WHERE u.id = p AND u.active)
$$;

CREATE FUNCTION store_role_of(p uuid, s uuid) RETURNS store_role LANGUAGE sql STABLE AS $$
  SELECT max(role) FROM store_grant WHERE store_id = s AND principal_id IN (SELECT principal_closure(p))
$$;

-- least() 는 NULL 을 무시하므로 한쪽이 무권한이면 반대쪽이 이겨버린다 → 명시적으로 NULL 처리
CREATE FUNCTION effective_role(s uuid) RETURNS store_role LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN app_agent() IS NULL THEN store_role_of(app_user(), s)
    WHEN store_role_of(app_user(), s) IS NULL OR store_role_of(app_agent(), s) IS NULL THEN NULL
    ELSE least(store_role_of(app_user(), s), store_role_of(app_agent(), s))
  END
$$;

ALTER TABLE memory ENABLE ROW LEVEL SECURITY;

-- 읽기: reader 이상. proposed 는 작성자·curator만, deleted/rejected 는 curator만
CREATE POLICY memory_read ON memory FOR SELECT USING (
  effective_role(store_id) IS NOT null AND (
    status IN ('active', 'superseded', 'expired')
    OR (status = 'proposed' AND (
      created_by::text = current_setting('app.agent_id', true)
      OR created_by::text = current_setting('app.user_id', true)
      OR effective_role(store_id) = 'curator'
    ))
    OR effective_role(store_id) = 'curator'
  )
);

-- 제안: contributor 이상, 반드시 proposed 로만 생성 (user store auto_approve 는 서비스 계층에서 승격)
-- 작성자 바인딩: 에이전트면 created_by=에이전트, on_behalf_of=사용자 / 아니면 created_by=사용자, on_behalf_of=NULL
CREATE POLICY memory_propose ON memory FOR INSERT WITH CHECK (
  effective_role(store_id) >= 'contributor' AND status = 'proposed'
  AND created_by = coalesce(app_agent(), app_user())
  AND on_behalf_of IS NOT DISTINCT FROM (CASE WHEN app_agent() IS NOT null THEN app_user() END)
  AND tenant_id = (
    SELECT tenant_id FROM store
    WHERE id = store_id
  )
);

-- 상태 변경(승인/대체/삭제): curator 만
CREATE POLICY memory_curate ON memory FOR UPDATE USING (effective_role(store_id) = 'curator');


-- ── 버전/리뷰: 부모 memory 가 보일 때만 보인다 (EXISTS 안에서 memory 의 RLS 가 그대로 적용됨) ──
ALTER TABLE memory_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE review ENABLE ROW LEVEL SECURITY;

CREATE POLICY memory_version_read ON memory_version FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM memory AS m
    WHERE m.id = memory_version.memory_id
  )
);
-- 기록: 부모 memory 에 contributor 이상, actor 는 호출 주체 본인
CREATE POLICY memory_version_write ON memory_version FOR INSERT WITH CHECK (
  actor_id = coalesce(app_agent(), app_user())
  AND EXISTS (
    SELECT 1 FROM memory AS m
    WHERE m.id = memory_version.memory_id AND effective_role(m.store_id) >= 'contributor'
  )
);
-- redact(snapshot -> NULL): curator 만 (컬럼 권한 + 트리거가 snapshot 외 변경을 막음)
CREATE POLICY memory_version_redact ON memory_version FOR UPDATE USING (
  EXISTS (
    SELECT 1 FROM memory AS m
    WHERE m.id = memory_version.memory_id AND effective_role(m.store_id) = 'curator'
  )
);

CREATE POLICY review_read ON review FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM memory AS m
    WHERE m.id = review.memory_id
  )
);
-- comment: contributor 이상 / approve·reject: curator
CREATE POLICY review_write ON review FOR INSERT WITH CHECK (
  reviewer_id = coalesce(app_agent(), app_user())
  AND EXISTS (
    SELECT 1
    FROM memory AS m
    WHERE
      m.id = review.memory_id
      AND effective_role(m.store_id) >= CASE
        WHEN review.verdict = 'comment' THEN 'contributor'::store_role
        ELSE 'curator'::store_role
      END
  )
);

-- ── 앱 접속 역할: 최소 권한 (RLS 우회·스스로 권한 부여 불가) ──────
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') THEN CREATE ROLE app_rw NOLOGIN; END IF;
END $$;
GRANT USAGE ON SCHEMA public TO app_rw;
-- 주체/권한 테이블은 읽기 전용 (SCIM 동기화·관리 작업은 별도 역할)
GRANT SELECT ON tenant, principal, group_member, store, store_grant TO app_rw;
GRANT SELECT, INSERT, UPDATE ON memory TO app_rw;
GRANT SELECT, INSERT ON memory_version TO app_rw;
GRANT UPDATE (snapshot) ON memory_version TO app_rw;   -- redact 전용
GRANT SELECT, INSERT ON review, deleted_hash TO app_rw;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_rw;
