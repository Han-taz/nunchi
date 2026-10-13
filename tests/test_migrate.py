import hashlib
import secrets
from pathlib import Path

import psycopg
import pytest
from hypothesis import given
from hypothesis import strategies as st

from nunchi import migrate as m
from tests.conftest import REPO


def seal(directory: Path) -> None:
    """Write SHA256SUMS the way `shasum -a 256 *.sql > SHA256SUMS` does."""
    lines = [
        f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}"
        for p in sorted(directory.glob("*.sql"))
    ]
    (directory / "SHA256SUMS").write_text("\n".join(lines) + "\n")


def mig(version: str, body: bytes = b"SELECT 1") -> m.Migration:
    return m.Migration(version, f"{version}_x.sql", body, hashlib.sha256(body).hexdigest())


@given(st.integers(min_value=0, max_value=6), st.integers(min_value=0, max_value=6))
def test_pending_is_exactly_the_unapplied_suffix(total: int, done: int) -> None:
    disk = [mig(f"{i:04d}", str(i).encode()) for i in range(1, total + 1)]
    applied = {x.version: x.checksum for x in disk[:done]}
    assert m.pending(disk, applied) == disk[done:]


@given(st.integers(min_value=1, max_value=6), st.data())
def test_any_edited_applied_migration_is_refused(total: int, data: st.DataObject) -> None:
    disk = [mig(f"{i:04d}", str(i).encode()) for i in range(1, total + 1)]
    applied = {x.version: x.checksum for x in disk}
    victim = data.draw(st.sampled_from(sorted(applied)))
    applied[victim] = "0" * 64
    with pytest.raises(m.MigrationError, match=f"{victim} was edited"):
        m.pending(disk, applied)


def test_applied_file_that_vanished_is_refused() -> None:
    with pytest.raises(m.MigrationError, match="0002 is applied but its file is gone"):
        m.pending([mig("0001")], {"0001": mig("0001").checksum, "0002": "x"})


def test_new_migration_sorting_before_an_applied_one_is_refused() -> None:
    disk = [mig("0001"), mig("0002")]
    with pytest.raises(m.MigrationError, match="0001 sorts before"):
        m.pending(disk, {"0002": disk[1].checksum})


def test_load_orders_by_version_and_hashes_bytes(tmp_path: Path) -> None:
    (tmp_path / "0002_b.sql").write_bytes(b"SELECT 2;\n")
    (tmp_path / "0001_a.sql").write_bytes(b"SELECT 1;\n")
    seal(tmp_path)
    loaded = m.load_migrations(tmp_path)
    assert [x.version for x in loaded] == ["0001", "0002"]
    assert loaded[0].checksum == hashlib.sha256(b"SELECT 1;\n").hexdigest()


def test_load_rejects_badly_named_file(tmp_path: Path) -> None:
    (tmp_path / "baseline.sql").write_text("SELECT 1;")
    with pytest.raises(m.MigrationError, match=r"NNNN_slug\.sql"):
        m.load_migrations(tmp_path)


def test_load_rejects_duplicate_version(tmp_path: Path) -> None:
    (tmp_path / "0001_a.sql").write_text("SELECT 1;")
    (tmp_path / "0001_b.sql").write_text("SELECT 2;")
    with pytest.raises(m.MigrationError, match=r"^two migration files share a version number$"):
        m.load_migrations(tmp_path)


def test_load_refuses_a_file_edited_without_resealing(tmp_path: Path) -> None:
    (tmp_path / "0001_a.sql").write_text("SELECT 1;\n")
    (tmp_path / "0002_b.sql").write_text("SELECT 2;\n")
    seal(tmp_path)
    (tmp_path / "0002_b.sql").write_text("SELECT 3;\n")
    with pytest.raises(
        m.MigrationError, match=r"SHA256SUMS does not match the migration files: 0002_b\.sql$"
    ):
        m.load_migrations(tmp_path)


def test_load_refuses_a_file_missing_from_the_manifest(tmp_path: Path) -> None:
    (tmp_path / "0001_a.sql").write_text("SELECT 1;\n")
    seal(tmp_path)
    (tmp_path / "0002_b.sql").write_text("SELECT 2;\n")
    with pytest.raises(m.MigrationError, match=r"files: 0002_b\.sql$"):
        m.load_migrations(tmp_path)


