-- Forward migration 0027: 중복 note 흡수 (U27). 함수 본문은 db/schema.sql 에서 그대로 복사했다 (schema-drift 가 둘을 비교한다).

-- 중복 note 흡수 (U27): note 는 키가 없어 같은 보고가 몇 분 간격으로 두 번 저장됐다. 같은 store 의 최근 p_days 일 안에 확인된 note 중
-- 제목+본문 trigram 유사도가 0.9 이상이거나, 제목이 같고 본문 유사도가 0.7 이상인 행이 있으면 새 행 없이 그 행을 reconfirm 하고 id 를 돌려준다. 없으면 NULL.
-- 호출자가 그 store 의 contributor 일 때만 판정한다(아니면 NULL 을 돌려 INSERT 정책이 거절하게 둔다).
CREATE FUNCTION app_sec.reconfirm_duplicate_note(p_store uuid, p_title text, p_body text, p_days integer DEFAULT 14)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  v_title text := app_sec.norm_text(p_title);
  v_body text := app_sec.norm_text(coalesce(p_body, ''));
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
    UPDATE memory SET last_confirmed_at = now() WHERE id = v_id;
  END IF;
  RETURN v_id;
END $$;

GRANT EXECUTE ON FUNCTION app_sec.reconfirm_duplicate_note(uuid, text, text, integer) TO app_rw;
