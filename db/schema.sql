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
CREATE TYPE memory_status AS ENUM (
  'proposed', 'provisional', 'challenger', 'active', 'superseded', 'rejected', 'expired', 'deleted'
);
-- 현재 상태에 이른 근거 (v1.3 §3.1)
CREATE TYPE promotion_basis AS ENUM ('agreed', 'stated', 'timer', 'agent', 'user_store', 'migrated');
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
  conflict_with uuid REFERENCES memory (id),            -- 같은 키의 살아있는 행 (challenger 는 remember() 가 정한다)
  subject_id uuid,                                      -- 키 = (subject_id, attribute). note 는 키가 없다
  attribute text,                                       -- app_sec.norm_text() 로 정규화 (트리거)
  last_confirmed_at timestamptz NOT NULL DEFAULT now(), -- 생성, 같은 값 재수집(reconfirm), curator 확인 때 갱신
  value text,                                           -- 짧은 정규 답 (예: 이민수), norm_text() 로 정규화. NULL = 옛 행
  basis promotion_basis,                                -- 현재 상태에 이른 근거 (v1.3 §3.1)
  promote_at timestamptz,                               -- provisional 과 challenger 가 반박 없이 active 가 되는 시각. 그 외에는 null
  CONSTRAINT memory_subject_same_tenant FOREIGN KEY (tenant_id, subject_id) REFERENCES entity (tenant_id, id),
  CONSTRAINT memory_key_by_kind CHECK (
    CASE
      WHEN kind = 'note' THEN subject_id IS null AND attribute IS null
      ELSE subject_id IS NOT null AND attribute IS NOT null
    END
  ),
  CONSTRAINT memory_store_same_tenant FOREIGN KEY (tenant_id, store_id) REFERENCES store (tenant_id, id),
  CHECK (status <> 'deleted' OR body IS null),
  CONSTRAINT memory_promote_at_state CHECK (promote_at IS null OR status IN ('provisional', 'challenger')),
  CHECK (kind = 'note' OR jsonb_array_length(source_refs) > 0)  -- note 외에는 출처 필수
);

CREATE INDEX memory_store_status_idx ON memory (store_id, status);
CREATE INDEX memory_search_idx ON memory USING gin ((title || ' ' || coalesce(body, '')) gin_trgm_ops);
CREATE INDEX memory_sources_idx ON memory USING gin (source_refs jsonb_path_ops);  -- 역방향 계보 조회
CREATE INDEX memory_hash_idx ON memory (store_id, content_hash);
-- 한 스토어 안에서 키마다 살아 있는 기억은 최대 하나다. 교체는 이전 행을 먼저 superseded 로 바꾼 뒤 새 행을 활성화한다 (한 트랜잭션)
CREATE UNIQUE INDEX memory_live_key_uidx ON memory (store_id, subject_id, attribute)
WHERE status IN ('active', 'provisional');
-- 키마다 열린 변경 제안(challenger)은 하나다. 살아 있는 행과는 별개의 유일성이다
CREATE UNIQUE INDEX memory_challenger_uidx ON memory (store_id, subject_id, attribute)
WHERE status = 'challenger';

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
  'edit', 'supersede', 'expire', 'delete', 'redact', 'reconfirm', 'promote'
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

-- 승인 카드: nonce 1개 = (memory, 수신 curator) 1장. 읽고 쓰는 함수는 없다 (U38 이 지웠다). app_rw 권한 없음.
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

-- 상태 기계 (v1.3 §5.2): 허용되는 (from, to, op) 전이는 이 표가 전부다. memory_bu 는 이 표를 한 번 조회할 뿐 분기하지 않는다.
-- op = 전이를 일으키는 함수가 트랜잭션 로컬 설정 app.op 로 넘기는 값이고 버전 기록에도 그대로 남는다. app.op 없는 상태 UPDATE 는 42501.
-- by_roles = 이 전이를 할 수 있는 역할. 요청 컨텍스트가 있으면 contributor 와 curator, 없으면 system 으로 본다. curator 는 삭제에만 쓴다.
CREATE TYPE transition_role AS ENUM ('contributor', 'system', 'curator');
CREATE TABLE memory_transition (
  from_status memory_status NOT NULL,
  to_status memory_status NOT NULL,
  op memory_op NOT NULL,
  by_roles transition_role[] NOT NULL CHECK (cardinality(by_roles) > 0),
  PRIMARY KEY (from_status, to_status, op)
);
INSERT INTO memory_transition (from_status, to_status, op, by_roles) VALUES
('provisional', 'active', 'confirm', '{contributor}'),
('provisional', 'active', 'promote', '{system}'),
('provisional', 'rejected', 'retract', '{contributor}'),
('provisional', 'superseded', 'supersede', '{contributor,system}'),
('active', 'superseded', 'supersede', '{contributor,system}'),
('active', 'expired', 'retract', '{contributor}'),
('active', 'expired', 'expire', '{system}'),
('challenger', 'active', 'confirm', '{contributor}'),
('challenger', 'active', 'promote', '{system}'),
('challenger', 'rejected', 'retract', '{contributor}'),
('challenger', 'provisional', 'promote', '{contributor,system}'),
('active', 'deleted', 'delete', '{curator}'),
('provisional', 'deleted', 'delete', '{curator}'),
('challenger', 'deleted', 'delete', '{curator}'),
('superseded', 'deleted', 'delete', '{curator}'),
('expired', 'deleted', 'delete', '{curator}'),
('rejected', 'deleted', 'delete', '{curator}');

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
-- store 별 승격 기간 (v1.3 §3.1). 행이 없으면 24시간. 앱 롤에는 권한이 없다
CREATE TABLE store_autonomy (
  store_id uuid PRIMARY KEY REFERENCES store (id),
  promote_after interval NOT NULL DEFAULT '24 hours' CHECK (promote_after > interval '0')
);

-- 버전/리뷰 테이블은 수정·삭제 금지. 예외: memory_version.snapshot 을 NULL 로 만드는 redact 만 허용
-- (snapshot 을 뺀 모든 컬럼이 동일해야 함. 컬럼이 추가돼도 자동으로 비교 대상에 포함)
CREATE FUNCTION forbid_mutation() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION '% is append-only', TG_TABLE_NAME; END IF;
  IF TG_TABLE_NAME = 'memory_evidence' THEN
    IF NOT (OLD.author_name IS NOT NULL AND NEW.author_name IS NULL
            AND to_jsonb(OLD) - 'author_name' = to_jsonb(NEW) - 'author_name'
            AND EXISTS (SELECT 1 FROM memory AS m WHERE m.id = OLD.memory_id AND m.status = 'deleted')) THEN
      RAISE EXCEPTION 'memory_evidence is append-only (only the delete scrub of author_name is allowed)';
    END IF;
    RETURN NEW;
  END IF;
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
CREATE TRIGGER memory_evidence_append_only BEFORE UPDATE OR DELETE ON memory_evidence
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

