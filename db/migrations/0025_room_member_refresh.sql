-- Forward migration 0025: 방 구성원 스냅샷 갱신 함수 (U25).
-- The function and grant are copied from db/schema.sql (the schema-drift job compares the two).

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

GRANT EXECUTE ON FUNCTION app_sec.replace_room_members(uuid, text[], text[]) TO app_rw;
