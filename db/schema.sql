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

-- pg_trgm 의 연산자 함수도 이 기본값 아래에서 만들어진다(마이그레이션 0009 와 같은 상태).
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;

-- ── 앱 접속 역할: LOGIN NOBYPASSRLS NOINHERIT (클러스터 전역 역할이라 이미 있으면 속성을 맞춘다) ──
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') THEN
    CREATE ROLE app_rw LOGIN NOBYPASSRLS NOINHERIT;
  ELSE
    ALTER ROLE app_rw LOGIN NOBYPASSRLS NOINHERIT;
  END IF;
END $$;

-- ── 워커 접속 역할: 기본은 NOLOGIN. 로그인 비밀번호는 배포(compose seed)가 ALTER ROLE 로 건다. 표 권한은 없고 아래 두 함수의 EXECUTE 뿐이다 ──
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nunchi_worker') THEN
    CREATE ROLE nunchi_worker NOLOGIN NOBYPASSRLS NOINHERIT;
  ELSE
    ALTER ROLE nunchi_worker NOBYPASSRLS NOINHERIT;
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
  archived_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  confidential boolean NOT NULL DEFAULT false,  -- 기밀 store 의 승인 카드는 제목 대신 id 만 싣는다 (카드는 U6b)
  UNIQUE (tenant_id, slug),
  UNIQUE (tenant_id, id)                  -- 복합 FK 대상 (테넌트 경계)
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

-- ── 주제(entity): 기억의 키 (subject, attribute) 의 subject ──────────
-- "A사", "에이사", "A Corp" 는 별칭이고 한 entity 를 가리킨다. 별칭은 테넌트 안에서 유일하다.
CREATE TABLE entity (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenant (id),
  kind text NOT NULL,
  canonical_name text NOT NULL,
  UNIQUE (tenant_id, id)
);
CREATE TABLE entity_alias (
  tenant_id uuid NOT NULL,
  entity_id uuid NOT NULL,
  alias_norm text NOT NULL,   -- app_sec.norm_text() 결과. 트리거가 정규화한다
  PRIMARY KEY (tenant_id, alias_norm),
  CONSTRAINT alias_entity_same_tenant FOREIGN KEY (tenant_id, entity_id) REFERENCES entity (tenant_id, id)
);

-- ── 메모리 ───────────────────────────────────────────────
CREATE TYPE memory_kind AS ENUM ('fact', 'decision', 'procedure', 'note');
-- provisional = 검토 전에 이미 노출된 상태. 불리언이 아니라 상태다 (전이 표가 허용하는 길만 있다)
CREATE TYPE memory_status AS ENUM ('proposed', 'provisional', 'active', 'superseded', 'rejected', 'expired', 'deleted');
-- 위험 등급: risk_tier() 가 정하고 approval_tier_rule 이 등급마다 최초 상태와 승인 정족수를 정한다
CREATE TYPE approval_tier AS ENUM ('auto', 'auto_labeled', 'one_curator', 'two_curators');
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
  tier approval_tier NOT NULL DEFAULT 'one_curator',  -- 요청 컨텍스트가 있는 INSERT 에서 risk_tier() 가 정한다. 이후 불변
  conflict_with uuid REFERENCES memory (id),            -- 같은 키의 살아있는 행 (서버 결정: memory_bi2k_key)
  subject_id uuid,                                      -- 키 = (subject_id, attribute). note 는 키가 없다
  attribute text,                                       -- app_sec.norm_text() 로 정규화 (트리거)
  last_confirmed_at timestamptz NOT NULL DEFAULT now(), -- 생성, 같은 값 재수집(reconfirm), curator 확인 때 갱신
  CONSTRAINT memory_subject_same_tenant FOREIGN KEY (tenant_id, subject_id) REFERENCES entity (tenant_id, id),
  CONSTRAINT memory_key_by_kind CHECK (
    CASE
      WHEN kind = 'note' THEN subject_id IS null AND attribute IS null
      ELSE subject_id IS NOT null AND attribute IS NOT null
    END
  ),
  CONSTRAINT memory_store_same_tenant FOREIGN KEY (tenant_id, store_id) REFERENCES store (tenant_id, id),
  CHECK (status <> 'deleted' OR body IS null),
  CHECK (kind = 'note' OR jsonb_array_length(source_refs) > 0)  -- note 외에는 출처 필수
);

CREATE INDEX memory_store_status_idx ON memory (store_id, status);
CREATE INDEX memory_search_idx ON memory USING gin ((title || ' ' || coalesce(body, '')) gin_trgm_ops);
CREATE INDEX memory_sources_idx ON memory USING gin (source_refs jsonb_path_ops);  -- 역방향 계보 조회
CREATE INDEX memory_hash_idx ON memory (store_id, content_hash);
-- 한 스토어 안에서 키마다 살아 있는 기억은 최대 하나다. 교체는 decide() 가 이전 행을 먼저 superseded 로 바꾼 뒤 새 행을 활성화한다
CREATE UNIQUE INDEX memory_live_key_uidx ON memory (store_id, subject_id, attribute)
WHERE status IN ('active', 'provisional');

-- 삭제된 내용 재유입 방지 (정리 작업·재제안이 되살리지 못하게)
CREATE TABLE deleted_hash (
  store_id uuid NOT NULL REFERENCES store (id),
  content_hash text NOT NULL,
  deleted_at timestamptz NOT NULL DEFAULT now(),
  reason text NOT NULL,
  PRIMARY KEY (store_id, content_hash)
);

-- append-only 버전 기록 = 감사 로그
CREATE TYPE memory_op AS ENUM (
  'propose', 'auto_activate', 'approve', 'confirm', 'reject', 'retract',
  'edit', 'supersede', 'expire', 'delete', 'redact', 'reconfirm'
);

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

-- 승인 카드: nonce 1개 = (memory, 수신 curator) 1장. 클릭은 nonce 로만 들어오고 decide() 만 읽고 쓴다 (app_rw 권한 없음).
CREATE TABLE approval_card (
  nonce uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  memory_id uuid NOT NULL REFERENCES memory (id),
  version_at_issue integer NOT NULL,
  issued_to uuid NOT NULL REFERENCES principal (id),
  platform text NOT NULL,
  channel_id text,
  message_ts text,
  issued_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT now() + interval '14 days',
  consumed_at timestamptz,
  outcome text
);