-- 읽기: reader 이상. provisional 과 challenger 는 active 와 같이 reader 에게 보인다 (검토 전이라는 표시는 status 가 한다).
-- challenger(살아 있는 값과 다른 값의 제안)는 search 가 살아 있는 행에 pending_change 로 붙여 보여 주므로 reader 가 읽을 수 있어야 한다.
-- proposed 는 대리된 사용자 본인(에이전트 유무 무관) 또는 사람 작성자와 curator만,
-- deleted/rejected 는 curator만. 봇을 공유하는 다른 사용자는 남의 proposed 를 보지 못한다.
-- app_sec.search 의 vis 와 같은 가시성이다 (smoke_test 의 N10 이 사용자별로 비교한다).
CREATE POLICY memory_read ON memory FOR SELECT USING (
  tenant_id = app_sec.ctx_tenant() AND (
    (
      status IN ('active', 'provisional', 'challenger', 'superseded', 'expired')
      AND store_id IN (SELECT app_sec.my_stores('reader'))
    )
    OR store_id IN (SELECT app_sec.my_stores('curator'))
    OR (
      status = 'proposed' AND coalesce(on_behalf_of, created_by) = app_sec.ctx_user()
      AND store_id IN (SELECT app_sec.my_stores('reader'))
    )
  )
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
ALTER TABLE memory_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE memory_evidence FORCE ROW LEVEL SECURITY;
CREATE POLICY memory_evidence_read ON memory_evidence FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM memory AS m
    WHERE m.id = memory_evidence.memory_id
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

-- ── 쓰기 경로: 판정은 app_sec.remember() 가, 바인딩·해시·계보 검사·상태 기계·버전·감사는 트리거가 한다 ──
-- 앱은 memory 에 INSERT 할 수 없다. UPDATE 는 curator 의 상태 변경(삭제)과 remember() 가 부르는 내부 함수뿐이고, 나머지 표는 SECURITY DEFINER 함수만 쓴다.

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

-- SCIM 으로 이은 Slack user.id 만 신원이 된다. 이메일만 맞는 사용자는 'email' 품질이라 resolve_identity 가 NULL 을 준다.
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
-- Mattermost 채널 id 는 소문자 영숫자 26자다. 채널 종류(O/P 만 바인딩, D/G 는 불가)는 id 에 없으므로 봇이 channel.type 으로 거른다.
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
  digest_enabled boolean NOT NULL DEFAULT false,
  digest_cursor bigint NOT NULL DEFAULT 0,
  CONSTRAINT binding_store_same_tenant FOREIGN KEY (tenant_id, store_id) REFERENCES store (tenant_id, id),
  CONSTRAINT binding_bound_by_same_tenant FOREIGN KEY (tenant_id, bound_by) REFERENCES principal (tenant_id, id),
  CONSTRAINT binding_confirmed_by_same_tenant
  FOREIGN KEY (tenant_id, confirmed_by) REFERENCES principal (tenant_id, id),
  CONSTRAINT binding_two_people CHECK (confirmed_by IS null OR confirmed_by <> bound_by),
  CONSTRAINT binding_confirm_pair CHECK ((confirmed_by IS null) = (confirmed_at IS null)),
  CONSTRAINT binding_channel_id_by_platform CHECK (
    CASE platform
      WHEN 'slack' THEN channel_id ~ '^C[A-Z0-9]+$'
      WHEN 'mattermost' THEN channel_id ~ '^[a-z0-9]{26}$'
      ELSE true
    END
  )
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

-- 채널 다이제스트 (U23): 바인딩마다 켜고 끄는 스위치(digest_enabled)와 읽은 곳까지의 커서(digest_cursor, Mattermost create_at 밀리초).
-- app_rw 는 room_binding 에 쓰지 못하므로 아래 두 함수로만 바꾼다. 스위치는 그 store 의 curator 만, 커서는 contributor 이상(봇)만 만진다.
-- 켜는 순간 커서를 지금으로 맞춘다: 켜기 전 대화는 읽지 않는다 (비용 상한).
CREATE FUNCTION app_sec.set_digest(p_binding uuid, p_enabled boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF app_sec.ctx_user() IS NULL THEN
    RAISE EXCEPTION 'no user context' USING ERRCODE = '28000';
  END IF;
  UPDATE room_binding SET
    digest_enabled = p_enabled,
    digest_cursor = CASE WHEN p_enabled AND NOT digest_enabled
      THEN greatest(digest_cursor, (extract(epoch FROM clock_timestamp()) * 1000)::bigint) ELSE digest_cursor END
  WHERE id = p_binding AND tenant_id = app_sec.ctx_tenant() AND confirmed_by IS NOT NULL AND revoked_at IS NULL
    AND store_id IN (SELECT app_sec.my_stores('curator'));
  IF NOT found THEN
    RAISE EXCEPTION 'not a curator of a live binding' USING ERRCODE = '42501';
  END IF;
END $$;

-- 커서는 앞으로만 간다 (되돌리는 호출은 무시).
CREATE FUNCTION app_sec.advance_digest(p_binding uuid, p_cursor bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF app_sec.ctx_user() IS NULL THEN
    RAISE EXCEPTION 'no user context' USING ERRCODE = '28000';
  END IF;
  UPDATE room_binding SET digest_cursor = greatest(digest_cursor, p_cursor)
  WHERE id = p_binding AND tenant_id = app_sec.ctx_tenant() AND digest_enabled AND revoked_at IS NULL
    AND store_id IN (SELECT app_sec.my_stores('contributor'));
  IF NOT found THEN
    RAISE EXCEPTION 'not a contributor of an enabled binding' USING ERRCODE = '42501';
  END IF;
END $$;

-- 방 구성원 스냅샷 갱신 (U25): 봇이 Mattermost 채널 구성원을 읽어 통째로 바꿔 쓴다. 스냅샷이 90분보다 오래되면 containment 가 unverified 가 되므로 주기적으로 불러야 한다.
-- app_rw 는 room_member 에 접근하지 못하므로 이 함수로만 쓴다. 그 store 의 contributor 이상(봇)만, 살아 있는 바인딩에 대해서만 가능하다.
-- 빈 목록은 거절한다 (읽기 실패가 "아무도 없음"으로 저장되면 안 된다). 목록에 없는 행은 지우고 있는 행은 synced_at 을 지금으로 올린다.
CREATE FUNCTION app_sec.replace_room_members(p_binding uuid, p_members text[], p_external text[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  b room_binding;
BEGIN
  IF app_sec.ctx_user() IS NULL THEN
    RAISE EXCEPTION 'no user context' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO b FROM room_binding
  WHERE id = p_binding AND tenant_id = app_sec.ctx_tenant() AND revoked_at IS NULL
    AND store_id IN (SELECT app_sec.my_stores('contributor'));
  IF NOT found THEN
    RAISE EXCEPTION 'not a contributor of a live binding' USING ERRCODE = '42501';
  END IF;
  IF coalesce(cardinality(p_members), 0) = 0 THEN
    RAISE EXCEPTION 'empty member list' USING ERRCODE = '22023';
  END IF;
  DELETE FROM room_member
  WHERE platform = b.platform AND workspace_id = b.workspace_id AND channel_id = b.channel_id
    AND platform_user_id <> ALL (p_members);
  INSERT INTO room_member (tenant_id, platform, workspace_id, channel_id, platform_user_id, is_external, synced_at)
  SELECT b.tenant_id, b.platform, b.workspace_id, b.channel_id, u, u = ANY (coalesce(p_external, '{}')), now()
  FROM unnest(p_members) AS u
  ON CONFLICT (platform, workspace_id, channel_id, platform_user_id)
  DO UPDATE SET is_external = EXCLUDED.is_external, synced_at = EXCLUDED.synced_at;
END $$;

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
--  - 방 출처(system = 'slack' 또는 'mattermost' + workspace_id + channel_id): 이 store 에 활성 바인딩이 없으면 23503.
--    Slack Connect / Mattermost shared channel(kind = connect)이거나 외부 구성원이 있는 방이면 origin = external.
--    containment 는 room_containment 의 결과다.
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
    IF x ->> 'system' IN ('slack', 'mattermost') AND x ? 'workspace_id' AND x ? 'channel_id' THEN
      SELECT * INTO b FROM room_binding AS r
      WHERE r.tenant_id = m.tenant_id AND r.platform = x ->> 'system' AND r.workspace_id = x ->> 'workspace_id' AND r.channel_id = x ->> 'channel_id'
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

-- ── 속성 어휘표: 키(memory.attribute)가 무엇을 묻는지 적는다 (v1.4 U41) ──
-- 같은 키는 구성상 같은 주제다. 새 키는 register_attribute 로만 늘고, 같은 질문인지는 서버가 질문끼리 비교해 정한다.
CREATE TABLE attribute_vocab (
  tenant_id uuid NOT NULL,
  store_id uuid NOT NULL,
  subject_id uuid NOT NULL,
  key text NOT NULL,        -- app_sec.norm_text() 형태의 짧은 슬러그. memory.attribute 가 이 값을 쓴다
  label text NOT NULL,      -- 사람이 읽는 이름
  question text NOT NULL,   -- 이 속성이 답하는 한 줄 질문 (예: '라이트 테마 border 색의 대비 비율')
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_id, subject_id, key),
  CONSTRAINT vocab_store_same_tenant FOREIGN KEY (tenant_id, store_id) REFERENCES store (tenant_id, id),
  CONSTRAINT vocab_subject_same_tenant FOREIGN KEY (tenant_id, subject_id) REFERENCES entity (tenant_id, id),
  CONSTRAINT vocab_key_shape CHECK (key = app_sec.norm_text(key) AND char_length(key) BETWEEN 1 AND 40),
  CONSTRAINT vocab_label_shape CHECK (char_length(label) BETWEEN 1 AND 80),
  CONSTRAINT vocab_question_shape CHECK (char_length(question) BETWEEN 1 AND 200)
);

ALTER TABLE attribute_vocab ENABLE ROW LEVEL SECURITY;
ALTER TABLE attribute_vocab FORCE ROW LEVEL SECURITY;
CREATE POLICY attribute_vocab_read ON attribute_vocab FOR SELECT USING (
  tenant_id = app_sec.ctx_tenant() AND store_id IN (SELECT app_sec.my_stores('reader'))
);

-- 새 어휘 항목: contributor 만 쓴다. 이미 있는 키는 그대로 두고 false 를 돌려준다 (재시도에 안전).
CREATE FUNCTION app_sec.register_attribute(p_store uuid, p_subject uuid, p_key text, p_label text, p_question text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  v_rows integer;
BEGIN
  IF app_sec.ctx_user() IS NULL OR p_store NOT IN (SELECT app_sec.my_stores('contributor')) THEN
    RAISE EXCEPTION 'not a contributor of the store' USING ERRCODE = '42501';
  END IF;
  INSERT INTO attribute_vocab (tenant_id, store_id, subject_id, key, label, question)
  VALUES (app_sec.ctx_tenant(), p_store, p_subject, app_sec.norm_text(p_key), btrim(p_label), btrim(p_question))
  ON CONFLICT (store_id, subject_id, key) DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows = 1;
END $$;

-- INSERT: 요청 컨텍스트가 있으면 저자·대리·tenant 를 세션에 묶고(NULL 은 채우고, 다르면 42501),
-- version 을 1 로 고정한다 (origin 은 memory_bi3_origin 이 정한다). 컨텍스트가 없는 소유자 적재는 값을 그대로 둔다.
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
    WHERE m.id = NEW.supersedes_id AND m.store_id = NEW.store_id AND m.status IN ('active', 'provisional', 'superseded')
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

-- UPDATE: 불변 컬럼, origin 단방향, memory_transition 표, 본문 편집 범위, 버전 증가, 삭제 시 본문 제거
CREATE FUNCTION app_sec.memory_before_update() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  tr memory_transition;
  v_op memory_op;
BEGIN
  IF (NEW.id, NEW.tenant_id, NEW.store_id, NEW.kind, NEW.created_by, NEW.on_behalf_of, NEW.created_at, NEW.session_ref)
     IS DISTINCT FROM
     (OLD.id, OLD.tenant_id, OLD.store_id, OLD.kind, OLD.created_by, OLD.on_behalf_of, OLD.created_at, OLD.session_ref) THEN
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
    v_op := nullif(current_setting('app.op', true), '')::memory_op;
    IF v_op IS NULL THEN
      RAISE EXCEPTION 'status change % -> % needs app.op', OLD.status, NEW.status USING ERRCODE = '42501';
    END IF;
    SELECT * INTO tr FROM memory_transition AS t WHERE t.from_status = OLD.status AND t.to_status = NEW.status AND t.op = v_op;
    IF NOT found THEN
      RAISE EXCEPTION 'illegal transition % -> % (%)', OLD.status, NEW.status, v_op;
    END IF;
    IF NOT (tr.by_roles && (
      CASE WHEN app_sec.ctx_user() IS NOT NULL THEN ARRAY['contributor', 'curator'] ELSE ARRAY['system'] END
    )::transition_role[]) THEN
      RAISE EXCEPTION 'transition % -> % (%) is for the % role', OLD.status, NEW.status, v_op, tr.by_roles USING ERRCODE = '42501';
    END IF;
    IF NEW.status NOT IN ('provisional', 'challenger') THEN
      NEW.promote_at := NULL;
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

-- origin 과 containment 는 출처에서 서버가 정한다. 외부 출처이거나 지시문 표지(flags)가 붙은 기억은 시간으로 승격하지 않는다 (결정 1):
-- promote_at 을 비우면 합의(confirm, 같은 값을 다른 사람이 말함)로만 active 가 된다.
-- source_facts 는 app_rw 가 부를 수 없으므로 소유자 권한 트리거가 대신 부른다. 이름 순서상 memory_bi, memory_bi2_hash 다음에 돈다.
CREATE FUNCTION app_sec.memory_set_origin() RETURNS trigger
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
    IF (NEW.origin = 'external' OR CASE
      WHEN NOT (NEW.gate_result ? 'flags') THEN false
      WHEN jsonb_typeof(NEW.gate_result -> 'flags') = 'array' THEN jsonb_array_length(NEW.gate_result -> 'flags') > 0
      ELSE true
    END) THEN
      NEW.promote_at := NULL;
    END IF;
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

-- 키와 값은 정규화해서 저장한다 (attribute, value). 같은 키와 값의 판정은 remember() 가 한다.
-- memory_bi2_hash 가 content_hash 를 정한 뒤, memory_bi3_origin 이 origin 을 정하기 전에 돈다.
CREATE FUNCTION app_sec.memory_norm_key() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF NEW.attribute IS NOT NULL THEN
    NEW.attribute := app_sec.norm_text(NEW.attribute);
  END IF;
  NEW.value := nullif(app_sec.norm_text(NEW.value), '');
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
    ELSE nullif(current_setting('app.op', true), '')::memory_op
  END;
  PERFORM app_sec.write_version(NEW, v_op, actor, why);
  IF v_op = 'delete' THEN
    IF OLD.content_hash IS NOT NULL THEN
      INSERT INTO deleted_hash (store_id, content_hash, reason) VALUES (NEW.store_id, OLD.content_hash, coalesce(why, 'delete'))
      ON CONFLICT DO NOTHING;
    END IF;
    UPDATE memory_version SET snapshot = NULL WHERE memory_id = NEW.id AND snapshot IS NOT NULL;
    UPDATE memory_evidence SET author_name = NULL WHERE memory_id = NEW.id AND author_name IS NOT NULL;
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
CREATE TRIGGER memory_bi2k_norm BEFORE INSERT ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_norm_key();
CREATE TRIGGER memory_bi3_origin BEFORE INSERT ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_set_origin();
CREATE TRIGGER memory_bu2_hash BEFORE UPDATE ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_set_hash();
CREATE TRIGGER memory_aw AFTER INSERT OR UPDATE ON memory FOR EACH ROW EXECUTE FUNCTION app_sec.memory_after_write();

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
CREATE FUNCTION app_sec.verify_chain(p_mem uuid) RETURNS boolean LANGUAGE sql
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

-- 쓰기 판정. 키의 살아 있는 행과 열린 challenger 를 잠그고 5.1 의 표에서 첫 일치 행을 실행한다.
-- 결과: created, confirmed, reconfirmed, challenged, superseded, retracted
-- (r_id = 결과가 된 행, r_conflict = challenged 일 때 살아 있는 행).
-- 증거 author 가 없으면 호출자, 시각이 없으면 지금이다. 같은 키에 동시에 쓰는 두 번째 INSERT 는 23505 를 받고 한 번 다시 판정한다.
-- p_retract 가 있으면 9, 10행만 본다: 대상이 provisional 이나 challenger 면 rejected, active 면 expired.
CREATE FUNCTION app_sec.remember(
  p_store uuid, p_kind memory_kind, p_title text, p_body text, p_source_refs jsonb,
  p_subject uuid, p_attribute text, p_value text, p_gate jsonb,
  p_consensus text, p_evidence jsonb, p_retract uuid DEFAULT null
) RETURNS TABLE (r_outcome text, r_id uuid, r_status memory_status, r_conflict uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  me uuid := app_sec.ctx_user();
  by_whom uuid := coalesce(app_sec.ctx_agent(), app_sec.ctx_user());
  behalf uuid := CASE WHEN app_sec.ctx_agent() IS NULL THEN NULL ELSE app_sec.ctx_user() END;
  v_attr text := app_sec.norm_text(p_attribute);
  v_val text := nullif(app_sec.norm_text(p_value), '');
  v_hash text := CASE WHEN p_body IS NULL THEN NULL ELSE app_sec.content_hmac(p_body) END;
  v_agreed boolean;
  v_basis promotion_basis;
  v_after interval;
  v_ev jsonb;
  v_fresh jsonb;
  live memory;
  chal memory;
  tgt memory;
  fresh memory;
  ref text;
  attempt integer;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'no user context' USING ERRCODE = '28000';
  END IF;
  IF p_consensus NOT IN ('agreed', 'stated') THEN
    RAISE EXCEPTION 'unknown consensus %', p_consensus USING ERRCODE = '22023';
  END IF;
  IF p_store NOT IN (SELECT app_sec.my_stores('contributor')) THEN
    RAISE EXCEPTION 'not a contributor of this store' USING ERRCODE = '42501';
  END IF;
  -- memory:// 인용은 호출자가 읽을 수 있는 기억만이다. 존재하지 않음과 읽을 수 없음은 같은 오류다 (memory_read 정책과 같은 조건)
  FOR ref IN SELECT x ->> 'uri' FROM jsonb_array_elements(p_source_refs) AS x WHERE x ->> 'uri' LIKE 'memory://%' LOOP
    IF ref ~ '^memory://[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' AND NOT EXISTS (
      SELECT 1 FROM memory AS m
      WHERE m.id = substr(ref, 10)::uuid AND m.tenant_id = app_sec.ctx_tenant() AND (
        (m.status IN ('active', 'provisional', 'superseded', 'expired') AND m.store_id IN (SELECT app_sec.my_stores('reader')))
        OR m.store_id IN (SELECT app_sec.my_stores('curator'))
        OR (m.status IN ('proposed', 'challenger') AND coalesce(m.on_behalf_of, m.created_by) = me AND m.store_id IN (SELECT app_sec.my_stores('reader')))
      )
    ) THEN
      RAISE EXCEPTION 'source memory not found: %', ref USING ERRCODE = '23503';
    END IF;
  END LOOP;

  v_agreed := p_consensus = 'agreed' OR EXISTS (SELECT 1 FROM store AS s WHERE s.id = p_store AND s.kind = 'user');
  v_basis := CASE
    WHEN EXISTS (SELECT 1 FROM store AS s WHERE s.id = p_store AND s.kind = 'user') THEN 'user_store'
    WHEN v_agreed THEN 'agreed'
    ELSE 'stated'
  END;
  v_after := coalesce((SELECT a.promote_after FROM store_autonomy AS a WHERE a.store_id = p_store), interval '24 hours');
  v_ev := (
    SELECT jsonb_agg(jsonb_build_object(
      'uri', e ->> 'uri', 'post_id', e ->> 'post_id', 'author', coalesce(e ->> 'author', me::text),
      'author_name', e ->> 'author_name', 'said_at', coalesce(e ->> 'said_at', clock_timestamp()::text)
    ))
    FROM jsonb_array_elements(CASE WHEN jsonb_array_length(coalesce(p_evidence, '[]'::jsonb)) = 0 THEN '[{}]'::jsonb ELSE p_evidence END) AS e
  );

  FOR attempt IN 1..2 LOOP
    BEGIN
      live := NULL;
      chal := NULL;
      IF p_retract IS NOT NULL THEN
        -- 9, 10행
        SELECT * INTO tgt FROM memory AS m
        WHERE m.id = p_retract AND m.store_id = p_store AND m.tenant_id = app_sec.ctx_tenant() AND m.status IN ('provisional', 'challenger', 'active')
        FOR UPDATE;
        IF NOT found THEN
          RAISE EXCEPTION 'retract target not found' USING ERRCODE = 'P0002';
        END IF;
        PERFORM app_sec.move(
          tgt.id, CASE WHEN tgt.status = 'active' THEN 'expired'::memory_status ELSE 'rejected'::memory_status END,
          'retract', app_sec.evidence_reason(v_basis, v_ev)
        );
        PERFORM app_sec.record_evidence(tgt.id, 'retract', v_basis, v_ev);
        IF tgt.status IN ('active', 'provisional') AND tgt.subject_id IS NOT NULL THEN
          PERFORM app_sec.adopt_orphan_challenger(tgt.store_id, tgt.subject_id, tgt.attribute);
        END IF;
        r_outcome := 'retracted';
        r_id := tgt.id;
      ELSE
        IF p_subject IS NOT NULL AND v_attr IS NOT NULL THEN
          SELECT * INTO live FROM memory AS m
          WHERE m.store_id = p_store AND m.tenant_id = app_sec.ctx_tenant() AND m.subject_id = p_subject AND m.attribute = v_attr
            AND m.status IN ('active', 'provisional')
          FOR UPDATE;
          SELECT * INTO chal FROM memory AS m
          WHERE m.store_id = p_store AND m.tenant_id = app_sec.ctx_tenant() AND m.subject_id = p_subject AND m.attribute = v_attr
            AND m.status = 'challenger'
          FOR UPDATE;
        END IF;
        r_conflict := NULL;
        IF live.id IS NULL THEN
          -- 1, 2행
          PERFORM set_config('app.reason', app_sec.evidence_reason(v_basis, v_ev), true);
          INSERT INTO memory (
            tenant_id, store_id, kind, status, title, body, source_refs, created_by, on_behalf_of,
            subject_id, attribute, value, gate_result, basis, promote_at
          ) VALUES (
            app_sec.ctx_tenant(), p_store, p_kind, CASE WHEN v_agreed THEN 'active' ELSE 'provisional' END::memory_status, p_title, p_body, p_source_refs,
            by_whom, behalf, p_subject, v_attr, v_val, coalesce(p_gate, '{}'), v_basis, CASE WHEN v_agreed THEN NULL ELSE now() + v_after END
          ) RETURNING * INTO fresh;
          PERFORM app_sec.record_evidence(fresh.id, 'propose', v_basis, v_ev);
          r_outcome := 'created';
          r_id := fresh.id;
        ELSIF coalesce(CASE WHEN v_val IS NOT NULL AND live.value IS NOT NULL THEN v_val = live.value ELSE v_hash = live.content_hash END, false) THEN
          IF live.status = 'provisional' AND EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_ev) AS e
            WHERE NOT EXISTS (SELECT 1 FROM memory_evidence AS x WHERE x.memory_id = live.id AND x.author = e ->> 'author')
          ) THEN
            -- 3행
            PERFORM app_sec.move(live.id, 'active', 'confirm', app_sec.evidence_reason('agreed', v_ev), 'agreed');
            PERFORM app_sec.record_evidence(live.id, 'confirm', 'agreed', v_ev);
            r_outcome := 'confirmed';
          ELSE
            -- 4행
            v_fresh := app_sec.new_evidence(live.id, 'reconfirm', v_ev);
            IF jsonb_array_length(v_fresh) > 0 THEN
              IF chal.id IS NOT NULL AND EXISTS (
                SELECT 1 FROM jsonb_array_elements(v_fresh) AS e WHERE (e ->> 'said_at')::timestamptz > chal.created_at
              ) THEN
                PERFORM app_sec.move(chal.id, 'rejected', 'retract', 'reaffirmed');
              END IF;
              PERFORM set_config('app.op', 'reconfirm', true);
              PERFORM set_config('app.reason', app_sec.evidence_reason(v_basis, v_fresh), true);
              UPDATE memory SET last_confirmed_at = clock_timestamp(), value = coalesce(value, v_val) WHERE id = live.id;
              PERFORM app_sec.record_evidence(live.id, 'reconfirm', v_basis, v_fresh);
            END IF;
            r_outcome := 'reconfirmed';
          END IF;
          r_id := live.id;
        ELSIF chal.id IS NOT NULL AND coalesce(CASE WHEN v_val IS NOT NULL AND chal.value IS NOT NULL THEN v_val = chal.value ELSE v_hash = chal.content_hash END, false) THEN
          IF v_agreed OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_ev) AS e
            WHERE NOT EXISTS (SELECT 1 FROM memory_evidence AS x WHERE x.memory_id = chal.id AND x.author = e ->> 'author')
          ) THEN
            -- 5행: 이전 행을 먼저 superseded 로 옮긴 뒤 challenger 를 active 로 올린다
            PERFORM app_sec.move(live.id, 'superseded', 'supersede', 'superseded by ' || chal.id);
            PERFORM app_sec.move(chal.id, 'active', 'confirm', app_sec.evidence_reason('agreed', v_ev), 'agreed', live.id);
            PERFORM app_sec.record_evidence(chal.id, 'confirm', 'agreed', v_ev);
            r_outcome := 'superseded';
            r_conflict := live.id;
          ELSE
            -- 6행
            v_fresh := app_sec.new_evidence(chal.id, 'reconfirm', v_ev);
            IF jsonb_array_length(v_fresh) > 0 THEN
              PERFORM set_config('app.op', 'reconfirm', true);
              PERFORM set_config('app.reason', app_sec.evidence_reason(v_basis, v_fresh), true);
              UPDATE memory SET last_confirmed_at = clock_timestamp() WHERE id = chal.id;
              PERFORM app_sec.record_evidence(chal.id, 'reconfirm', v_basis, v_fresh);
            END IF;
            r_outcome := 'reconfirmed';
            r_conflict := live.id;
          END IF;
          r_id := chal.id;
        ELSE
          -- 7, 8행: 열린 challenger 는 먼저 닫는다
          IF chal.id IS NOT NULL THEN
            PERFORM app_sec.move(chal.id, 'rejected', 'retract', 'replaced');
          END IF;
          IF v_agreed THEN
            PERFORM app_sec.move(live.id, 'superseded', 'supersede', 'superseded by a newer value');
          END IF;
          PERFORM set_config('app.reason', app_sec.evidence_reason(v_basis, v_ev), true);
          INSERT INTO memory (
            tenant_id, store_id, kind, status, title, body, source_refs, created_by, on_behalf_of,
            subject_id, attribute, value, gate_result, basis, promote_at, supersedes_id, conflict_with, valid_from
          ) VALUES (
            app_sec.ctx_tenant(), p_store, p_kind, CASE WHEN v_agreed THEN 'active' ELSE 'challenger' END::memory_status, p_title, p_body, p_source_refs,
            by_whom, behalf, p_subject, v_attr, v_val, coalesce(p_gate, '{}'), v_basis, CASE WHEN v_agreed THEN NULL ELSE now() + v_after END,
            live.id, CASE WHEN v_agreed THEN NULL ELSE live.id END, CASE WHEN v_agreed THEN current_date END
          ) RETURNING * INTO fresh;
          PERFORM app_sec.record_evidence(fresh.id, 'propose', v_basis, v_ev);
          r_outcome := CASE WHEN v_agreed THEN 'superseded' ELSE 'challenged' END;
          r_id := fresh.id;
          r_conflict := CASE WHEN v_agreed THEN NULL ELSE live.id END;
        END IF;
      END IF;
      PERFORM set_config('app.op', '', true);
      PERFORM set_config('app.reason', '', true);
      SELECT m.status INTO r_status FROM memory AS m WHERE m.id = r_id;
      RETURN NEXT;
      RETURN;
    EXCEPTION WHEN unique_violation THEN
      IF attempt = 2 THEN
        RAISE;
      END IF;
    END;
  END LOOP;
END $$;

-- MCP decide (v1.3 §8): contributor 이상이면 사람이든 에이전트든 provisional/challenger 를 확정(confirm)하거나 모든 살아 있는 행을 철회(retract)한다.
-- 증거(source_refs)는 필수이고, 작성자는 호출자로 고정한다 (클라이언트가 보낸 author 는 무시한다).
-- 기존 증거에 이미 있는 작성자의 confirm 은 4행처럼 reconfirm 만 한다: 혼자서 확정하지 못한다. active 행의 confirm 도 reconfirm 이다.
-- 결과: applied(r_status = 새 상태), reconfirmed, refused.
-- refused 의 r_reason: stale 이면 expected_version 이 다르고, not_live 이면 대상이 없거나 살아 있지 않거나 contributor 가 아니다.
CREATE FUNCTION app_sec.decide(p_memory uuid, p_verdict text, p_expected_version integer, p_evidence jsonb)
RETURNS TABLE (r_outcome text, r_status memory_status, r_reason text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  me uuid := app_sec.ctx_user();
  v_who text := app_sec.ctx_user()::text;
  v_ev jsonb;
  v_fresh jsonb;
  tgt memory;
  live memory;
  chal memory;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'no user context' USING ERRCODE = '28000';
  END IF;
  IF p_verdict NOT IN ('confirm', 'retract') THEN
    RAISE EXCEPTION 'unknown verdict %', p_verdict USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(coalesce(p_evidence, '[]'::jsonb)) = 0 THEN
    RAISE EXCEPTION 'decide needs at least one source ref' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO tgt FROM memory AS m
  WHERE m.id = p_memory AND m.tenant_id = app_sec.ctx_tenant() AND m.store_id IN (SELECT app_sec.my_stores('contributor'))
  FOR UPDATE;
  IF NOT found OR tgt.status NOT IN ('provisional', 'challenger', 'active') THEN
    RETURN QUERY SELECT 'refused'::text, tgt.status, 'not_live'::text;
    RETURN;
  END IF;
  IF tgt.version <> p_expected_version THEN
    RETURN QUERY SELECT 'refused'::text, tgt.status, 'stale'::text;
    RETURN;
  END IF;
  v_ev := (
    SELECT jsonb_agg(jsonb_build_object(
      'uri', e ->> 'uri', 'author', v_who,
      'author_name', (SELECT p.display_name FROM principal AS p WHERE p.id = me), 'said_at', clock_timestamp()::text
    ))
    FROM jsonb_array_elements(p_evidence) AS e
  );

  IF p_verdict = 'retract' THEN
    PERFORM app_sec.move(
      tgt.id, CASE WHEN tgt.status = 'active' THEN 'expired'::memory_status ELSE 'rejected'::memory_status END,
      'retract', app_sec.evidence_reason('agent', v_ev)
    );
    PERFORM app_sec.record_evidence(tgt.id, 'retract', 'agent', v_ev);
    IF tgt.status IN ('active', 'provisional') AND tgt.subject_id IS NOT NULL THEN
      PERFORM app_sec.adopt_orphan_challenger(tgt.store_id, tgt.subject_id, tgt.attribute);
    END IF;
    r_outcome := 'applied';
  ELSIF tgt.status = 'active' OR EXISTS (SELECT 1 FROM memory_evidence AS x WHERE x.memory_id = tgt.id AND x.author = v_who) THEN
    IF tgt.status = 'active' AND tgt.subject_id IS NOT NULL THEN
      SELECT * INTO chal FROM memory AS m
      WHERE m.store_id = tgt.store_id AND m.subject_id = tgt.subject_id AND m.attribute = tgt.attribute AND m.status = 'challenger'
      FOR UPDATE;
      IF found THEN
        PERFORM app_sec.move(chal.id, 'rejected', 'retract', 'reaffirmed');
      END IF;
    END IF;
    v_fresh := app_sec.new_evidence(tgt.id, 'reconfirm', v_ev);
    PERFORM set_config('app.op', 'reconfirm', true);
    PERFORM set_config('app.reason', app_sec.evidence_reason('agent', v_fresh), true);
    UPDATE memory SET last_confirmed_at = clock_timestamp() WHERE id = tgt.id;
    PERFORM app_sec.record_evidence(tgt.id, 'reconfirm', 'agent', v_fresh);
    r_outcome := 'reconfirmed';
  ELSE
    IF tgt.status = 'challenger' THEN
      SELECT * INTO live FROM memory AS m
      WHERE m.store_id = tgt.store_id AND m.subject_id = tgt.subject_id AND m.attribute = tgt.attribute AND m.status IN ('active', 'provisional')
      FOR UPDATE;
      PERFORM app_sec.move(live.id, 'superseded', 'supersede', 'superseded by ' || tgt.id);
      PERFORM app_sec.move(tgt.id, 'active', 'confirm', app_sec.evidence_reason('agent', v_ev), 'agent', live.id);
    ELSE
      PERFORM app_sec.move(tgt.id, 'active', 'confirm', app_sec.evidence_reason('agent', v_ev), 'agent');
    END IF;
    PERFORM app_sec.record_evidence(tgt.id, 'confirm', 'agent', v_ev);
    r_outcome := 'applied';
  END IF;
  PERFORM set_config('app.op', '', true);
  PERFORM set_config('app.reason', '', true);
  SELECT m.status INTO r_status FROM memory AS m WHERE m.id = tgt.id;
  RETURN NEXT;
END $$;

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

-- 워커 전용 (v1.3 §7.2): 시각이 지난 provisional 과 challenger 를 active 로 올린다.
-- digest 바인딩이 있는 기억은 그 바인딩의 digest_cursor(Mattermost create_at 밀리초)가 promote_at 을 지났을 때만 올린다:
-- digest 가 밀리면 아직 읽지 못한 반박이 있을 수 있다.
-- 바인딩의 digest 가 꺼져 있거나 바인딩 출처가 없는 기억(MCP, 📌)은 시각만 본다. 출처가 external 인 기억은 시간으로 올리지 않는다 (결정 1).
-- p_now 는 테스트와 eval 이 시계를 넘기는 데 쓴다. 이미 올린 행은 다시 걸리지 않으므로 몇 번을 불러도 같은 상태가 된다.
-- 교체는 이전 행을 먼저 superseded 로 옮긴 뒤 challenger 를 active 로 올린다 (결정 3). valid_to 는 DB 의 오늘(current_date)이다.
CREATE FUNCTION app_sec.digest_cursor(m memory) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT min(b.digest_cursor)
  FROM jsonb_array_elements(m.source_refs) AS x
  JOIN room_binding AS b ON b.tenant_id = m.tenant_id AND b.store_id = m.store_id
    AND b.platform = x ->> 'system' AND b.workspace_id = x ->> 'workspace_id' AND b.channel_id = x ->> 'channel_id'
    AND b.confirmed_by IS NOT NULL AND b.revoked_at IS NULL AND b.digest_enabled
$$;
CREATE FUNCTION app_sec.promote_due(p_now timestamptz DEFAULT now()) RETURNS TABLE (promoted integer, replaced integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  cand memory;
  live memory;
  cur bigint;
  ev jsonb;
BEGIN
  promoted := 0;
  replaced := 0;
  FOR cand IN
    SELECT * FROM memory AS m WHERE m.status = 'challenger' AND m.origin = 'internal' AND m.promote_at <= p_now ORDER BY m.promote_at, m.id
  LOOP
    SELECT * INTO live FROM memory AS l
    WHERE l.store_id = cand.store_id AND l.subject_id = cand.subject_id AND l.attribute = cand.attribute AND l.status IN ('active', 'provisional')
    FOR UPDATE;
    SELECT * INTO cand FROM memory AS m WHERE m.id = cand.id AND m.status = 'challenger' AND m.promote_at <= p_now FOR UPDATE;
    CONTINUE WHEN NOT found;
    cur := app_sec.digest_cursor(cand);
    CONTINUE WHEN cur < ceil(extract(EPOCH FROM cand.promote_at) * 1000);
    ev := jsonb_build_array(jsonb_build_object('post_id', cur::text, 'said_at', p_now));
    IF live.id IS NOT NULL THEN
      PERFORM app_sec.move(live.id, 'superseded', 'supersede', 'superseded by ' || cand.id);
    END IF;
    PERFORM app_sec.move(cand.id, 'active', 'promote', app_sec.evidence_reason('timer', ev), 'timer', live.id);
    PERFORM app_sec.record_evidence(cand.id, 'promote', 'timer', ev);
    replaced := replaced + 1;
  END LOOP;
  -- 열린 challenger 가 있는 키의 provisional 은 승격하지 않는다: challenger 쪽 규칙이 먼저 결론을 낸다
  FOR cand IN
    SELECT * FROM memory AS m
    WHERE m.status = 'provisional' AND m.origin = 'internal' AND m.promote_at <= p_now
      AND NOT EXISTS (
        SELECT 1 FROM memory AS c
        WHERE c.store_id = m.store_id AND c.subject_id = m.subject_id AND c.attribute = m.attribute AND c.status = 'challenger'
      )
    ORDER BY m.promote_at, m.id
  LOOP
    SELECT * INTO cand FROM memory AS m WHERE m.id = cand.id AND m.status = 'provisional' AND m.promote_at <= p_now FOR UPDATE;
    CONTINUE WHEN NOT found;
    cur := app_sec.digest_cursor(cand);
    CONTINUE WHEN cur < ceil(extract(EPOCH FROM cand.promote_at) * 1000);
    ev := jsonb_build_array(jsonb_build_object('post_id', cur::text, 'said_at', p_now));
    PERFORM app_sec.move(cand.id, 'active', 'promote', app_sec.evidence_reason('timer', ev), 'timer');
    PERFORM app_sec.record_evidence(cand.id, 'promote', 'timer', ev);
    promoted := promoted + 1;
  END LOOP;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION app_sec.digest_cursor(memory) FROM public, app_rw;
REVOKE ALL ON FUNCTION app_sec.promote_due(timestamptz) FROM public, app_rw;
GRANT EXECUTE ON FUNCTION app_sec.promote_due(timestamptz) TO nunchi_worker;

-- ── 검색: pg_trgm + pgvector 하이브리드 (v1.2 §5), 변경 제안(challenger) 접기 (v1.3 §8)
-- 한국어는 조사가 붙고 띄어쓰기가 흔들려서 simple FTS 가 '담당자' 로 '담당자는' 을 못 찾는다. trigram 은 부분 문자열로 맞는다.
-- 질의는 두 가지로 맞춘다: 원문, 그리고 공백을 뺀 형태('배포 절차' 로 '배포절차는' 을 찾기 위해). 둘 중 하나가 word_similarity 0.3 이상이면 후보다.
-- 임베딩 질의(p_embedding, p_model)를 주면 코사인 유사도가 p_floor(기본 0.4) 이상인 행을 벡터 순위로 따로 매기고,
-- 두 순위를 RRF(k = p_rrf_k, 기본 60)로 합친다. 질의 벡터는 real[] 로 받아 함수 안에서 vector(512) 로 바꾼다
-- (app_rw 가 vector 입출력 함수를 직접 실행하지 않아도 된다).
-- 합친 점수는 2/(k+1)(두 목록 모두 1위일 때의 값)로 나눠 0..1 로 맞춘다. 임베딩 질의가 없으면 예전 그대로 trigram 점수다.
-- 상태 가중치(provisional 0.7, 그 밖 1.0)는 순위를 합치고 접은 뒤 결과 행의 상태로 곱한다. 인덱스는 title || ' ' || body 식 하나에 건다.
-- challenger 는 p_statuses 에 없어도 찾는다. 질의가 challenger 본문에만 맞아도 같은 키의 살아 있는 행(p_statuses 에 드는 active, provisional)이
-- 결과로 나오고, 그 행에 pending_* 로 열린 challenger 가 붙는다. 살아 있는 행이 결과에 못 드는 challenger 는 버린다.
-- p_statuses 에 challenger 를 넣으면 challenger 도 자기 행으로 나온다.
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
  stale boolean, last_confirmed_at timestamptz,
  subject_id uuid, attribute text, basis promotion_basis, promote_at timestamptz, flags integer,
  pending_id uuid, pending_title text, pending_value text, pending_promote_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
#variable_conflict use_column
DECLARE v_q text; v_squeezed text; v_old_threshold text; v_vec vector(512); v_st memory_status[];
BEGIN
  IF length(p_query) > 1000 THEN
    RAISE EXCEPTION 'search query too long: at most 1000 characters' USING ERRCODE = '22023';
  END IF;
  v_q := btrim(p_query);
  v_squeezed := regexp_replace(v_q, '\s+', '', 'g');
  IF v_squeezed = '' THEN
    RETURN;
  END IF;
  v_st := coalesce(p_statuses, ARRAY['active']::memory_status[]);
  v_vec := p_embedding::vector(512);
  v_old_threshold := coalesce(current_setting('pg_trgm.word_similarity_threshold', true), '0.6');
  PERFORM set_config('pg_trgm.word_similarity_threshold', '0.3', true);
  RETURN QUERY
    WITH vis AS NOT MATERIALIZED (
      SELECT m.id, m.store_id, m.kind, m.title, m.status, m.body, m.subject_id, m.attribute
      FROM memory AS m
      WHERE
        m.tenant_id = app_sec.ctx_tenant()
        AND (p_stores IS NULL OR m.store_id = ANY (p_stores))
        AND (m.status = ANY (v_st) OR m.status = 'challenger')
        AND (p_kinds IS NULL OR m.kind = ANY (p_kinds))
        AND (
          (m.status IN ('active', 'provisional', 'challenger', 'superseded', 'expired') AND m.store_id IN (SELECT app_sec.my_stores('reader')))
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
    ),
    hit AS (
      SELECT v.id, v.status, v.store_id, v.subject_id, v.attribute,
        CASE WHEN v_vec IS NULL THEN t.sim
             ELSE (coalesce(1.0 / (p_rrf_k + t.rk), 0) + coalesce(1.0 / (p_rrf_k + x.rk), 0)) * (p_rrf_k + 1) / 2 END AS raw
      FROM tri AS t FULL JOIN vec AS x ON x.id = t.id
      JOIN vis AS v ON v.id = coalesce(t.id, x.id)
    ),
    folded AS (
      SELECT CASE
          WHEN h.status = 'challenger' AND NOT ('challenger' = ANY (v_st)) THEN
            (SELECT l.id FROM memory AS l
             WHERE l.tenant_id = app_sec.ctx_tenant() AND l.store_id = h.store_id AND l.subject_id = h.subject_id
               AND l.attribute = h.attribute AND l.status IN ('active', 'provisional') AND l.status = ANY (v_st))
          ELSE h.id
        END AS target,
        h.raw
      FROM hit AS h
    )
    SELECT m.id, m.store_id, m.kind, m.title, m.status,
      (g.raw * CASE m.status WHEN 'provisional' THEN 0.7 ELSE 1.0 END)::real AS score,
      app_sec.is_stale(m.status, m.store_id, m.kind, m.last_confirmed_at) AS stale, m.last_confirmed_at,
      m.subject_id, m.attribute, m.basis, m.promote_at,
      CASE WHEN jsonb_typeof(m.gate_result -> 'flags') = 'array' THEN jsonb_array_length(m.gate_result -> 'flags') ELSE 0 END AS flags,
      c.id, c.title, c.value, c.promote_at
    FROM (SELECT f.target, max(f.raw) AS raw FROM folded AS f WHERE f.target IS NOT NULL GROUP BY f.target) AS g
    JOIN memory AS m ON m.id = g.target
    LEFT JOIN memory AS c ON c.status = 'challenger' AND c.tenant_id = m.tenant_id AND c.store_id = m.store_id
      AND c.subject_id = m.subject_id AND c.attribute = m.attribute AND m.status IN ('active', 'provisional')
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

-- ── 앱 접속 역할 최소 권한 (RLS 우회·스스로 권한 부여 불가) ──
GRANT USAGE ON SCHEMA public TO app_rw;
-- 주체/권한/감사 테이블은 읽기 전용이다. 버전은 memory 트리거, 삭제 해시는 삭제 트리거, 권한과 주체는 별도 관리 역할이 쓴다
GRANT SELECT ON tenant, group_member, store, store_grant, memory_transition TO app_rw;
GRANT SELECT ON entity, entity_alias, attribute_vocab TO app_rw;
-- principal.external_id(IdP subject, SCIM id)는 숨긴다: 컬럼 단위 GRANT 에서 뺀다. SELECT * 는 42501 이다.
-- 필요한 조회는 SECURITY DEFINER 함수(app_sec.resolve_principal)로 낸다.
GRANT SELECT (id, tenant_id, kind, display_name, active) ON principal TO app_rw;
GRANT SELECT ON memory_version, memory_evidence, deleted_hash, room_binding, source_system TO app_rw;
GRANT SELECT, UPDATE ON memory TO app_rw;  -- 쓰기는 app_sec.remember() 뿐이다: INSERT 권한이 없다

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
GRANT EXECUTE ON FUNCTION app_sec.claim_inbound_event(text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.my_store_roles() TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.my_stores(store_role) TO app_rw;
GRANT EXECUTE ON FUNCTION
app_sec.search(text, uuid[], memory_status[], memory_kind[], real[], text, real, integer)
TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.verify_chain(uuid) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.evidence_line(text, text, text, timestamptz, promotion_basis) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.evidence_digest(text[]) TO app_rw;
GRANT EXECUTE ON FUNCTION
app_sec.remember(uuid, memory_kind, text, text, jsonb, uuid, text, text, jsonb, text, jsonb, uuid)
TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.decide(uuid, text, integer, jsonb) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.norm_text(text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.resolve_entity(text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.create_entity(text, text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.add_entity_alias(uuid, text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.entity_matches(text, integer) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.attribute_matches(uuid, uuid, text, integer) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.register_attribute(uuid, uuid, text, text, text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.memory_as_of(uuid, uuid, text, date) TO app_rw;
GRANT EXECUTE ON FUNCTION principal_closure(uuid) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.set_digest(uuid, boolean) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.advance_digest(uuid, bigint) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.replace_room_members(uuid, text[], text[]) TO app_rw;

-- 중복 note 흡수 (U27): note 는 키가 없어 같은 보고가 몇 분 간격으로 두 번 저장됐다. 같은 store 의 최근 p_days 일 안에 확인된 note 중
-- 제목+본문 trigram 유사도가 0.9 이상이거나, 제목이 같고 본문 유사도가 0.7 이상인 행이 있으면 새 행 없이 그 행을 reconfirm 하고 id 를 돌려준다. 없으면 NULL.
-- 호출자가 그 store 의 contributor 일 때만 판정한다(아니면 NULL 을 돌려 remember() 가 거절하게 둔다).
CREATE FUNCTION app_sec.reconfirm_duplicate_note(
  p_store uuid, p_title text, p_body text, p_days integer DEFAULT 14,
  p_consensus text DEFAULT 'stated', p_evidence jsonb DEFAULT '[]'
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  v_title text := app_sec.norm_text(p_title);
  v_body text := app_sec.norm_text(coalesce(p_body, ''));
  v_basis promotion_basis := CASE WHEN p_consensus = 'agreed' THEN 'agreed' ELSE 'stated' END;
  v_ev jsonb;
  v_fresh jsonb;
  v_id uuid;
BEGIN
  IF app_sec.ctx_user() IS NULL OR p_store NOT IN (SELECT app_sec.my_stores('contributor')) THEN
    RETURN NULL;
  END IF;
  SELECT m.id INTO v_id FROM memory AS m
  WHERE m.store_id = p_store AND m.tenant_id = app_sec.ctx_tenant() AND m.kind = 'note' AND m.subject_id IS NULL
    AND m.status IN ('proposed', 'active', 'provisional')
    AND m.last_confirmed_at >= now() - make_interval(days => p_days)
    AND (
      similarity(app_sec.norm_text(m.title || ' ' || coalesce(m.body, '')), v_title || ' ' || v_body) >= 0.9
      OR (app_sec.norm_text(m.title) = v_title AND similarity(app_sec.norm_text(coalesce(m.body, '')), v_body) >= 0.7)
    )
  ORDER BY similarity(app_sec.norm_text(m.title || ' ' || coalesce(m.body, '')), v_title || ' ' || v_body) DESC, m.created_at, m.id
  LIMIT 1
  FOR UPDATE OF m;
  IF v_id IS NOT NULL THEN
    v_ev := (
      SELECT jsonb_agg(jsonb_build_object(
        'uri', e ->> 'uri', 'post_id', e ->> 'post_id', 'author', coalesce(e ->> 'author', app_sec.ctx_user()::text),
        'author_name', e ->> 'author_name', 'said_at', coalesce(e ->> 'said_at', clock_timestamp()::text)
      ))
      FROM jsonb_array_elements(CASE WHEN jsonb_array_length(coalesce(p_evidence, '[]'::jsonb)) = 0 THEN '[{}]'::jsonb ELSE p_evidence END) AS e
    );
    v_fresh := app_sec.new_evidence(v_id, 'reconfirm', v_ev);
    PERFORM set_config('app.reason', app_sec.evidence_reason(v_basis, v_fresh), true);
    UPDATE memory SET last_confirmed_at = now() WHERE id = v_id;
    PERFORM app_sec.record_evidence(v_id, 'reconfirm', v_basis, v_fresh);
    PERFORM set_config('app.reason', '', true);
  END IF;
  RETURN v_id;
END $$;

GRANT EXECUTE ON FUNCTION app_sec.reconfirm_duplicate_note(uuid, text, text, integer, text, jsonb) TO app_rw;

-- digest 봇이 창을 읽기 전에 청중 포함을 확인한다 (design v1.3 7.1 5번)
GRANT EXECUTE ON FUNCTION app_sec.room_containment(uuid) TO app_rw;
