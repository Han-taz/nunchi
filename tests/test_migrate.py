import hashlib
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


@pytest.mark.parametrize(
    ("sql", "message"),
    [
        ("BEGIN;\nSELECT 1;\nCOMMIT;\n", "top-level BEGIN"),
        ("SELECT 1;\ncommit;\n", "top-level COMMIT"),
        ("SELECT 1;\n  Rollback ;\n", "top-level ROLLBACK"),
        ("SELECT 1;\nABORT;\n", "top-level ABORT"),
        ("SELECT 1;\nSTART   TRANSACTION;\n", "top-level START TRANSACTION"),
        ("-- note\n/* x */ BEGIN;\n", "top-level BEGIN"),
        ("SELECT 'a'; COMMIT;", "top-level COMMIT"),
        ("SELECT E'it\\'s'; COMMIT;", "top-level COMMIT"),
        ("SELECT 'it''s'; COMMIT;", "top-level COMMIT"),
        ('SELECT "x"; COMMIT;', "top-level COMMIT"),
        ("SELECT $$x$$; COMMIT;", "top-level COMMIT"),
        ("SELECT $t$x$t$; COMMIT;", "top-level COMMIT"),
        ("CREATE INDEX CONCURRENTLY i ON t (a);\n", "CONCURRENTLY cannot run"),
        ("REFRESH MATERIALIZED VIEW concurrently v;\n", "CONCURRENTLY cannot run"),
        ("SELECT E'\\''; COMMIT; SELECT ''", "top-level COMMIT"),
    ],
)
def test_load_rejects_sql_the_runner_transaction_cannot_hold(
    tmp_path: Path, sql: str, message: str
) -> None:
    (tmp_path / "0001_a.sql").write_text(sql)
    seal(tmp_path)
    with pytest.raises(m.MigrationError, match=rf"^0001_a\.sql: .*{message}"):
        m.load_migrations(tmp_path)


@pytest.mark.parametrize(
    "sql",
    [
        "SELECT 1;\n",
        "DO $$\nBEGIN\n  PERFORM 1;\nEND $$;\n",
        "CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $b$\nBEGIN RETURN 1; END; $b$;\n",
        "-- BEGIN; COMMIT; CONCURRENTLY\nSELECT 1;\n",
        "/* COMMIT; */ SELECT 1;\n",
        "SELECT 'COMMIT; CONCURRENTLY';\n",
        "SELECT E'\\'; COMMIT; --';\n",
        'SELECT 1 AS "commit";\n',
        "SELECT 1 AS begin_at, 2 AS committed;\n",
        "COMMENT ON TABLE t IS 'ROLLBACK is fine here';\n",
        "CREATE FUNCTION g() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; END;\n",
    ],
)
def test_load_accepts_keywords_that_are_only_text(tmp_path: Path, sql: str) -> None:
    (tmp_path / "0001_a.sql").write_text(sql)
    seal(tmp_path)
    assert [x.version for x in m.load_migrations(tmp_path)] == ["0001"]


def test_load_rejects_invalid_utf8(tmp_path: Path) -> None:
    (tmp_path / "0001_a.sql").write_bytes(b"SELECT '\xff';")
    seal(tmp_path)
    with pytest.raises(m.MigrationError, match=r"^0001_a\.sql: not valid UTF-8$"):
        m.load_migrations(tmp_path)
