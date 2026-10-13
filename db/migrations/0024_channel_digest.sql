-- Forward migration 0024: 채널 다이제스트 스위치와 커서 (U23).
-- The column and function definitions are copied from db/schema.sql (the schema-drift job compares the two).

ALTER TABLE room_binding ADD COLUMN digest_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE room_binding ADD COLUMN digest_cursor bigint NOT NULL DEFAULT 0;

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

GRANT EXECUTE ON FUNCTION app_sec.set_digest(uuid, boolean) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.advance_digest(uuid, bigint) TO app_rw;
