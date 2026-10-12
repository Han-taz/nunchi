-- Team Memory Core — schema v1 (PostgreSQL 16+)
-- 원칙: store = 권한 경계, 변경은 append-only 버전, 범위는 인증 컨텍스트가 주입
--       (app_sec.begin_request 가 principal 을 검증하고 트랜잭션 xid 에 바인딩)
--
-- 역할 분리
--   테이블·함수 소유자: 이 파일을 적재하는 역할 (운영에서는 NOLOGIN 인 app_owner. SECURITY DEFINER 함수가
--                       RLS 를 우회해야 하므로 superuser 이거나 BYPASSRLS 여야 한다).
--   앱 접속 역할 app_rw: LOGIN NOBYPASSRLS NOINHERIT. 아무것도 소유하지 않고, 아래 GRANT 만 가진다.
--                       비밀번호는 배포 때 ALTER ROLE 로 설정한다 (이 파일에는 두지 않는다).
--   smoke_test.sql 의 SET ROLE app_rw 는 테스트 전용 패턴이다. 앱은 app_rw 로 직접 접속해야 한다.
--                       superuser 로 접속해 SET ROLE 하면 SQL 인젝션 한 번이 RESET ROLE 로 이어진다.
--
-- 신뢰 경계 (v1.1 에서 받아들인 한계)
--   app_rw 는 한 트랜잭션 안에서 set_config 로 app.user_id / app.agent_id / app.tenant_id / app.ctx_xid 를 직접 쓸 수 있다.
--   즉 app_rw 가 탈취되면 컨텍스트를 위조할 수 있다. begin_request 는 실수와 풀러 누수를 막을 뿐 탈취된 앱은 막지 못한다.
--   app_rw can forge context inside a transaction; DB-side token verification is P1 (fable report §6.2).
--
-- 함수 보안
--   모든 함수는 SET search_path = pg_catalog, public, pg_temp 로 고정한다. pg_temp 를 빼면 임시 스키마가 관계(테이블)
--   조회에서 가장 먼저 검색되어, app_rw 의 CREATE TEMP TABLE store_grant 가 SECURITY DEFINER 함수까지 가로챈다.
--   TEMPORARY 권한도 PUBLIC 에서 회수한다 (아래). 이 규칙은 db-test.sh 의 lint(S1)가 강제한다.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 이 파일을 적재하는 역할이 앞으로 만드는 모든 함수는 PUBLIC 실행 권한 없이 태어난다.
-- 스키마별 default 로는 전역 기본값(PUBLIC 실행)을 지울 수 없어서 스키마를 지정하지 않는다.
-- 앱이 부를 수 있는 함수는 파일 끝의 명시적 GRANT EXECUTE 목록이 전부다 (P3 이 목록을 테스트로 고정한다).
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM public;

-- ── 앱 접속 역할: LOGIN NOBYPASSRLS NOINHERIT (클러스터 전역 역할이라 이미 있으면 속성을 맞춘다) ──
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') THEN
    CREATE ROLE app_rw LOGIN NOBYPASSRLS NOINHERIT;
  ELSE
    ALTER ROLE app_rw LOGIN NOBYPASSRLS NOINHERIT;
  END IF;
END $$;

-- 임시 테이블로 관계 조회를 가로채는 길을 닫는다. 기본 권한은 PUBLIC 에 있어서 app_rw 한 명만 회수해서는 효과가 없다.
-- 이 데이터베이스의 모든 역할에서 회수한다. 임시 테이블이 필요한 관리 작업은 소유자(superuser)로 하거나 따로 GRANT 한다.
DO $$ BEGIN
  EXECUTE format('REVOKE TEMPORARY ON DATABASE %I FROM PUBLIC, app_rw', current_database());
END $$;

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
  UNIQUE (tenant_id, kind, external_id),
  UNIQUE (tenant_id, id)                  -- 복합 FK 대상 (테넌트 경계)
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
  UNIQUE (tenant_id, id),                 -- 복합 FK 대상 (테넌트 경계)
  CHECK (auto_approve = false OR kind = 'user')
);

CREATE TYPE store_role AS ENUM ('reader', 'contributor', 'curator');
-- reader: 읽기 / contributor: 읽기+제안 / curator: 승인·대체·삭제

