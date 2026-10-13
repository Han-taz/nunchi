-- Forward migration 0010: Slack identity links, room bindings, server-decided origin, store.confidential.
-- Statements are copied from db/schema.sql (the schema-drift job compares the two).
ALTER TABLE store ADD COLUMN confidential boolean NOT NULL DEFAULT false;  -- 기밀 store 의 승인 카드는 제목 대신 id 만 싣는다 (카드는 U6b)

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

CREATE OR REPLACE FUNCTION app_sec.memory_set_tier() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE cont text;
BEGIN
  IF app_sec.ctx_user() IS NOT NULL THEN
    NEW.conflict_with := NULL;
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

GRANT SELECT ON room_binding, source_system TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.resolve_identity(uuid, text, text) TO app_rw;
