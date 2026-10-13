-- Forward migration 0026: 제안 카드 발송 대기열 (U26). 함수 본문은 db/schema.sql 에서 그대로 복사했다 (schema-drift 가 둘을 비교한다).

-- 제안 카드 발송 대기열 (U26): 제안자(봇 포함)가 부르면 카드가 아직 한 장도 없는 자기 proposed 메모리마다 issue_dm_cards 를 불러 카드를 만들고,
-- 아직 메신저로 보내지 않은(message_ts 없음) 열린 카드를 돌려준다. 보낸 뒤 record_card_sent 로 표시하면 다시 나오지 않는다.
CREATE FUNCTION app_sec.pending_dm_cards(p_platform text)
RETURNS TABLE (card_nonce uuid, memory_id uuid, version integer, platform_user_id text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  me uuid := app_sec.ctx_user();
  r record;
BEGIN
  IF me IS NULL OR app_sec.ctx_agent() IS NOT NULL THEN
    RAISE EXCEPTION 'only a human principal may open approvals' USING ERRCODE = '42501';
  END IF;
  FOR r IN
    SELECT m.id FROM memory AS m
    WHERE m.status = 'proposed' AND me IN (m.created_by, coalesce(m.on_behalf_of, m.created_by))
      AND NOT EXISTS (SELECT 1 FROM approval_card AS a WHERE a.memory_id = m.id AND a.version_at_issue = m.version)
    ORDER BY m.created_at
  LOOP
    PERFORM app_sec.issue_dm_cards(r.id, p_platform);
  END LOOP;
  RETURN QUERY
  SELECT a.nonce, a.memory_id, a.version_at_issue, i.platform_user_id
  FROM approval_card AS a
  INNER JOIN memory AS m ON m.id = a.memory_id
  INNER JOIN principal_identity AS i ON i.principal_id = a.issued_to AND i.platform = p_platform AND i.tenant_id = m.tenant_id
  WHERE a.platform = p_platform AND a.message_ts IS NULL AND a.consumed_at IS NULL AND a.expires_at > now()
    AND m.status = 'proposed' AND a.version_at_issue = m.version
    AND me IN (m.created_by, coalesce(m.on_behalf_of, m.created_by))
  ORDER BY a.issued_at, a.nonce;
END $$;

-- 보낸 카드 표시: 카드를 낸 제안자만, 아직 표시되지 않은 카드에 한 번 기록한다.
CREATE FUNCTION app_sec.record_card_sent(p_nonce uuid, p_channel text, p_ts text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  me uuid := app_sec.ctx_user();
  n integer;
BEGIN
  IF me IS NULL OR app_sec.ctx_agent() IS NOT NULL THEN
    RAISE EXCEPTION 'only a human principal may open approvals' USING ERRCODE = '42501';
  END IF;
  UPDATE approval_card AS a SET channel_id = p_channel, message_ts = p_ts
  FROM memory AS m
  WHERE a.nonce = p_nonce AND a.message_ts IS NULL AND m.id = a.memory_id
    AND me IN (m.created_by, coalesce(m.on_behalf_of, m.created_by));
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n = 1;
END $$;

GRANT EXECUTE ON FUNCTION app_sec.pending_dm_cards(text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.record_card_sent(uuid, text, text) TO app_rw;
