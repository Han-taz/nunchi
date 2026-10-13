-- Forward migration 0023: 승인 카드 발급을 플랫폼 중립으로 (U22b). issue_slack_cards 를 issue_dm_cards(memory, platform) 로 바꾼다.
-- The function body is copied from db/schema.sql (the schema-drift job compares the two).
-- Slack 행과 enum 값은 그대로 둔다: 이미 발급된 approval_card.platform = 'slack' 행은 유효하다.

DROP FUNCTION app_sec.issue_slack_cards(uuid);

-- 승인 카드(DM): 제안자가 부르면 p_platform 의 SCIM 으로 이어진 curator(제안자 제외)마다 카드를 1장 만들고 새 (nonce, 플랫폼 user id) 만 돌려준다. 열린 카드는 건너뛴다.
CREATE FUNCTION app_sec.issue_dm_cards(p_memory uuid, p_platform text)
RETURNS TABLE (card_nonce uuid, platform_user_id text)
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
    SELECT i.principal_id, i.platform_user_id AS uid FROM principal_identity AS i
    INNER JOIN principal AS u ON u.id = i.principal_id AND u.tenant_id = i.tenant_id
    WHERE i.platform = p_platform AND i.link_quality = 'scim' AND i.tenant_id = m.tenant_id
      AND u.kind = 'user' AND u.active AND u.id NOT IN (m.created_by, coalesce(m.on_behalf_of, m.created_by))
      AND EXISTS (SELECT 1 FROM store_grant AS g WHERE g.store_id = m.store_id AND g.role = 'curator' AND g.principal_id IN (SELECT app_sec.closure(u.id)))
  ),
  ins AS (
    INSERT INTO approval_card (memory_id, version_at_issue, issued_to, platform)
    SELECT m.id, m.version, c.principal_id, p_platform FROM curators AS c
    WHERE NOT EXISTS (
      SELECT 1 FROM approval_card AS a
      WHERE a.memory_id = m.id AND a.issued_to = c.principal_id AND a.version_at_issue = m.version
        AND a.consumed_at IS NULL AND a.expires_at > now()
    )
    RETURNING approval_card.nonce, approval_card.issued_to
  )
  SELECT ins.nonce, c.uid FROM ins INNER JOIN curators AS c ON c.principal_id = ins.issued_to;
END $$;

GRANT EXECUTE ON FUNCTION app_sec.issue_dm_cards(uuid, text) TO app_rw;
