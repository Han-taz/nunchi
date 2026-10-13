-- Forward migration 0016: nunchi_worker, the freshness worker's own DB role (replaces the owner URL in compose).
-- The role and grants are copied from db/schema.sql (the schema-drift job compares the two).

-- ── 워커 접속 역할: 기본은 NOLOGIN. 로그인 비밀번호는 배포(compose seed)가 ALTER ROLE 로 건다. 표 권한은 없고 아래 두 함수의 EXECUTE 뿐이다 ──
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nunchi_worker') THEN
    CREATE ROLE nunchi_worker NOLOGIN NOBYPASSRLS NOINHERIT;
  ELSE
    ALTER ROLE nunchi_worker NOBYPASSRLS NOINHERIT;
  END IF;
END $$;

GRANT USAGE ON SCHEMA app_sec TO nunchi_worker;
GRANT EXECUTE ON FUNCTION app_sec.mark_expired() TO nunchi_worker;
GRANT EXECUTE ON FUNCTION app_sec.stale_memories(integer) TO nunchi_worker;
