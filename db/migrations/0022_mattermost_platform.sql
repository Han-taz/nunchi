-- Forward migration 0022: Mattermost 를 두 번째 플랫폼으로 받는다 (U22a).
-- 채널 id 규칙을 플랫폼별로 나누고 source_facts 가 system = 'mattermost' 방 출처도 바인딩으로 검증한다.
-- The function body is copied from db/schema.sql (the schema-drift job compares the two).

ALTER TABLE room_binding DROP CONSTRAINT binding_slack_channel_only;
ALTER TABLE room_binding ADD CONSTRAINT binding_channel_id_by_platform CHECK (
  CASE platform
    WHEN 'slack' THEN channel_id ~ '^C[A-Z0-9]+$'
    WHEN 'mattermost' THEN channel_id ~ '^[a-z0-9]{26}$'
    ELSE true
  END
) NOT VALID;
ALTER TABLE room_binding VALIDATE CONSTRAINT binding_channel_id_by_platform;

CREATE OR REPLACE FUNCTION app_sec.source_facts(m memory, OUT p_origin memory_origin, OUT p_containment text)
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