-- tenant_id 는 store 와 principal 이 같은 테넌트임을 복합 FK 두 개로 강제한다
CREATE TABLE store_grant (
  store_id uuid NOT NULL,
  principal_id uuid NOT NULL,  -- user/group/agent
  role store_role NOT NULL,
  tenant_id uuid NOT NULL,
  PRIMARY KEY (store_id, principal_id),
  CONSTRAINT grant_store_same_tenant
  FOREIGN KEY (tenant_id, store_id) REFERENCES store (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT grant_principal_same_tenant
  FOREIGN KEY (tenant_id, principal_id) REFERENCES principal (tenant_id, id) ON DELETE CASCADE
);
CREATE INDEX store_grant_principal_idx ON store_grant (principal_id);
CREATE INDEX group_member_member_idx ON group_member (member_id);

-- ── 메모리 ───────────────────────────────────────────────
CREATE TYPE memory_kind AS ENUM ('fact', 'decision', 'procedure', 'note');
CREATE TYPE memory_status AS ENUM ('proposed', 'active', 'superseded', 'rejected', 'expired', 'deleted');
CREATE TYPE memory_origin AS ENUM ('internal', 'external');

CREATE TABLE memory (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenant (id),
  store_id uuid NOT NULL,
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
  content_hash text,                                    -- HMAC(정규화 본문). 서버(트리거)가 계산, 클라이언트 값 무시
  version integer NOT NULL DEFAULT 1,              -- 낙관적 잠금
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  search_tsv tsvector GENERATED ALWAYS AS
  (to_tsvector('simple', coalesce(title, '') || ' ' || coalesce(body, ''))) STORED,
  CONSTRAINT memory_store_same_tenant FOREIGN KEY (tenant_id, store_id) REFERENCES store (tenant_id, id),
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
  snapshot_hash text,      -- sha256(snapshot). snapshot 이 redact 돼도 남아 체인 검증이 유지된다
  prev_hash text,          -- 같은 memory 의 직전 row_hash
  row_hash text,           -- sha256(prev_hash | memory | version | op | actor | snapshot_hash | at | reason)
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

-- 상태 기계: 허용되는 (from, to) 전이만 이 표에 있고 memory_bu 트리거는 이 표만 본다
CREATE TABLE memory_transition (
  from_status memory_status NOT NULL,
  to_status memory_status NOT NULL,
  PRIMARY KEY (from_status, to_status)
);
INSERT INTO memory_transition (from_status, to_status) VALUES
('proposed', 'active'), ('proposed', 'rejected'),
('active', 'superseded'), ('active', 'expired'), ('active', 'deleted'),
('superseded', 'deleted'), ('expired', 'deleted'), ('rejected', 'deleted');

-- 버전/리뷰 테이블은 수정·삭제 금지. 예외: memory_version.snapshot 을 NULL 로 만드는 redact 만 허용
-- (snapshot 을 뺀 모든 컬럼이 동일해야 함. 컬럼이 추가돼도 자동으로 비교 대상에 포함)
CREATE FUNCTION forbid_mutation() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$
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
-- 앱은 트랜잭션마다 app_sec.begin_request(user, agent) 를 부른다. 함수가 principal 의 종류·활성·테넌트를 검증하고
-- 값을 set_config(..., true) 로 설정한 뒤 현재 xid 에 묶는다. 세션 레벨 SET 이나 풀러 연결에 남은 값은 xid 가
-- 맞지 않아 읽히지 않는다 (fail-closed: 컨텍스트 없음 = NULL = 권한 없음).
CREATE SCHEMA app_sec;
GRANT USAGE ON SCHEMA app_sec TO app_rw;

CREATE FUNCTION app_sec.begin_request(p_user uuid, p_agent uuid DEFAULT null) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE t uuid;
BEGIN
  SELECT tenant_id INTO t FROM principal WHERE id = p_user AND kind = 'user' AND active;
  IF t IS NULL THEN RAISE EXCEPTION 'unknown or inactive user %', p_user USING ERRCODE = '28000'; END IF;
  IF p_agent IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM principal WHERE id = p_agent AND kind = 'agent' AND active AND tenant_id = t
  ) THEN
    RAISE EXCEPTION 'unknown or inactive agent %', p_agent USING ERRCODE = '28000';
  END IF;
  PERFORM set_config('app.user_id', p_user::text, true);
  PERFORM set_config('app.agent_id', coalesce(p_agent::text, ''), true);
  PERFORM set_config('app.tenant_id', t::text, true);
  PERFORM set_config('app.ctx_xid', pg_current_xact_id()::text, true);  -- primary 전용
END $$;

-- 토큰의 subject(발급 테넌트, 종류, external_id)를 principal id 로 바꾼다. begin_request 이전, 컨텍스트가 없는 시점에 쓴다.
-- principal.external_id 는 app_rw 에 열려 있지 않으므로(아래 컬럼 GRANT) 이 함수가 유일한 조회 경로다.
-- 활성 principal 만 돌려주고 그 밖에는 NULL 이다. 테넌트와 종류가 정확히 일치해야 한다.
CREATE FUNCTION app_sec.resolve_principal(p_issuer_tenant uuid, p_kind principal_kind, p_external_id text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT id FROM principal
  WHERE tenant_id = p_issuer_tenant AND kind = p_kind AND external_id = p_external_id AND active
$$;

CREATE FUNCTION app_sec.ctx_user() RETURNS uuid LANGUAGE sql STABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT CASE WHEN current_setting('app.ctx_xid', true) = pg_current_xact_id()::text
              THEN nullif(current_setting('app.user_id', true), '')::uuid END
$$;
CREATE FUNCTION app_sec.ctx_agent() RETURNS uuid LANGUAGE sql STABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT CASE WHEN current_setting('app.ctx_xid', true) = pg_current_xact_id()::text
              THEN nullif(current_setting('app.agent_id', true), '')::uuid END
$$;
CREATE FUNCTION app_sec.ctx_tenant() RETURNS uuid LANGUAGE sql
STABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT CASE WHEN current_setting('app.ctx_xid', true) = pg_current_xact_id()::text
              THEN nullif(current_setting('app.tenant_id', true), '')::uuid END
$$;

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
CREATE FUNCTION principal_closure(p uuid) RETURNS SETOF uuid LANGUAGE sql
STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT app_sec.closure(p)
  WHERE p IN (app_sec.ctx_user(), app_sec.ctx_agent())
$$;

-- 실효 권한 = (사용자 role) ∩ (에이전트 role). 에이전트가 있으면 양쪽 grant 가 모두 있어야 하고 낮은 쪽을 쓴다.
-- 정책에서 store_id IN (SELECT ... FROM my_store_roles()) 로 쓰면 행마다가 아니라 요청당 한 번 평가된다.
CREATE FUNCTION app_sec.my_store_roles() RETURNS TABLE (store_id uuid, role store_role)
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

-- 정책용: 최소 role 이상을 가진 store 집합
CREATE FUNCTION app_sec.my_stores(min_role store_role) RETURNS SETOF uuid LANGUAGE sql
STABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT store_id FROM app_sec.my_store_roles() WHERE role >= min_role
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

ALTER TABLE memory ENABLE ROW LEVEL SECURITY;
ALTER TABLE memory FORCE ROW LEVEL SECURITY;

-- 읽기: reader 이상. proposed 는 대리된 사용자 본인(에이전트 유무 무관) 또는 사람 작성자와 curator만,
-- deleted/rejected 는 curator만. 봇을 공유하는 다른 사용자는 남의 proposed 를 보지 못한다.
CREATE POLICY memory_read ON memory FOR SELECT USING (
  tenant_id = app_sec.ctx_tenant() AND (
    (
      status IN ('active', 'superseded', 'expired')
      AND store_id IN (SELECT app_sec.my_stores('reader'))
    )
    OR store_id IN (SELECT app_sec.my_stores('curator'))
    OR (
      status = 'proposed' AND coalesce(on_behalf_of, created_by) = app_sec.ctx_user()
      AND store_id IN (SELECT app_sec.my_stores('reader'))
    )
  )
);

-- 제안: contributor 이상, 반드시 proposed 로만 생성 (user store auto_approve 는 서비스 계층에서 승격)
-- 작성자 바인딩: 에이전트면 created_by=에이전트, on_behalf_of=사용자 / 아니면 created_by=사용자, on_behalf_of=NULL
CREATE POLICY memory_propose ON memory FOR INSERT WITH CHECK (
  status = 'proposed' AND version = 1
  AND tenant_id = app_sec.ctx_tenant()
  AND store_id IN (SELECT app_sec.my_stores('contributor'))
  AND created_by = coalesce(app_sec.ctx_agent(), app_sec.ctx_user())
  AND on_behalf_of IS NOT DISTINCT FROM (CASE WHEN app_sec.ctx_agent() IS NOT null THEN app_sec.ctx_user() END)
);

-- 상태 변경(승인/대체/삭제): curator 만
CREATE POLICY memory_curate ON memory FOR UPDATE
USING (
  tenant_id = app_sec.ctx_tenant()
  AND store_id IN (SELECT app_sec.my_stores('curator'))
)
WITH CHECK (
  tenant_id = app_sec.ctx_tenant()
  AND store_id IN (SELECT app_sec.my_stores('curator'))
);


-- ── 버전/리뷰: 부모 memory 가 보일 때만 보인다 (EXISTS 안에서 memory 의 RLS 가 그대로 적용됨) ──
ALTER TABLE memory_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE memory_version FORCE ROW LEVEL SECURITY;
ALTER TABLE review ENABLE ROW LEVEL SECURITY;
ALTER TABLE review FORCE ROW LEVEL SECURITY;

CREATE POLICY memory_version_read ON memory_version FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM memory AS m
    WHERE m.id = memory_version.memory_id
  )
);
-- 쓰기 정책은 없다: 버전은 memory 트리거(SECURITY DEFINER)만, review 는 승인 함수만 기록한다 (app_rw 에는 INSERT/UPDATE 권한도 없다)

