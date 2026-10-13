-- Forward migration 0017: Slack 수신 중복 제거와 Slack 승인 카드 발급.
-- The function bodies are copied from db/schema.sql (the schema-drift job compares the two).

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

GRANT EXECUTE ON FUNCTION app_sec.claim_inbound_event(text) TO app_rw;
GRANT EXECUTE ON FUNCTION app_sec.issue_slack_cards(uuid) TO app_rw;
