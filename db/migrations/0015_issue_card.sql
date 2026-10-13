-- Forward migration 0015: app_sec.issue_card, the way a human curator opens an approval without a Slack card.
-- The function body is copied from db/schema.sql (the schema-drift job compares the two).

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

GRANT EXECUTE ON FUNCTION app_sec.issue_card(uuid) TO app_rw;