CREATE POLICY review_read ON review FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM memory AS m
    WHERE m.id = review.memory_id
  )
);

-- 삭제된 내용의 해시: curator 만 읽는다 (재제안 차단 검사는 is_deleted_content 가 대신한다)
ALTER TABLE deleted_hash ENABLE ROW LEVEL SECURITY;
ALTER TABLE deleted_hash FORCE ROW LEVEL SECURITY;
CREATE POLICY deleted_hash_read ON deleted_hash FOR SELECT USING (
  store_id IN (SELECT app_sec.my_stores('curator'))
);

-- ── 쓰기 경로: 바인딩·해시·계보 검사·상태 기계·버전·감사는 전부 트리거가 한다 ──
-- 앱이 직접 쓰는 테이블은 memory 하나이고, 나머지(memory_version, deleted_hash)는 아래 SECURITY DEFINER 함수만 쓴다.

-- 내용 해시용 서버 비밀키. app_rw 는 이 표를 읽을 수 없다 (스키마 USAGE 만 있고 표 권한이 없다)
CREATE TABLE app_sec.secret (
  name text PRIMARY KEY,
  value bytea NOT NULL
);
INSERT INTO app_sec.secret (name, value) VALUES ('hash_key', gen_random_bytes(32));

-- 내용 해시 = HMAC(정규화 본문). 정규화 = 보이지 않는 문자 제거 -> NFKC -> 다시 제거 -> 공백류 접기 -> 소문자.
-- 보이지 않는 문자 = 일반 범주 Cf 전부 + Default_Ignorable_Code_Point + 공백이 아닌 Cc.
-- NFKC 앞뒤로 두 번 지우는 이유: CGJ(U+034F)나 ZWSP(U+200B)가 결합 문자 사이에 끼면 NFKC 가 합성하지 못한다.
-- 공백류 = 탭, 줄바꿈, NEL, Zs, 줄/문단 구분자. 모두 U+0020 한 칸으로 접는다.
-- Postgres 정규식에는 유니코드 속성 클래스가 없어 범위를 직접 적는다. 아래 블록은 고정된 UCD 파일에서
-- scripts/gen-unicode-ignorables.py 가 만든다 (CI 가 다시 만들어 diff). 평문 sha256 으로 삭제된 내용을 추측하는 오라클을 막는다
CREATE FUNCTION app_sec.strip_invisible(t text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public, pg_temp AS $$
  WITH p (re) AS (
    SELECT
    -- BEGIN generated by scripts/gen-unicode-ignorables.py (Unicode 18.0.0)
    '[\u0000-\u0008\u000e-\u001f\u007f-\u0084\u0086-\u009f\u00ad\u034f\u0600-\u0605\u061c\u06dd\u070f'
    || '\u0890-\u0891\u08e2\u115f-\u1160\u17b4-\u17b5\u180b-\u180f\u200b-\u200f\u202a-\u202e'
    || '\u2060-\u206f\u3164\ufe00-\ufe0f\ufeff\uffa0\ufff0-\ufffb\U000110bd\U000110cd'
    || '\U00013430-\U0001343f\U0001bca0-\U0001bca3\U0001d173-\U0001d17a\U000e0000-\U000e0fff]'
    -- END generated
  )
  SELECT regexp_replace(t, p.re, '', 'g') FROM p
$$;
CREATE FUNCTION app_sec.content_hmac(t text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT encode(
    hmac(
      convert_to(
        lower(btrim(regexp_replace(
          app_sec.strip_invisible(normalize(app_sec.strip_invisible(t), NFKC)),
          '[ \t\n\v\f\r\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+', ' ', 'g'
        ))),
        'UTF8'
      ),
      (SELECT value FROM app_sec.secret WHERE name = 'hash_key'),
      'sha256'
    ),
    'hex'
  )
$$;

-- 삭제 해시는 curator 만 읽으므로 contributor 의 재제안 검사는 이 함수가 대신한다
CREATE FUNCTION app_sec.is_deleted_content(s uuid, h text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM deleted_hash WHERE store_id = s AND content_hash = h)
$$;

-- INSERT: 요청 컨텍스트가 있으면 저자·대리·tenant 를 세션에 묶고(NULL 은 채우고, 다르면 42501),
-- status/version 을 제안 상태로 고정한다. 컨텍스트가 없는 소유자 적재는 값을 그대로 둔다.
-- 이 트리거는 호출자(app_rw) 권한으로 돈다: 정책과 RLS 가 그대로 적용된다. 내부 함수(content_hmac 등)는
-- app_rw 가 부를 수 없으므로 해시 계산은 SECURITY DEFINER 트리거 memory_bi2_hash / memory_bu2_hash 가 한다.
CREATE FUNCTION app_sec.memory_before_insert() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  by_whom uuid := coalesce(app_sec.ctx_agent(), app_sec.ctx_user());
  on_behalf uuid := CASE WHEN app_sec.ctx_agent() IS NULL THEN NULL ELSE app_sec.ctx_user() END;
  ref text;
  src uuid;
BEGIN
  IF app_sec.ctx_user() IS NOT NULL THEN
    NEW.created_by := coalesce(NEW.created_by, by_whom);
    NEW.tenant_id := coalesce(NEW.tenant_id, app_sec.ctx_tenant());
    IF NEW.created_by <> by_whom OR NEW.tenant_id <> app_sec.ctx_tenant()
       OR NEW.on_behalf_of IS DISTINCT FROM on_behalf THEN
      RAISE EXCEPTION 'author, delegate and tenant are bound to the request' USING ERRCODE = '42501';
    END IF;
    NEW.status := 'proposed';
    NEW.version := 1;
  END IF;

  -- 존재하지 않음과 읽을 수 없음은 같은 오류다 (존재 오라클 차단). 호출자의 RLS 가 그대로 적용된다
  IF NEW.supersedes_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM memory AS m
    WHERE m.id = NEW.supersedes_id AND m.store_id = NEW.store_id AND m.status = 'active'
  ) THEN
    RAISE EXCEPTION 'supersedes target not found' USING ERRCODE = '23503';
  END IF;

  FOR ref IN SELECT x ->> 'uri' FROM jsonb_array_elements(NEW.source_refs) AS x WHERE x ->> 'uri' LIKE 'memory://%' LOOP
    IF ref !~ '^memory://[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'source memory not found: %', ref USING ERRCODE = '23503';
    END IF;
    src := substr(ref, 10)::uuid;
    IF NOT EXISTS (SELECT 1 FROM memory AS m WHERE m.id = src) THEN
      RAISE EXCEPTION 'source memory not found: %', ref USING ERRCODE = '23503';
    END IF;
    -- 외부 오염은 보수적으로 전파한다: 근거 중 하나라도 external 이면 파생도 external
    IF EXISTS (SELECT 1 FROM memory AS m WHERE m.id = src AND m.origin = 'external') THEN
      NEW.origin := 'external';
    END IF;
  END LOOP;
  RETURN NEW;
END $$;

-- UPDATE: 불변 컬럼, origin 단방향, memory_transition 표, 본문 편집 범위, 버전 증가, 삭제 시 본문 제거
CREATE FUNCTION app_sec.memory_before_update() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF (NEW.id, NEW.tenant_id, NEW.store_id, NEW.kind, NEW.created_by, NEW.on_behalf_of, NEW.created_at, NEW.session_ref)
     IS DISTINCT FROM
     (OLD.id, OLD.tenant_id, OLD.store_id, OLD.kind, OLD.created_by, OLD.on_behalf_of, OLD.created_at, OLD.session_ref) THEN
    RAISE EXCEPTION 'immutable column changed';
  END IF;
  IF OLD.origin = 'external' AND NEW.origin = 'internal' THEN
    RAISE EXCEPTION 'origin cannot be laundered to internal';
  END IF;
  IF NEW.status <> OLD.status AND NOT EXISTS (
    SELECT 1 FROM memory_transition AS t WHERE t.from_status = OLD.status AND t.to_status = NEW.status
  ) THEN
    RAISE EXCEPTION 'illegal transition % -> %', OLD.status, NEW.status;
  END IF;
  IF (NEW.title, NEW.body, NEW.source_refs) IS DISTINCT FROM (OLD.title, OLD.body, OLD.source_refs)
     AND NOT (NEW.status = OLD.status AND OLD.status IN ('proposed', 'active')) AND NEW.status <> 'deleted' THEN
    RAISE EXCEPTION 'content edit not allowed in this transition';
  END IF;
  IF NEW.status = 'deleted' THEN
    NEW.body := NULL;
    NEW.title := '[deleted]';
  END IF;
  NEW.version := OLD.version + 1;
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- 내용 해시와 삭제 내용 재제안 검사. 소유자 권한으로 돌아 app_rw 가 content_hmac / is_deleted_content 를 직접 부르지 않아도 된다.
-- 트리거 이름 순서(memory_bi < memory_bi2_hash)로 memory_bi 가 본문을 확정한 뒤에 실행된다.
CREATE FUNCTION app_sec.memory_set_hash() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.content_hash := CASE WHEN NEW.body IS NULL THEN NULL ELSE app_sec.content_hmac(NEW.body) END;
    IF NEW.content_hash IS NOT NULL AND app_sec.is_deleted_content(NEW.store_id, NEW.content_hash) THEN
      RAISE EXCEPTION 'content was previously deleted in this store' USING ERRCODE = '23505';
    END IF;
  ELSE
    NEW.content_hash := CASE WHEN NEW.body IS NULL THEN OLD.content_hash ELSE app_sec.content_hmac(NEW.body) END;
  END IF;
  RETURN NEW;
END $$;

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

-- 쓰기 후: 버전 기록. 삭제면 삭제 해시를 등록하고 과거 snapshot 을 전부 redact 한다
CREATE FUNCTION app_sec.memory_after_write() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  op memory_op;
  actor uuid := coalesce(app_sec.ctx_user(), app_sec.ctx_agent(), NEW.created_by);
  why text := current_setting('app.reason', true);
BEGIN
  IF TG_OP = 'INSERT' THEN
    op := 'propose';
  ELSIF NEW.status <> OLD.status THEN
    op := CASE NEW.status
      WHEN 'active' THEN 'approve' WHEN 'rejected' THEN 'reject' WHEN 'superseded' THEN 'supersede'
      WHEN 'expired' THEN 'expire' WHEN 'deleted' THEN 'delete'
    END;
  ELSE
    op := 'edit';
  END IF;
  PERFORM app_sec.write_version(NEW, op, actor, why);
  IF op = 'delete' THEN
    IF OLD.content_hash IS NOT NULL THEN
      INSERT INTO deleted_hash (store_id, content_hash, reason) VALUES (NEW.store_id, OLD.content_hash, coalesce(why, 'delete'))
      ON CONFLICT DO NOTHING;
    END IF;
    UPDATE memory_version SET snapshot = NULL WHERE memory_id = NEW.id AND snapshot IS NOT NULL;
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER memory_bi BEFORE INSERT ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_before_insert();
CREATE TRIGGER memory_bu BEFORE UPDATE ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_before_update();
CREATE TRIGGER memory_bi2_hash BEFORE INSERT ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_set_hash();
CREATE TRIGGER memory_bu2_hash BEFORE UPDATE ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_set_hash();
CREATE TRIGGER memory_aw AFTER INSERT OR UPDATE ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_after_write();

-- 체인 검증. 호출자의 RLS 가 적용되므로 보이는 버전만 검증한다 (없거나 못 보면 NULL)
CREATE FUNCTION app_sec.verify_chain(p_mem uuid) RETURNS boolean LANGUAGE sql
STABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT bool_and(
    row_hash = encode(
      sha256(convert_to(concat_ws('|', prev_hash, memory_id, version, op, actor_id, snapshot_hash, extract(EPOCH FROM at), coalesce(reason, '')), 'UTF8')),
      'hex'
    )
    AND prev_hash IS NOT DISTINCT FROM expected_prev
  )
  FROM (
    SELECT v.*, lag(row_hash) OVER (ORDER BY id) AS expected_prev
    FROM memory_version AS v WHERE memory_id = p_mem
  ) AS x
$$;

-- ── 검색: RLS 아래에서는 @@ 가 non-LEAKPROOF 라 GIN 인덱스를 못 쓴다 (N10) ──
-- 인덱스를 쓰는 SECURITY DEFINER 함수로 제공하고, memory_read 정책과 같은 가시성 규칙을 my_stores() 로 직접 적용한다.
-- websearch_to_tsquery 비용은 항 수에 제곱으로 늘어난다(30k 항에 CPU 9.6초).
-- 1000자를 넘거나 tsquery 노드(항과 연산자)가 64개를 넘으면 22023 으로 거부한다.
-- 공백 분리 항 수는 NBSP·쉼표 구분을 못 세므로 노드 수로 센다.
-- 기본 status 는 active 만이다. 가시성 규칙이 정책과 어긋나지 않는지는 smoke_test 의 N10 이 사용자별로 비교한다.
-- 결과는 점수 순 50건까지. 본문은 돌려주지 않고 id 로 RLS 아래에서 다시 읽는다.
CREATE FUNCTION app_sec.search(
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

-- ── 앱 접속 역할 최소 권한 (RLS 우회·스스로 권한 부여 불가) ──
GRANT USAGE ON SCHEMA public TO app_rw;
-- 주체/권한/감사 테이블은 읽기 전용이다. 버전은 memory 트리거, 삭제 해시는 삭제 트리거, 권한과 주체는 별도 관리 역할이 쓴다
GRANT SELECT ON tenant, group_member, store, store_grant, memory_transition TO app_rw;
-- principal.external_id(IdP subject, SCIM id)는 숨긴다: 컬럼 단위 GRANT 에서 뺀다. SELECT * 는 42501 이다.
-- 필요한 조회는 SECURITY DEFINER 함수(app_sec.resolve_principal)로 낸다.
GRANT SELECT (id, tenant_id, kind, display_name, active) ON principal TO app_rw;
GRANT SELECT ON memory_version, review, deleted_hash TO app_rw;
GRANT SELECT, INSERT, UPDATE ON memory TO app_rw;

-- 함수 실행 권한은 허용 목록뿐이다. 내부 함수(write_version, content_hmac, is_deleted_content, 트리거 함수)는
-- SECURITY DEFINER 트리거와 소유자만 부른다. 정책이 호출자 권한으로 평가하는 ctx_*, my_stores 와 그 하위
-- my_store_roles, principal_closure 는 app_rw 에 줘야 한다.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app_sec FROM public, app_rw;
REVOKE ALL ON FUNCTION principal_closure(uuid), forbid_mutation() FROM public, app_rw;
GRANT EXECUTE ON FUNCTION app_sec.begin_request(uuid, uuid) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.resolve_principal(uuid, principal_kind, text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.ctx_user() TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.ctx_agent() TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.ctx_tenant() TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.my_store_roles() TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.my_stores(store_role) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.search(text, uuid[], memory_status[]) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.verify_chain(uuid) TO app_rw;
GRANT EXECUTE ON FUNCTION principal_closure(uuid) TO app_rw;
