-- Forward migration 0038: 중복 note 의 재확인도 증거를 남긴다 (design v1.3 U35).
-- remember() 의 4행과 같이, 새 증거만 reconfirm 증거로 기록하고 evidence:<hex> 를 reason 에 넣는다.
-- 그리고 digest 봇이 청중 포함(room_containment)을 실행할 수 있게 한다.
-- 함수 본문은 db/schema.sql 에서 그대로 복사했다 (schema-drift 가 둘을 비교한다).
DROP FUNCTION app_sec.reconfirm_duplicate_note(uuid, text, text, integer);

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
