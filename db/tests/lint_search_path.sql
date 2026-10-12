-- S1: every function in public and app_sec pins search_path, with pg_temp last.
-- Without the pin, a TEMP table or function created by the caller shadows the schema's own objects.
-- Functions owned by extensions (pgcrypto) are not ours to pin.
WITH fn AS (
  SELECT
    p.oid::regprocedure::text AS name,
    coalesce(
      bool_or(c ~ '^search_path=pg_catalog, .*pg_temp$'), false
    ) AS pinned
  FROM pg_proc AS p
  INNER JOIN pg_namespace AS n ON p.pronamespace = n.oid
  LEFT JOIN LATERAL unnest(p.proconfig) AS c ON true
  WHERE
    n.nspname IN ('public', 'app_sec')
    AND p.prokind IN ('f', 'p')
    AND NOT EXISTS (
      SELECT 1 FROM pg_depend AS d
      WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e'
    )
  GROUP BY p.oid
)

SELECT
  CASE
    WHEN count(*) = 0 THEN 'S1 FAIL: no functions found to lint'
    WHEN count(*) FILTER (WHERE NOT pinned) = 0
      THEN 'S1 search_path pinned on all ' || count(*) || ' functions (ok)'
    ELSE 'S1 FAIL: unpinned ' || string_agg(name, ', ' ORDER BY name) FILTER (WHERE NOT pinned)
  END
FROM fn;
