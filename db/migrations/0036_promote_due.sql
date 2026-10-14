-- Forward migration 0036: 워커의 promote_due (design v1.3 U36).
-- 함수 본문은 db/schema.sql 에서 그대로 복사했다 (schema-drift 가 둘을 비교한다).
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