-- 리뷰 기록 (사람 승인 / 리뷰 에이전트 주석)
CREATE TABLE review (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  memory_id uuid NOT NULL REFERENCES memory (id),
  reviewer_id uuid NOT NULL REFERENCES principal (id),
  verdict text NOT NULL CHECK (verdict IN ('approve', 'reject', 'comment', 'confirm', 'retract')),
  note text,
  at timestamptz NOT NULL DEFAULT now(),
  via_agent_id uuid REFERENCES principal (id),
  card_nonce uuid REFERENCES approval_card (nonce),
  version integer NOT NULL
);

-- 상태 기계: 허용되는 (from, to) 전이는 이 표가 전부다. memory_bu 는 이 표를 한 번 조회할 뿐 분기하지 않는다.
-- op = 그 전이가 버전 기록에 남기는 op, by_role = curator(요청 컨텍스트의 사용자) 또는 system(컨텍스트 없는 워커/소유자),
-- reviewed = 전이마다 review 행(verdict = op)이 정족수만큼 있어야 하는가 (정족수와 직무 분리는 memory_bu 가 본다)
CREATE TYPE transition_role AS ENUM ('curator', 'system');
CREATE TABLE memory_transition (
  from_status memory_status NOT NULL,
  to_status memory_status NOT NULL,
  op memory_op NOT NULL,
  by_role transition_role NOT NULL,
  reviewed boolean NOT NULL DEFAULT false,
  PRIMARY KEY (from_status, to_status)
);
INSERT INTO memory_transition (from_status, to_status, op, by_role, reviewed) VALUES
('proposed', 'provisional', 'auto_activate', 'system', false),
('proposed', 'active', 'approve', 'curator', true),
('proposed', 'rejected', 'reject', 'curator', true),
('provisional', 'active', 'confirm', 'curator', true),
('provisional', 'rejected', 'retract', 'curator', true),
('provisional', 'superseded', 'supersede', 'curator', false),
('provisional', 'deleted', 'delete', 'curator', false),
('active', 'superseded', 'supersede', 'curator', false),
('active', 'expired', 'expire', 'system', false),
('active', 'deleted', 'delete', 'curator', false),
('superseded', 'deleted', 'delete', 'curator', false),
('expired', 'deleted', 'delete', 'curator', false),
('rejected', 'deleted', 'delete', 'curator', false);

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

-- 등급 -> 최초 상태와 승인 정족수. INSERT 정책, 등급 트리거, 버전 기록이 모두 이 표 하나를 본다.
CREATE TABLE approval_tier_rule (
  tier approval_tier PRIMARY KEY,
  initial_status memory_status NOT NULL,
  approvals_needed integer NOT NULL
);
INSERT INTO approval_tier_rule (tier, initial_status, approvals_needed) VALUES
('auto', 'active', 0),
('auto_labeled', 'provisional', 1),
('one_curator', 'proposed', 1),
('two_curators', 'proposed', 2);

-- 제안자 신뢰: (저자, store) 별 점수. risk_tier() 가 읽고, memory_aw 가 trust_rule 표대로 갱신한다.
CREATE TABLE proposer_trust (
  principal_id uuid NOT NULL REFERENCES principal (id),
  store_id uuid NOT NULL REFERENCES store (id),
  points integer NOT NULL DEFAULT 0,
  approved integer NOT NULL DEFAULT 0,
  rejected integer NOT NULL DEFAULT 0,
  retracted integer NOT NULL DEFAULT 0,
  demoted_until timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (principal_id, store_id)
);

-- 비대칭 점수: 승인/확인 +1, 반려 -5, 회수 -10 (이미 노출된 것이라 반려의 두 배) + 30일 강등. 전이의 op 마다 한 행이다.
CREATE TABLE trust_rule (
  op memory_op PRIMARY KEY,
  points integer NOT NULL,
  approved integer NOT NULL,
  rejected integer NOT NULL,
  retracted integer NOT NULL,
  demote_days integer NOT NULL
);
INSERT INTO trust_rule (op, points, approved, rejected, retracted, demote_days) VALUES
('approve', 1, 1, 0, 0, 0),
('confirm', 1, 1, 0, 0, 0),
('reject', -5, 0, 1, 0, 0),
('retract', -10, 0, 0, 1, 30);

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
-- tenant: ctx_tenant() 의 행 하나.
ALTER TABLE principal ENABLE ROW LEVEL SECURITY;
ALTER TABLE principal FORCE ROW LEVEL SECURITY;
ALTER TABLE group_member ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_member FORCE ROW LEVEL SECURITY;
ALTER TABLE store ENABLE ROW LEVEL SECURITY;
ALTER TABLE store FORCE ROW LEVEL SECURITY;
ALTER TABLE store_grant ENABLE ROW LEVEL SECURITY;
ALTER TABLE store_grant FORCE ROW LEVEL SECURITY;
ALTER TABLE tenant ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant FORCE ROW LEVEL SECURITY;

-- tenant: 호출자 자신의 테넌트 한 행만 보인다. 컨텍스트가 없으면 0행이다 (다른 테넌트의 존재와 이름을 알 수 없다).
CREATE POLICY tenant_read ON tenant FOR SELECT USING (id = app_sec.ctx_tenant());

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

ALTER TABLE entity ENABLE ROW LEVEL SECURITY;
ALTER TABLE entity FORCE ROW LEVEL SECURITY;
CREATE POLICY entity_read ON entity FOR SELECT USING (tenant_id = app_sec.ctx_tenant());
ALTER TABLE entity_alias ENABLE ROW LEVEL SECURITY;
ALTER TABLE entity_alias FORCE ROW LEVEL SECURITY;
CREATE POLICY entity_alias_read ON entity_alias FOR SELECT USING (tenant_id = app_sec.ctx_tenant());

ALTER TABLE memory ENABLE ROW LEVEL SECURITY;
ALTER TABLE memory FORCE ROW LEVEL SECURITY;

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

-- ── Slack 신원 · 방 바인딩 · 출처 분류 (설계서 3.2) ───────────────────
-- 데이터 모양: principal_identity 는 (platform, platform_user_id) -> principal 한 줄짜리 표이고, room_binding 은
-- (바인딩 -> store) 에 승인 두 칸(bound_by, confirmed_by)이 붙은 상태 표다: confirmed_by 가 NULL 이면 보류, 채워지면 활성, revoked_at 이면 종료.
-- 활성인 바인딩만 제안의 출처로 인정되고 origin 과 containment 는 거기서 서버가 정한다 (source_facts).
-- 이 표들은 app_rw 가 쓰지 못한다. 쓰는 쪽은 관리 API(소유자 역할) 하나이고, 관리자 여부는 그 API 가 확인한다.
-- DB 가 지키는 것은 bound_by 와 confirmed_by 가 다른 사람이고 confirmed_by 가 그 store 의 curator 라는 점이다.
CREATE TYPE link_quality AS ENUM ('scim', 'email');
CREATE TYPE room_kind AS ENUM ('public', 'private', 'connect');