def test_load_refuses_a_manifest_entry_without_a_file(tmp_path: Path) -> None:
    (tmp_path / "0001_a.sql").write_text("SELECT 1;\n")
    (tmp_path / "0002_b.sql").write_text("SELECT 2;\n")
    seal(tmp_path)
    (tmp_path / "0002_b.sql").unlink()
    with pytest.raises(m.MigrationError, match=r"files: 0002_b\.sql$"):
        m.load_migrations(tmp_path)


def test_load_refuses_a_missing_manifest(tmp_path: Path) -> None:
    (tmp_path / "0001_a.sql").write_text("SELECT 1;\n")
    with pytest.raises(m.MigrationError, match=r"^SHA256SUMS is missing$"):
        m.load_migrations(tmp_path)


@pytest.mark.parametrize("line", ["nothing", "abc  0001_a.sql", f"{'0' * 64}  "])
def test_load_refuses_a_malformed_manifest(tmp_path: Path, line: str) -> None:
    (tmp_path / "0001_a.sql").write_text("SELECT 1;\n")
    (tmp_path / "SHA256SUMS").write_text(line + "\n")
    with pytest.raises(m.MigrationError, match="malformed or duplicate line"):
        m.load_migrations(tmp_path)


def test_load_refuses_a_duplicate_manifest_entry(tmp_path: Path) -> None:
    (tmp_path / "0001_a.sql").write_text("SELECT 1;\n")
    seal(tmp_path)
    line = (tmp_path / "SHA256SUMS").read_text()
    (tmp_path / "SHA256SUMS").write_text(line + line)
    with pytest.raises(m.MigrationError, match="malformed or duplicate line"):
        m.load_migrations(tmp_path)


@pytest.fixture
def migrations(tmp_path: Path) -> Path:
    (tmp_path / "0001_t.sql").write_text("CREATE TABLE t (id int);\nINSERT INTO t VALUES (1);\n")
    seal(tmp_path)
    return tmp_path


@pytest.mark.db
def test_apply_then_reapply_is_a_noop(fresh_db: str, migrations: Path) -> None:
    with psycopg.connect(fresh_db) as conn:
        assert m.migrate(conn, migrations) == ["0001"]
        assert m.migrate(conn, migrations) == []
        assert conn.execute("SELECT count(*) FROM t").fetchone() == (1,)
        row = conn.execute("SELECT version, checksum FROM schema_migrations").fetchall()
    assert row == [("0001", hashlib.sha256((migrations / "0001_t.sql").read_bytes()).hexdigest())]


@pytest.mark.db
def test_later_migration_applies_after_earlier(fresh_db: str, migrations: Path) -> None:
    (migrations / "0002_u.sql").write_text("INSERT INTO t VALUES (2);\n")
    seal(migrations)
    with psycopg.connect(fresh_db) as conn:
        assert m.migrate(conn, migrations) == ["0001", "0002"]
        assert conn.execute("SELECT sum(id) FROM t").fetchone() == (3,)


@pytest.mark.db
def test_tampered_applied_migration_is_refused(fresh_db: str, migrations: Path) -> None:
    with psycopg.connect(fresh_db) as conn:
        m.migrate(conn, migrations)
        (migrations / "0001_t.sql").write_text("CREATE TABLE t (id int, extra int);\n")
        seal(migrations)
        with pytest.raises(m.MigrationError, match="0001 was edited"):
            m.migrate(conn, migrations)


@pytest.mark.db
def test_failing_migration_rolls_back_everything(fresh_db: str, migrations: Path) -> None:
    (migrations / "0002_bad.sql").write_text("INSERT INTO t VALUES (2);\nSELECT nope();\n")
    seal(migrations)
    with psycopg.connect(fresh_db) as conn:
        with pytest.raises(m.MigrationError, match=r"^0002_bad\.sql: .*nope\(\)"):
            m.migrate(conn, migrations)
        assert conn.execute("SELECT to_regclass('t')").fetchone() == (None,)


