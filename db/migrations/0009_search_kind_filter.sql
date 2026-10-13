-- Forward migration 0009: app_sec.search filters by kind inside the function, before its 50-row limit.
-- Function body is copied from db/schema.sql (the schema-drift job compares the two).

DROP FUNCTION app_sec.search(text, uuid[], memory_status[]);
CREATE FUNCTION app_sec.search(
  p_query text,
  p_stores uuid[] DEFAULT null,
  p_statuses memory_status[] DEFAULT ARRAY['active']::memory_status[],
  p_kinds memory_kind[] DEFAULT null
) RETURNS TABLE (id uuid, store_id uuid, kind memory_kind, title text, status memory_status, score real)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
#variable_conflict use_column
DECLARE v_tsq tsquery;
BEGIN
  IF length(p_query) > 1000 THEN
    RAISE EXCEPTION 'search query too long: at most 1000 characters' USING ERRCODE = '22023';
  END IF;
  v_tsq := websearch_to_tsquery('simple', p_query);
  IF numnode(v_tsq) > 64 THEN
    RAISE EXCEPTION 'search query too complex: at most 64 tsquery nodes' USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  WITH q AS (SELECT v_tsq AS tsq)
    SELECT m.id, m.store_id, m.kind, m.title, m.status, ts_rank(m.search_tsv, q.tsq) AS score
    FROM q, memory AS m
    WHERE
      m.tenant_id = app_sec.ctx_tenant()
      AND m.search_tsv @@ q.tsq
      AND (p_stores IS NULL OR m.store_id = ANY (p_stores))
      AND m.status = ANY (coalesce(p_statuses, ARRAY['active']::memory_status[]))
      AND (p_kinds IS NULL OR m.kind = ANY (p_kinds))
      AND (
        (m.status IN ('active', 'provisional', 'superseded', 'expired') AND m.store_id IN (SELECT app_sec.my_stores('reader')))
        OR m.store_id IN (SELECT app_sec.my_stores('curator'))
        OR (
          m.status = 'proposed' AND coalesce(m.on_behalf_of, m.created_by) = app_sec.ctx_user()
          AND m.store_id IN (SELECT app_sec.my_stores('reader'))
        )
      )
    ORDER BY score DESC, m.id
    LIMIT 50;
END $$;
REVOKE ALL ON FUNCTION app_sec.search(text, uuid[], memory_status[], memory_kind[]) FROM public, app_rw;
GRANT EXECUTE ON FUNCTION app_sec.search(text, uuid[], memory_status[], memory_kind[]) TO app_rw;