-- SCIM 으로 이은 Slack user.id 만 decide() 의 신원이 된다. 이메일만 맞는 사용자는 'email' 품질이라 resolve_identity 가 NULL 을 준다.
CREATE TABLE principal_identity (
  platform text NOT NULL,
  platform_user_id text NOT NULL,
  tenant_id uuid NOT NULL,
  principal_id uuid NOT NULL,
  link_quality link_quality NOT NULL,
  linked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (platform, platform_user_id),
  CONSTRAINT identity_principal_same_tenant
  FOREIGN KEY (tenant_id, principal_id) REFERENCES principal (tenant_id, id) ON DELETE CASCADE
);

-- DM 과 mpim 은 kind 에 없고 (enum), Slack 의 채널 id 는 C 로 시작하는 것만 받는다 (DM 은 D, mpim 은 G).
CREATE TABLE room_binding (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  platform text NOT NULL,
  workspace_id text NOT NULL,
  channel_id text NOT NULL,
  kind room_kind NOT NULL,
  store_id uuid NOT NULL,
  bound_by uuid NOT NULL,
  bound_at timestamptz NOT NULL DEFAULT now(),
  confirmed_by uuid,
  confirmed_at timestamptz,
  revoked_at timestamptz,
  CONSTRAINT binding_store_same_tenant FOREIGN KEY (tenant_id, store_id) REFERENCES store (tenant_id, id),
  CONSTRAINT binding_bound_by_same_tenant FOREIGN KEY (tenant_id, bound_by) REFERENCES principal (tenant_id, id),
  CONSTRAINT binding_confirmed_by_same_tenant
  FOREIGN KEY (tenant_id, confirmed_by) REFERENCES principal (tenant_id, id),
  CONSTRAINT binding_two_people CHECK (confirmed_by IS null OR confirmed_by <> bound_by),
  CONSTRAINT binding_confirm_pair CHECK ((confirmed_by IS null) = (confirmed_at IS null)),
  CONSTRAINT binding_slack_channel_only CHECK (platform <> 'slack' OR channel_id ~ '^C[A-Z0-9]+$')
);
CREATE UNIQUE INDEX room_binding_live_idx ON room_binding (platform, workspace_id, channel_id) WHERE revoked_at IS null;

-- conversations.members + users.info 스냅샷. is_external = 다른 workspace 사용자 또는 stranger/restricted.
CREATE TABLE room_member (
  tenant_id uuid NOT NULL REFERENCES tenant (id),
  platform text NOT NULL,
  workspace_id text NOT NULL,
  channel_id text NOT NULL,
  platform_user_id text NOT NULL,
  is_external boolean NOT NULL DEFAULT false,
  synced_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (platform, workspace_id, channel_id, platform_user_id)
);

-- 출처 시스템 등록. host_pattern 은 소문자 host 와 비교하는 패턴이고 * 가 와일드카드다. authority 는 U9a 게이트가 쓴다.
CREATE TABLE source_system (
  tenant_id uuid NOT NULL REFERENCES tenant (id),
  system text NOT NULL,
  host_pattern text NOT NULL,
  authority integer NOT NULL DEFAULT 1,
  is_internal boolean NOT NULL,
  PRIMARY KEY (tenant_id, host_pattern)
);

ALTER TABLE principal_identity ENABLE ROW LEVEL SECURITY;
ALTER TABLE principal_identity FORCE ROW LEVEL SECURITY;
ALTER TABLE room_binding ENABLE ROW LEVEL SECURITY;
ALTER TABLE room_binding FORCE ROW LEVEL SECURITY;
ALTER TABLE room_member ENABLE ROW LEVEL SECURITY;
ALTER TABLE room_member FORCE ROW LEVEL SECURITY;
ALTER TABLE source_system ENABLE ROW LEVEL SECURITY;
ALTER TABLE source_system FORCE ROW LEVEL SECURITY;
-- Slack user id 와 방 구성원은 앱이 직접 읽지 않는다 (정책 없음 = 소유자 밖은 0행). 바인딩은 그 store 의 reader 에게 보인다.
CREATE POLICY room_binding_read ON room_binding FOR SELECT USING (
  tenant_id = app_sec.ctx_tenant() AND store_id IN (SELECT app_sec.my_stores('reader'))
);
CREATE POLICY source_system_read ON source_system FOR SELECT USING (tenant_id = app_sec.ctx_tenant());

-- 바인딩 규칙: 확인자는 그 store 의 현재 curator 이고 구성원 스냅샷이 있어야 한다 (멤버십을 못 읽는 방은 바인딩할 수 없다 = fail-closed).
-- 한 번 확인되면 확인자·대상은 바뀌지 않고, kind 는 connect 로만 올릴 수 있고, 종료는 되돌리지 못한다.
CREATE FUNCTION app_sec.room_binding_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF (NEW.tenant_id, NEW.platform, NEW.workspace_id, NEW.channel_id, NEW.store_id, NEW.bound_by, NEW.bound_at)
       IS DISTINCT FROM (OLD.tenant_id, OLD.platform, OLD.workspace_id, OLD.channel_id, OLD.store_id, OLD.bound_by, OLD.bound_at)
       OR (OLD.confirmed_by IS NOT NULL AND (NEW.confirmed_by, NEW.confirmed_at) IS DISTINCT FROM (OLD.confirmed_by, OLD.confirmed_at))
       OR (OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at)
       OR (NEW.kind <> OLD.kind AND NEW.kind <> 'connect') THEN
      RAISE EXCEPTION 'room_binding: this change is not allowed' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  IF NEW.confirmed_by IS NOT NULL AND (TG_OP = 'INSERT' OR OLD.confirmed_by IS NULL) THEN
    IF NOT EXISTS (
      SELECT 1 FROM store_grant AS g
      WHERE g.store_id = NEW.store_id AND g.role = 'curator' AND g.principal_id IN (SELECT app_sec.closure(NEW.confirmed_by))
    ) THEN
      RAISE EXCEPTION 'room_binding: confirmer is not a curator of the store' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM room_member AS m
      WHERE m.platform = NEW.platform AND m.workspace_id = NEW.workspace_id AND m.channel_id = NEW.channel_id
    ) THEN
      RAISE EXCEPTION 'room_binding: no membership snapshot for the room' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER room_binding_guard BEFORE INSERT OR UPDATE ON room_binding
FOR EACH ROW EXECUTE FUNCTION app_sec.room_binding_guard();