@pytest.mark.db
def test_main_applies_baseline_and_reports(
    fresh_db: str, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("NUNCHI_DATABASE_URL", fresh_db)
    monkeypatch.setenv("NUNCHI_MIGRATIONS_DIR", str(REPO / "db" / "migrations"))
    assert m.main() == 0
    versions = sorted(f.name[:4] for f in (REPO / "db" / "migrations").glob("*.sql"))
    assert f"applied {versions}" in capsys.readouterr().out
    assert m.main() == 0
    assert "applied nothing" in capsys.readouterr().out
    with psycopg.connect(fresh_db) as conn:
        assert conn.execute("SELECT to_regclass('memory')").fetchone() == ("memory",)


@pytest.mark.db
def test_main_exits_nonzero_on_tamper(
    fresh_db: str,
    migrations: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setenv("NUNCHI_DATABASE_URL", fresh_db)
    monkeypatch.setenv("NUNCHI_MIGRATIONS_DIR", str(migrations))
    assert m.main() == 0
    (migrations / "0001_t.sql").write_text("SELECT 1;\n")
    seal(migrations)
    assert m.main() == 1
    assert "0001 was edited" in capsys.readouterr().err


@pytest.mark.db
def test_setup_failure_names_the_setup_step(fresh_db: str, migrations: Path) -> None:
    with psycopg.connect(fresh_db, autocommit=True) as conn:
        conn.execute("SET default_transaction_read_only = on")
        with pytest.raises(m.MigrationError, match=r"^schema_migrations setup: .*read-only"):
            m.migrate(conn, migrations)


@pytest.mark.db
def test_main_names_the_failing_file_and_exits_one(
    fresh_db: str,
    migrations: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    (migrations / "0002_bad.sql").write_text("SELECT nope();\n")
    seal(migrations)
    monkeypatch.setenv("NUNCHI_DATABASE_URL", fresh_db)
    monkeypatch.setenv("NUNCHI_MIGRATIONS_DIR", str(migrations))
    assert m.main() == 1
    err = capsys.readouterr().err
    assert err.startswith("migrate: 0002_bad.sql: ")
    assert "nope" in err


def test_main_reports_an_unreachable_database(
    migrations: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("NUNCHI_DATABASE_URL", "postgres://u:p@127.0.0.1:1/db?connect_timeout=2")
    monkeypatch.setenv("NUNCHI_MIGRATIONS_DIR", str(migrations))
    assert m.main() == 1
    assert capsys.readouterr().err.startswith("migrate: database error: ")


_PREFIX = "CREATE TABLE a (i int);\n"
_COMMITTING_PROC = (
    "CREATE PROCEDURE p() LANGUAGE plpgsql AS $$ BEGIN COMMIT; END $$;\n"
    "CREATE TABLE a (i int);\nCALL p();\n"
)
_ATOMIC_DOMAIN = "CREATE DOMAIN atomic AS int; CREATE TABLE a (i int, begin atomic);\n"

# Each entry is one migration file that creates table `a` and then tries to leave
# or outlive the runner's transaction. The server must refuse it; nothing may stay.
_HOSTILE = {
    "commit": _PREFIX + "COMMIT;\nSELECT 1/0;",
    "commit-and-chain": _PREFIX + "COMMIT AND CHAIN;\nSELECT 1/0;",
    "commit-and-no-chain": _PREFIX + "COMMIT AND NO CHAIN;\nSELECT 1/0;",
    "commit-work": _PREFIX + "COMMIT WORK;\nSELECT 1/0;",
    "end": _PREFIX + "END;\nSELECT 1/0;",
    "end-transaction": _PREFIX + "end transaction;\nSELECT 1/0;",
    "abort": _PREFIX + "ABORT;\nSELECT 1/0;",
    "rollback": _PREFIX + "ROLLBACK;\nSELECT 1/0;",
    "begin": _PREFIX + "BEGIN;\nCOMMIT;\nSELECT 1/0;",
    "start-transaction": _PREFIX + "START TRANSACTION;\nCOMMIT;\nSELECT 1/0;",
    "savepoint": _PREFIX + "SAVEPOINT s;\nSELECT 1/0;",
    "release": _PREFIX + "SAVEPOINT s; RELEASE s;\nSELECT 1/0;",
    "rollback-to": _PREFIX + "SAVEPOINT s; ROLLBACK TO s;\nSELECT 1/0;",
    "prepare-transaction": _PREFIX + "PREPARE TRANSACTION 'x';\nSELECT 1/0;",
    "commit-prepared": _PREFIX + "COMMIT PREPARED 'x';\nSELECT 1/0;",
    "rollback-prepared": _PREFIX + "ROLLBACK PREPARED 'x';\nSELECT 1/0;",
    "vacuum": _PREFIX + "VACUUM;\nSELECT 1/0;",
    "vacuum-table": _PREFIX + "VACUUM (ANALYZE) a;\nSELECT 1/0;",
    "create-index-concurrently": _PREFIX + "CREATE INDEX CONCURRENTLY i ON a (i);",
    "create-unique-index-concurrently": _PREFIX + "CREATE UNIQUE INDEX CONCURRENTLY i ON a (i);",
    "drop-index-concurrently": _PREFIX + "CREATE INDEX i ON a (i); DROP INDEX CONCURRENTLY i;",
    "reindex-concurrently": _PREFIX + "CREATE INDEX i ON a (i); REINDEX INDEX CONCURRENTLY i;",
    "reindex-option-concurrently": _PREFIX + "REINDEX (CONCURRENTLY) TABLE a;",
    "call-committing-procedure": _COMMITTING_PROC,
    "do-commit": _PREFIX + "DO $$ BEGIN COMMIT; END $$;\nSELECT 1/0;",
    "do-rollback": _PREFIX + "DO $$ BEGIN ROLLBACK; END $$;\nSELECT 1/0;",
    "do-execute-commit": _PREFIX + "DO $$ BEGIN EXECUTE 'COMMIT'; END $$;\nSELECT 1/0;",
    "fake-begin-atomic-end": _ATOMIC_DOMAIN + "END;\nSELECT 1/0;",
    "fake-begin-atomic-commit": _ATOMIC_DOMAIN + "COMMIT;\nSELECT 1/0;",
    "after-real-begin-atomic": (
        "CREATE FUNCTION g() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; END;\n"
        + _PREFIX
        + "END;\nSELECT 1/0;"
    ),
    "comment-hides-nothing": _PREFIX + "-- note\n/* x */ COMMIT;\nSELECT 1/0;",
    "after-string": _PREFIX + "SELECT 'a'; COMMIT;\nSELECT 1/0;",
    "after-escape-string": _PREFIX + "SELECT E'it\\'s'; COMMIT;\nSELECT 1/0;",
    "after-doubled-quote": _PREFIX + "SELECT 'it''s'; COMMIT;\nSELECT 1/0;",
    "after-dollar-quote": _PREFIX + "SELECT $t$x$t$; COMMIT;\nSELECT 1/0;",
    "after-escape-quote": _PREFIX + "SELECT E'\\''; COMMIT; SELECT ''\nSELECT 1/0;",
    "psql-gexec": _PREFIX + "SELECT 'COMMIT' \\gexec\nSELECT 1/0;",
    "psql-semicolon": _PREFIX + "SELECT 1 \\; COMMIT;\nSELECT 1/0;",
}


def assert_nothing_persisted(url: str) -> None:
    with psycopg.connect(url) as check:
        assert check.execute("SELECT to_regclass('a')").fetchone() == (None,)
        if check.execute("SELECT to_regclass('schema_migrations')").fetchone() != (None,):
            assert check.execute("SELECT count(*) FROM schema_migrations").fetchone() == (0,)


@pytest.mark.db
@pytest.mark.parametrize("sql", list(_HOSTILE.values()), ids=list(_HOSTILE))
def test_server_refuses_what_the_runner_transaction_cannot_hold(
    fresh_db: str, tmp_path: Path, sql: str
) -> None:
    (tmp_path / "0001_a.sql").write_text(sql)
    seal(tmp_path)
    with (
        psycopg.connect(fresh_db) as conn,
        pytest.raises(m.MigrationError, match=r"^0001_a\.sql: "),
    ):
        m.migrate(conn, tmp_path)
    assert_nothing_persisted(fresh_db)


@pytest.mark.db
def test_refusal_message_comes_from_the_server_and_names_the_file(
    fresh_db: str, tmp_path: Path
) -> None:
    (tmp_path / "0001_ok.sql").write_text("SELECT 1;")
    (tmp_path / "0002_end.sql").write_text(_PREFIX + "END;")
    seal(tmp_path)
    with psycopg.connect(fresh_db) as conn, pytest.raises(m.MigrationError) as err:
        m.migrate(conn, tmp_path)
    assert str(err.value).startswith(
        "0002_end.sql: EXECUTE of transaction commands is not implemented"
    )
    assert_nothing_persisted(fresh_db)


# Session settings an earlier file leaves behind must not change how a later file is read.
# The payload is one harmless string literal when read with standard_conforming_strings = on,
# and `'a\\'` followed by a live COMMIT when read with it off.
_PAYLOAD = "CREATE TABLE a (i int); SELECT 'a\\'\n'; COMMIT; SELECT 1/0; --'"


@pytest.mark.db
@pytest.mark.parametrize(
    "setting",
    [
        "SET standard_conforming_strings = off",
        "SET LOCAL standard_conforming_strings = off",
        "SELECT set_config('standard_conforming_strings', 'off', true)",
        "SELECT set_config('standard_conforming_strings', 'off', false)",
        "SET backslash_quote = on; SET standard_conforming_strings = off",
    ],
)
def test_earlier_file_cannot_change_how_a_later_file_is_lexed(
    fresh_db: str, tmp_path: Path, setting: str
) -> None:
    (tmp_path / "0001_set.sql").write_text(setting + ";\n")
    (tmp_path / "0002_payload.sql").write_text(_PAYLOAD)
    (tmp_path / "0003_fail.sql").write_text("SELECT 1/0;\n")
    seal(tmp_path)
    with (
        psycopg.connect(fresh_db) as conn,
        pytest.raises(m.MigrationError, match=r"^0003_fail\.sql: .*division by zero"),
    ):
        m.migrate(conn, tmp_path)
    assert_nothing_persisted(fresh_db)


@pytest.mark.db
def test_payload_is_only_a_string_when_read_the_standard_way(fresh_db: str, tmp_path: Path) -> None:
    (tmp_path / "0001_set.sql").write_text("SET standard_conforming_strings = off;\n")
    (tmp_path / "0002_payload.sql").write_text(_PAYLOAD)
    seal(tmp_path)
    with psycopg.connect(fresh_db) as conn:
        assert m.migrate(conn, tmp_path) == ["0001", "0002"]
        assert conn.execute("SELECT to_regclass('a')").fetchone() == ("a",)


@pytest.mark.db
def test_file_text_that_contains_dollar_quote_tags_runs_verbatim(
    fresh_db: str, tmp_path: Path
) -> None:
    body = "CREATE TABLE a (i int);\nINSERT INTO a VALUES (1);\nSELECT $do$x$do$, $$y$$, '$';\n-- $"
    (tmp_path / "0001_a.sql").write_text(body)
    seal(tmp_path)
    with psycopg.connect(fresh_db) as conn:
        assert m.migrate(conn, tmp_path) == ["0001"]
        assert conn.execute("SELECT count(*) FROM a").fetchone() == (1,)


@pytest.mark.parametrize("sql", ["SELECT 1;\n", "-- BEGIN; COMMIT; CONCURRENTLY\nSELECT 1;\n"])
def test_load_does_not_judge_sql_text(tmp_path: Path, sql: str) -> None:
    (tmp_path / "0001_a.sql").write_text(sql)
    seal(tmp_path)
    assert [x.version for x in m.load_migrations(tmp_path)] == ["0001"]


def test_load_rejects_invalid_utf8(tmp_path: Path) -> None:
    (tmp_path / "0001_a.sql").write_bytes(b"SELECT '\xff';")
    seal(tmp_path)
    with pytest.raises(m.MigrationError, match=r"^0001_a\.sql: not valid UTF-8$"):
        m.load_migrations(tmp_path)


@pytest.mark.db
def test_all_frozen_migrations_apply_through_the_runner(fresh_db: str) -> None:
    files = sorted((REPO / "db" / "migrations").glob("*.sql"))
    with psycopg.connect(fresh_db) as conn:
        assert m.migrate(conn, REPO / "db" / "migrations") == [f.name[:4] for f in files]


@pytest.mark.db
def test_refresh_concurrently_is_legal_in_a_transaction_so_it_is_allowed(
    fresh_db: str, tmp_path: Path
) -> None:
    sql = (
        "CREATE TABLE a (k int); INSERT INTO a VALUES (1);"
        " CREATE MATERIALIZED VIEW v AS SELECT k FROM a; CREATE UNIQUE INDEX ON v (k);"
        " REFRESH MATERIALIZED VIEW CONCURRENTLY v;"
    )
    (tmp_path / "0001_a.sql").write_text(sql)
    seal(tmp_path)
    with psycopg.connect(fresh_db) as conn:
        assert m.migrate(conn, tmp_path) == ["0001"]


@pytest.mark.db
def test_a_file_that_contains_the_first_random_tag_still_runs_verbatim(
    fresh_db: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    draws = iter(["aaaaaaaaaaaaaaaa", "aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb", "cccccccccccccccc"])
    monkeypatch.setattr(secrets, "token_hex", lambda _n: next(draws))
    (tmp_path / "0001_a.sql").write_text(
        "CREATE TABLE a (s text); INSERT INTO a VALUES ($maaaaaaaaaaaaaaaa$x$maaaaaaaaaaaaaaaa$);"
    )
    seal(tmp_path)
    with psycopg.connect(fresh_db) as conn:
        assert m.migrate(conn, tmp_path) == ["0001"]
        assert conn.execute("SELECT s FROM a").fetchone() == ("x",)