-- Slack user.id -> principal. SCIM 으로 이은 활성 사용자만 돌려주고 그 밖에는 NULL 이다 (begin_request 이전, 컨텍스트 없이 쓴다).
CREATE FUNCTION app_sec.resolve_identity(p_tenant uuid, p_platform text, p_platform_user_id text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT p.id FROM principal_identity AS i
  INNER JOIN principal AS p ON p.id = i.principal_id AND p.tenant_id = i.tenant_id
  WHERE i.tenant_id = p_tenant AND i.platform = p_platform AND i.platform_user_id = p_platform_user_id
    AND i.link_quality = 'scim' AND p.kind = 'user' AND p.active
$$;

-- 청중 포함 (설계서 3.2): store 의 사람 reader(직접 grant + 그룹, 에이전트 제외) 중 방 구성원으로 매핑되지 않는 수,
-- 외부 구성원 수, 스냅샷 나이(가장 오래된 행). 스냅샷이 없거나 90분보다 오래됐거나 빠진 reader 가 있으면 ok = false (fail-closed).
CREATE FUNCTION app_sec.room_containment(p_binding uuid)
RETURNS TABLE (ok boolean, missing_readers integer, external_members integer, snapshot_age interval)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  WITH b AS (SELECT * FROM room_binding WHERE id = p_binding),
  mem AS (
    SELECT m.platform_user_id, m.is_external, m.synced_at FROM room_member AS m, b
    WHERE m.platform = b.platform AND m.workspace_id = b.workspace_id AND m.channel_id = b.channel_id
  ),
  stats AS (
    SELECT
      (
        SELECT count(*)::integer FROM principal AS u, b
        WHERE u.tenant_id = b.tenant_id AND u.kind = 'user' AND u.active
          AND EXISTS (SELECT 1 FROM store_grant AS g WHERE g.store_id = b.store_id AND g.principal_id IN (SELECT app_sec.closure(u.id)))
          AND NOT EXISTS (
            SELECT 1 FROM principal_identity AS i
            WHERE i.platform = b.platform AND i.principal_id = u.id AND i.platform_user_id IN (SELECT platform_user_id FROM mem)
          )
      ) AS missing,
      (SELECT count(*)::integer FROM mem WHERE is_external) AS ext,
      (SELECT now() - min(synced_at) FROM mem) AS age
  )
  SELECT coalesce(s.age <= interval '90 minutes' AND s.missing = 0, false), s.missing, s.ext, s.age FROM stats AS s, b
$$;

-- 제안의 출처에서 서버가 정하는 값. origin 은 클라이언트가 올리기만 할 수 있고 내릴 수 없다.
--  - slack 방 출처(system = 'slack' + workspace_id + channel_id): 이 store 에 활성 바인딩이 없으면 23503.
--    Slack Connect 이거나 외부 구성원이 있는 방이면 origin = external. containment 는 room_containment 의 결과다.
--  - 그 밖의 출처 host: 이 테넌트에 source_system 이 등록돼 있는데 is_internal 인 패턴에 맞지 않으면 origin = external.
--    등록이 하나도 없는 테넌트는 host 분류를 아직 설정하지 않은 것으로 보고 host 규칙을 적용하지 않는다.
-- containment 는 방 출처가 있을 때만 'ok' / 'unverified' 를 돌려주고 없으면 NULL 이다.
CREATE FUNCTION app_sec.source_facts(m memory, OUT p_origin memory_origin, OUT p_containment text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  x jsonb;
  b room_binding;
  c record;
  host text;
BEGIN
  p_origin := m.origin;
  FOR x IN SELECT e FROM jsonb_array_elements(m.source_refs) AS e LOOP
    IF x ->> 'uri' LIKE 'memory://%' THEN
      CONTINUE;
    END IF;
    IF x ->> 'system' = 'slack' AND x ? 'workspace_id' AND x ? 'channel_id' THEN
      SELECT * INTO b FROM room_binding AS r
      WHERE r.tenant_id = m.tenant_id AND r.platform = 'slack' AND r.workspace_id = x ->> 'workspace_id' AND r.channel_id = x ->> 'channel_id'
        AND r.store_id = m.store_id AND r.confirmed_by IS NOT NULL AND r.revoked_at IS NULL;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'room is not bound to this store' USING ERRCODE = '23503';
      END IF;
      SELECT * INTO c FROM app_sec.room_containment(b.id);
      IF b.kind = 'connect' OR c.external_members > 0 THEN
        p_origin := 'external';
      END IF;
      p_containment := CASE WHEN c.ok AND p_containment IS DISTINCT FROM 'unverified' THEN 'ok' ELSE 'unverified' END;
    ELSE
      host := lower(substring(x ->> 'uri' FROM '^[A-Za-z][A-Za-z0-9+.-]*://(?:[^/?#@]*@)?([^/?#:]+)'));
      IF host IS NOT NULL
         AND EXISTS (SELECT 1 FROM source_system AS s WHERE s.tenant_id = m.tenant_id)
         AND NOT EXISTS (
           SELECT 1 FROM source_system AS s
           WHERE s.tenant_id = m.tenant_id AND s.is_internal
             AND host LIKE replace(replace(lower(s.host_pattern), '_', '\_'), '*', '%')
         ) THEN
        p_origin := 'external';
      END IF;
    END IF;
  END LOOP;
END $$;

-- 키 정규화: 소문자, 앞뒤 공백 제거, 연속 공백 하나로
CREATE FUNCTION app_sec.norm_text(t text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT lower(btrim(regexp_replace(t, '\s+', ' ', 'g')))
$$;
CREATE FUNCTION app_sec.alias_before_write() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  NEW.alias_norm := app_sec.norm_text(NEW.alias_norm);
  RETURN NEW;
END $$;
CREATE TRIGGER entity_alias_norm BEFORE INSERT OR UPDATE ON entity_alias
FOR EACH ROW EXECUTE FUNCTION app_sec.alias_before_write();
-- entity 해석 1단계: 별칭 정확 일치. 호출자의 RLS 가 적용되어 자기 테넌트의 별칭만 본다 (유사도 후보는 U5 밖)
CREATE FUNCTION app_sec.resolve_entity(p_name text) RETURNS uuid
LANGUAGE sql STABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT a.entity_id FROM entity_alias AS a WHERE a.alias_norm = app_sec.norm_text(p_name)
$$;
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

-- 위험 등급 (설계서 2.1). 입력은 모두 서버/DB 가 정한 값이고 위에서부터 첫 일치 행이 등급이다.
-- 1행(게이트 reject = 제안 거부)은 게이트의 몫이라 여기 없다. 신뢰 20점이 기준이고 점수 갱신은 proposer_trust 가 한다.
-- gate_result.containment 가 없으면 방 근거가 없는 출처로 보고 확인된 것으로 취급한다 (방 테이블은 U6). 있는데 ok 가 아니면 9행이다.
CREATE FUNCTION app_sec.risk_tier(m memory) RETURNS approval_tier
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  WITH f AS (
    SELECT
      s.kind AS store_kind,
      m.supersedes_id IS NOT NULL AS supersedes,
      t.kind = 'decision' AS target_is_decision,
      EXISTS (
        SELECT 1 FROM store_grant AS g
        WHERE g.store_id = t.store_id AND g.role = 'curator'
          AND g.principal_id IN (SELECT app_sec.closure(coalesce(t.on_behalf_of, t.created_by)))
      ) AS target_by_curator,
      coalesce(substring(m.gate_result ->> 'authority' FROM '^[0-9]{1,4}$')::int, 1) AS authority,
      coalesce(substring(t.gate_result ->> 'authority' FROM '^[0-9]{1,4}$')::int, 1) AS target_authority,
      CASE
        WHEN NOT (m.gate_result ? 'flags') THEN false
        WHEN jsonb_typeof(m.gate_result -> 'flags') = 'array' THEN jsonb_array_length(m.gate_result -> 'flags') > 0
        ELSE true
      END AS flagged,
      m.gate_result ? 'containment' AND (m.gate_result ->> 'containment') IS DISTINCT FROM 'ok' AS containment_unverified,
      coalesce(pt.demoted_until > now(), false) AS demoted,
      au.kind AS author_kind,
      coalesce(pt.points, 0) AS trust_points,
      20 AS trust_threshold
    FROM store AS s
    LEFT JOIN memory AS t ON t.id = m.supersedes_id
    LEFT JOIN proposer_trust AS pt ON pt.principal_id = m.created_by AND pt.store_id = m.store_id
    LEFT JOIN principal AS au ON au.id = m.created_by
    WHERE s.id = m.store_id
  )

  SELECT (CASE
    WHEN f.store_kind = 'user' THEN 'auto'
    WHEN f.store_kind = 'org' OR m.kind = 'decision' THEN 'two_curators'
    WHEN f.supersedes AND (f.target_is_decision OR f.target_by_curator OR f.authority < f.target_authority) THEN 'two_curators'
    WHEN f.supersedes THEN 'one_curator'
    WHEN m.kind = 'procedure' THEN 'one_curator'
    WHEN m.origin = 'external' THEN 'one_curator'
    WHEN f.flagged THEN 'one_curator'
    WHEN m.conflict_with IS NOT NULL OR f.containment_unverified THEN 'one_curator'
    WHEN f.demoted THEN 'one_curator'
    WHEN f.author_kind = 'user' OR f.trust_points >= f.trust_threshold THEN 'auto_labeled'
    ELSE 'one_curator'
  END)::approval_tier FROM f
$$;

-- INSERT: 요청 컨텍스트가 있으면 저자·대리·tenant 를 세션에 묶고(NULL 은 채우고, 다르면 42501),
-- version 을 1 로 고정한다 (tier 와 status 는 memory_bi3_tier 가 정한다). 컨텍스트가 없는 소유자 적재는 값을 그대로 둔다.
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
    NEW.version := 1;
  END IF;

  -- 존재하지 않음과 읽을 수 없음은 같은 오류다 (존재 오라클 차단). 호출자의 RLS 가 그대로 적용된다
  IF NEW.supersedes_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM memory AS m
    WHERE m.id = NEW.supersedes_id AND m.store_id = NEW.store_id AND m.status IN ('active', 'provisional')
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
    -- 외부 오염은 보수적으로 전파한다: 근거가 external 이거나 user store 이거나 아직 검토 전(provisional)이면 파생도 external
    IF EXISTS (
      SELECT 1 FROM memory AS m
      INNER JOIN store AS s ON s.id = m.store_id
      WHERE m.id = src AND (m.origin = 'external' OR m.status = 'provisional' OR s.kind = 'user')
    ) THEN
      NEW.origin := 'external';
    END IF;
  END LOOP;
  RETURN NEW;
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

-- UPDATE: 불변 컬럼, origin 단방향, memory_transition 표, 본문 편집 범위, 버전 증가, 삭제 시 본문 제거
CREATE FUNCTION app_sec.memory_before_update() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  tr memory_transition;
  q record;
BEGIN
  IF (NEW.id, NEW.tenant_id, NEW.store_id, NEW.kind, NEW.created_by, NEW.on_behalf_of, NEW.created_at, NEW.session_ref, NEW.tier)
     IS DISTINCT FROM
     (OLD.id, OLD.tenant_id, OLD.store_id, OLD.kind, OLD.created_by, OLD.on_behalf_of, OLD.created_at, OLD.session_ref, OLD.tier) THEN
    RAISE EXCEPTION 'immutable column changed';
  END IF;
  IF (NEW.subject_id, NEW.attribute) IS DISTINCT FROM (OLD.subject_id, OLD.attribute) THEN
    IF OLD.status <> 'proposed' THEN
      RAISE EXCEPTION 'immutable column changed';
    END IF;
    -- 별개로 저장: curator 가 제안의 키를 고치면 충돌 대상을 새 키로 다시 찾는다
    NEW.attribute := app_sec.norm_text(NEW.attribute);
    SELECT m.id INTO NEW.conflict_with FROM memory AS m
    WHERE m.store_id = OLD.store_id AND m.subject_id = NEW.subject_id AND m.attribute = NEW.attribute
      AND m.status IN ('active', 'provisional');
    NEW.supersedes_id := NEW.conflict_with;
  END IF;
  IF NEW.status = 'active' AND OLD.status <> 'active' THEN
    NEW.last_confirmed_at := now();
  END IF;
  IF OLD.origin = 'external' AND NEW.origin = 'internal' THEN
    RAISE EXCEPTION 'origin cannot be laundered to internal';
  END IF;
  IF NEW.status <> OLD.status THEN
    SELECT * INTO tr FROM memory_transition AS t WHERE t.from_status = OLD.status AND t.to_status = NEW.status;
    IF NOT found THEN
      RAISE EXCEPTION 'illegal transition % -> %', OLD.status, NEW.status;
    END IF;
    IF (tr.by_role = 'curator') <> (app_sec.ctx_user() IS NOT NULL) THEN
      RAISE EXCEPTION 'transition % -> % is for the % role', OLD.status, NEW.status, tr.by_role USING ERRCODE = '42501';
    END IF;
    IF tr.reviewed THEN
      IF app_sec.ctx_user() IN (OLD.created_by, coalesce(OLD.on_behalf_of, OLD.created_by)) THEN
        RAISE EXCEPTION 'separation of duties: the proposer cannot review' USING ERRCODE = '42501';
      END IF;
      SELECT * INTO q FROM app_sec.quorum(OLD, NEW.status);
      IF q.have < q.needed THEN
        RAISE EXCEPTION 'quorum not met: % of % reviews', q.have, q.needed USING ERRCODE = '42501';
      END IF;
    END IF;
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

-- 등급과 최초 상태는 서버가 정한다: 클라이언트가 보낸 tier, status 는 요청 컨텍스트가 있으면 덮어쓴다.
-- risk_tier 는 app_rw 가 부를 수 없으므로 소유자 권한 트리거가 대신 부른다. 이름 순서상 memory_bi, memory_bi2_hash 다음에 돈다.
CREATE FUNCTION app_sec.memory_set_tier() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE cont text;
BEGIN
  IF app_sec.ctx_user() IS NOT NULL THEN
    -- origin 과 containment 는 출처에서 서버가 정한다. 클라이언트 값은 올리는 쪽으로만 반영된다 (내릴 수 없다).
    SELECT f.p_origin, f.p_containment INTO NEW.origin, cont FROM app_sec.source_facts(NEW) AS f;
    IF jsonb_typeof(NEW.gate_result) <> 'object' THEN
      NEW.gate_result := '{}';
    END IF;
    cont := CASE
      WHEN cont = 'unverified' OR coalesce(NEW.gate_result ->> 'containment', 'ok') <> 'ok' THEN 'unverified'
      ELSE coalesce(cont, NEW.gate_result ->> 'containment')
    END;
    IF cont IS NOT NULL THEN
      NEW.gate_result := NEW.gate_result || jsonb_build_object('containment', cont);
    END IF;
    NEW.tier := app_sec.risk_tier(NEW);
    SELECT r.initial_status INTO NEW.status FROM approval_tier_rule AS r WHERE r.tier = NEW.tier;
  END IF;
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

-- 갱신 판정 (설계서 3). 소유자 권한이라 RLS 너머의 살아 있는 행을 보므로, 호출자가 그 store 의 contributor 일 때만 판정한다
-- (아니면 정책이 거절하게 둔다). memory_bi2_hash 가 content_hash 를 정한 뒤, memory_bi3_tier 가 등급을 정하기 전에 돈다.
-- conflict_with 는 클라이언트 값을 버리고 여기서만 정한다. 같은 키 + 같은 값이면 새 행 없이 이전 행을 reconfirm 한다 (RETURN NULL).
CREATE FUNCTION app_sec.memory_key_decide() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  live memory;
BEGIN
  IF NEW.attribute IS NOT NULL THEN
    NEW.attribute := app_sec.norm_text(NEW.attribute);
  END IF;
  IF app_sec.ctx_user() IS NULL THEN
    RETURN NEW;
  END IF;
  NEW.conflict_with := NULL;
  IF NEW.subject_id IS NULL OR NEW.attribute IS NULL OR NEW.store_id NOT IN (SELECT app_sec.my_stores('contributor')) THEN
    RETURN NEW;
  END IF;
  SELECT * INTO live FROM memory AS m
  WHERE m.store_id = NEW.store_id AND m.tenant_id = NEW.tenant_id AND m.subject_id = NEW.subject_id
    AND m.attribute = NEW.attribute AND m.status IN ('active', 'provisional')
  FOR UPDATE;
  IF NOT found THEN
    RETURN NEW;
  END IF;
  IF NEW.content_hash IS NOT NULL AND NEW.content_hash = live.content_hash THEN
    UPDATE memory SET last_confirmed_at = now() WHERE id = live.id;
    RETURN NULL;
  END IF;
  NEW.conflict_with := live.id;
  NEW.supersedes_id := live.id;
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
  v_op memory_op;
  actor uuid := coalesce(app_sec.ctx_user(), app_sec.ctx_agent(), NEW.created_by);
  why text := current_setting('app.reason', true);
BEGIN
  v_op := CASE
    WHEN TG_OP = 'INSERT' THEN 'propose'
    WHEN NEW.status = OLD.status AND NEW.last_confirmed_at IS DISTINCT FROM OLD.last_confirmed_at
      AND (NEW.title, NEW.body, NEW.source_refs) IS NOT DISTINCT FROM (OLD.title, OLD.body, OLD.source_refs) THEN 'reconfirm'
    WHEN NEW.status = OLD.status THEN 'edit'
    ELSE (SELECT t.op FROM memory_transition AS t WHERE t.from_status = OLD.status AND t.to_status = NEW.status)
  END;
  PERFORM app_sec.write_version(NEW, v_op, actor, why);
  -- 제안자 신뢰는 전이의 op 마다 trust_rule 한 행으로 갱신한다 (규칙이 없는 op 는 아무 행도 만들지 않는다)
  INSERT INTO proposer_trust AS pt (principal_id, store_id, points, approved, rejected, retracted, demoted_until)
  SELECT
    NEW.created_by, NEW.store_id, r.points, r.approved, r.rejected, r.retracted,
    CASE WHEN r.demote_days > 0 THEN now() + make_interval(days => r.demote_days) END
  FROM trust_rule AS r WHERE r.op = v_op
  ON CONFLICT (principal_id, store_id) DO UPDATE SET
    points = pt.points + excluded.points,
    approved = pt.approved + excluded.approved,
    rejected = pt.rejected + excluded.rejected,
    retracted = pt.retracted + excluded.retracted,
    demoted_until = coalesce(excluded.demoted_until, pt.demoted_until),
    updated_at = now();
  IF TG_OP = 'INSERT' AND EXISTS (
    SELECT 1 FROM approval_tier_rule AS r
    WHERE r.tier = NEW.tier AND r.initial_status = NEW.status AND r.initial_status <> 'proposed'
  ) THEN
    PERFORM app_sec.write_version(NEW, 'auto_activate', actor, why);
  END IF;
  IF v_op = 'delete' THEN
    IF OLD.content_hash IS NOT NULL THEN
      INSERT INTO deleted_hash (store_id, content_hash, reason) VALUES (NEW.store_id, OLD.content_hash, coalesce(why, 'delete'))
      ON CONFLICT DO NOTHING;
    END IF;
    UPDATE memory_version SET snapshot = NULL WHERE memory_id = NEW.id AND snapshot IS NOT NULL;
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER memory_bi BEFORE INSERT ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_before_insert();
-- 리뷰가 판단한 memory 버전: 클라이언트 값은 무시하고 항상 잠긴 memory 행의 현재 version 으로 덮어쓴다.
-- 정족수는 현재 version 의 리뷰만 센다 (본문이 바뀌면 이전 승인은 기록에만 남는다).
CREATE FUNCTION app_sec.review_before_insert() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  SELECT m.version INTO NEW.version FROM memory AS m WHERE m.id = NEW.memory_id;
  RETURN NEW;
END $$;
CREATE TRIGGER review_bi BEFORE INSERT ON review FOR EACH ROW EXECUTE FUNCTION app_sec.review_before_insert();

CREATE TRIGGER memory_bu BEFORE UPDATE ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_before_update();
CREATE TRIGGER memory_bi2_hash BEFORE INSERT ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_set_hash();
CREATE TRIGGER memory_bi2k_key BEFORE INSERT ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_key_decide();
CREATE TRIGGER memory_bi3_tier BEFORE INSERT ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_set_tier();
CREATE TRIGGER memory_bu2_hash BEFORE UPDATE ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_set_hash();
CREATE TRIGGER memory_aw AFTER INSERT OR UPDATE ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_after_write();

-- 승인 함수: 카드 nonce 로만 승인/반려/의견. 멱등(소비된 nonce), 낙관적 잠금(expected_version), 클릭자 = 수신자.
-- 거절 사유는 위에서부터 첫 일치 하나만 반환하고 review 행도 버전도 남기지 않는다. 처리되면 review 를 쓰고 memory 를 UPDATE 하며
-- 정족수와 직무 분리의 최종 판정은 memory_bu 가 한다. verdict 는 approve/confirm(→ active), reject/retract(→ rejected), comment 이고
-- review 에는 현재 상태에서 그 전이의 op 로 기록한다 (proposed 의 approve 는 approve, provisional 의 approve 는 confirm).
CREATE FUNCTION app_sec.decide(
  p_nonce uuid, p_memory uuid, p_expected_version integer, p_verdict text, p_reason text DEFAULT null
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  me uuid := app_sec.ctx_user();
  c approval_card;
  m memory;
  tr memory_transition;
  q record;
  refusal text;
  target memory_status;
  v_outcome text;
  v_old uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'no user context' USING ERRCODE = '28000';
  END IF;
  IF p_verdict NOT IN ('approve', 'confirm', 'reject', 'retract', 'comment') THEN
    RAISE EXCEPTION 'unknown verdict %', p_verdict USING ERRCODE = '22023';
  END IF;
  SELECT * INTO c FROM approval_card WHERE nonce = p_nonce FOR UPDATE;
  SELECT * INTO m FROM memory WHERE id = c.memory_id FOR UPDATE;
  refusal := CASE
    WHEN c.nonce IS NULL THEN 'unknown_nonce'
    WHEN c.issued_to <> me THEN 'wrong_clicker'
    WHEN c.consumed_at IS NOT NULL THEN 'duplicate:' || c.outcome
    WHEN c.memory_id <> p_memory THEN 'mismatch'
    WHEN c.expires_at < now() THEN 'expired'
    WHEN NOT EXISTS (
      SELECT 1 FROM app_sec.my_store_roles() AS r WHERE r.store_id = m.store_id AND r.role = 'curator'
    ) THEN 'not_curator'
    WHEN m.version <> p_expected_version THEN 'stale'
    WHEN me IN (m.created_by, coalesce(m.on_behalf_of, m.created_by)) THEN 'self_review'
  END;
  IF refusal IS NOT NULL THEN
    RETURN refusal;
  END IF;

  target := CASE p_verdict WHEN 'approve' THEN 'active' WHEN 'confirm' THEN 'active' WHEN 'reject' THEN 'rejected' WHEN 'retract' THEN 'rejected' END;
  SELECT * INTO tr FROM memory_transition AS t WHERE t.from_status = m.status AND t.to_status = target;
  IF target IS NOT NULL AND NOT found THEN
    RAISE EXCEPTION 'illegal transition % -> %', m.status, target;
  END IF;
  INSERT INTO review (memory_id, reviewer_id, verdict, note, via_agent_id, card_nonce)
  VALUES (m.id, me, coalesce(tr.op::text, p_verdict), p_reason, app_sec.ctx_agent(), p_nonce);
  PERFORM set_config('app.reason', coalesce(p_reason, ''), true);

  v_outcome := CASE WHEN target IS NULL THEN 'comment' ELSE target::text END;
  IF target IS NOT NULL THEN
    SELECT * INTO q FROM app_sec.quorum(m, target);
    IF q.have < q.needed THEN
      v_outcome := 'pending_quorum:' || q.have || '/' || q.needed;
    ELSE
      -- 교체: 같은 키(또는 supersedes_id)의 살아 있는 행을 먼저 superseded 로 바꾼 뒤 새 행을 활성화한다 (한 트랜잭션, 지연 제약 없음)
      IF target = 'active' THEN
        UPDATE memory SET status = 'superseded', valid_to = coalesce(m.valid_from, current_date)
        WHERE id <> m.id AND status IN ('active', 'provisional')
          AND (id = m.supersedes_id OR (store_id = m.store_id AND subject_id = m.subject_id AND attribute = m.attribute))
        RETURNING id INTO v_old;
      END IF;
      UPDATE memory SET
        status = target,
        supersedes_id = coalesce(v_old, supersedes_id),
        valid_from = CASE WHEN v_old IS NULL THEN valid_from ELSE coalesce(valid_from, current_date) END
      WHERE id = m.id AND version = p_expected_version;
    END IF;
  END IF;
  UPDATE approval_card SET consumed_at = now(), outcome = v_outcome WHERE nonce = p_nonce;
  RETURN v_outcome;
END $$;

-- 승인 카드 발급: MCP 처럼 Slack 카드가 없는 경로에서 curator 가 직접 결정할 때 쓴다. 사람만(에이전트 문맥이면 거부), 그 기억이 속한 store 의 curator 만 받는다.
-- 이미 열린 카드가 있으면 새로 만들지 않고 그 nonce 를 돌려준다 (재시도에 안전). 결정의 나머지 검사(self_review, stale, 정족수)는 decide() 의 몫이다.
CREATE FUNCTION app_sec.issue_card(p_memory uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  me uuid := app_sec.ctx_user();
  m memory;
  v_nonce uuid;
BEGIN
  IF me IS NULL OR app_sec.ctx_agent() IS NOT NULL THEN
    RAISE EXCEPTION 'only a human principal may open an approval' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO m FROM memory WHERE id = p_memory;
  IF NOT found OR NOT EXISTS (
    SELECT 1 FROM app_sec.my_store_roles() AS r WHERE r.store_id = m.store_id AND r.role = 'curator'
  ) THEN
    RAISE EXCEPTION 'not a curator of this memory' USING ERRCODE = '42501';
  END IF;
  SELECT nonce INTO v_nonce FROM approval_card
  WHERE memory_id = m.id AND issued_to = me AND consumed_at IS NULL AND expires_at > now() AND version_at_issue = m.version;
  IF v_nonce IS NOT NULL THEN RETURN v_nonce; END IF;
  INSERT INTO approval_card (memory_id, version_at_issue, issued_to, platform)
  VALUES (m.id, m.version, me, 'mcp') RETURNING nonce INTO v_nonce;
  RETURN v_nonce;
END $$;

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
GRANT USAGE ON SCHEMA app_sec TO nunchi_worker;
GRANT EXECUTE ON FUNCTION app_sec.mark_expired() TO nunchi_worker;
GRANT EXECUTE ON FUNCTION app_sec.stale_memories(integer) TO nunchi_worker;

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

-- inbound_event: event_id 한 줄짜리 표. Slack 재전송은 같은 event_id 라 PK 가 멱등성을 준다. app_rw 는 claim_inbound_event 로만 쓴다.
CREATE TABLE inbound_event (
  event_id text PRIMARY KEY,
  received_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE inbound_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE inbound_event FORCE ROW LEVEL SECURITY;

-- 처음 보는 event_id 면 true, 이미 있으면 false. 요청 트랜잭션이 롤백되면 적재도 취소되어 재전송이 다시 처리된다.
CREATE FUNCTION app_sec.claim_inbound_event(p_event_id text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  n integer;
BEGIN
  IF app_sec.ctx_user() IS NULL THEN
    RAISE EXCEPTION 'no user context' USING ERRCODE = '28000';
  END IF;
  INSERT INTO inbound_event (event_id) VALUES (p_event_id) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n = 1;
END $$;

-- Slack 승인 카드: 제안자가 부르면 SCIM 으로 이어진 curator(제안자 제외)마다 카드를 1장 만들고 새 (nonce, Slack id) 만 돌려준다. 열린 카드는 건너뛴다.
CREATE FUNCTION app_sec.issue_slack_cards(p_memory uuid) RETURNS TABLE (card_nonce uuid, slack_user_id text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  me uuid := app_sec.ctx_user();
  m memory;
BEGIN
  IF me IS NULL OR app_sec.ctx_agent() IS NOT NULL THEN
    RAISE EXCEPTION 'only a human principal may open approvals' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO m FROM memory WHERE id = p_memory;
  IF NOT found OR m.status <> 'proposed' OR me NOT IN (m.created_by, coalesce(m.on_behalf_of, m.created_by)) THEN
    RAISE EXCEPTION 'not the proposer of a proposed memory' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  WITH curators AS (
    SELECT i.principal_id, i.platform_user_id FROM principal_identity AS i
    INNER JOIN principal AS u ON u.id = i.principal_id AND u.tenant_id = i.tenant_id
    WHERE i.platform = 'slack' AND i.link_quality = 'scim' AND i.tenant_id = m.tenant_id
      AND u.kind = 'user' AND u.active AND u.id NOT IN (m.created_by, coalesce(m.on_behalf_of, m.created_by))
      AND EXISTS (SELECT 1 FROM store_grant AS g WHERE g.store_id = m.store_id AND g.role = 'curator' AND g.principal_id IN (SELECT app_sec.closure(u.id)))
  ),
  ins AS (
    INSERT INTO approval_card (memory_id, version_at_issue, issued_to, platform)
    SELECT m.id, m.version, c.principal_id, 'slack' FROM curators AS c
    WHERE NOT EXISTS (
      SELECT 1 FROM approval_card AS a
      WHERE a.memory_id = m.id AND a.issued_to = c.principal_id AND a.version_at_issue = m.version
        AND a.consumed_at IS NULL AND a.expires_at > now()
    )
    RETURNING approval_card.nonce, approval_card.issued_to
  )
  SELECT ins.nonce, c.platform_user_id FROM ins INNER JOIN curators AS c ON c.principal_id = ins.issued_to;
END $$;

-- ── 앱 접속 역할 최소 권한 (RLS 우회·스스로 권한 부여 불가) ──
GRANT USAGE ON SCHEMA public TO app_rw;
-- 주체/권한/감사 테이블은 읽기 전용이다. 버전은 memory 트리거, 삭제 해시는 삭제 트리거, 권한과 주체는 별도 관리 역할이 쓴다
GRANT SELECT ON tenant, group_member, store, store_grant, memory_transition, approval_tier_rule TO app_rw;
GRANT SELECT ON entity, entity_alias TO app_rw;
-- principal.external_id(IdP subject, SCIM id)는 숨긴다: 컬럼 단위 GRANT 에서 뺀다. SELECT * 는 42501 이다.
-- 필요한 조회는 SECURITY DEFINER 함수(app_sec.resolve_principal)로 낸다.
GRANT SELECT (id, tenant_id, kind, display_name, active) ON principal TO app_rw;
GRANT SELECT ON memory_version, review, deleted_hash, room_binding, source_system TO app_rw;
GRANT SELECT, INSERT, UPDATE ON memory TO app_rw;

-- 함수 실행 권한은 허용 목록뿐이다. 내부 함수(write_version, content_hmac, is_deleted_content, 트리거 함수)는
-- SECURITY DEFINER 트리거와 소유자만 부른다. 정책이 호출자 권한으로 평가하는 ctx_*, my_stores 와 그 하위
-- my_store_roles, principal_closure 는 app_rw 에 줘야 한다.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app_sec FROM public, app_rw;
REVOKE ALL ON FUNCTION principal_closure(uuid), forbid_mutation() FROM public, app_rw;
GRANT EXECUTE ON FUNCTION app_sec.begin_request(uuid, uuid) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.resolve_principal(uuid, principal_kind, text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.resolve_identity(uuid, text, text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.ctx_user() TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.ctx_agent() TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.ctx_tenant() TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.decide(uuid, uuid, integer, text, text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.issue_card(uuid) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.claim_inbound_event(text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.issue_slack_cards(uuid) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.quorum(memory, memory_status) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.my_store_roles() TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.my_stores(store_role) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.search(text, uuid[], memory_status[], memory_kind[]) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.verify_chain(uuid) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.norm_text(text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.resolve_entity(text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.create_entity(text, text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.memory_as_of(uuid, uuid, text, date) TO app_rw;
GRANT EXECUTE ON FUNCTION principal_closure(uuid) TO app_rw;
