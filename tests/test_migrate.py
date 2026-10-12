import hashlib
from pathlib import Path

import psycopg
import pytest
from hypothesis import given
from hypothesis import strategies as st

from nunchi import migrate as m
from tests.conftest import REPO


def mig(version: str, body: bytes = b"SELECT 1") -> m.Migration:
    return m.Migration(version, body, hashlib.sha256(body).hexdigest())


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
    with pytest.raises(m.MigrationError, match="share a version"):
        m.load_migrations(tmp_path)


@pytest.fixture
def migrations(tmp_path: Path) -> Path:
    (tmp_path / "0001_t.sql").write_text("CREATE TABLE t (id int);\nINSERT INTO t VALUES (1);\n")
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
    with psycopg.connect(fresh_db) as conn:
        assert m.migrate(conn, migrations) == ["0001", "0002"]
        assert conn.execute("SELECT sum(id) FROM t").fetchone() == (3,)


@pytest.mark.db
def test_tampered_applied_migration_is_refused(fresh_db: str, migrations: Path) -> None:
    with psycopg.connect(fresh_db) as conn:
        m.migrate(conn, migrations)
        (migrations / "0001_t.sql").write_text("CREATE TABLE t (id int, extra int);\n")
        with pytest.raises(m.MigrationError, match="0001 was edited"):
            m.migrate(conn, migrations)


@pytest.mark.db
def test_failing_migration_rolls_back_everything(fresh_db: str, migrations: Path) -> None:
    (migrations / "0002_bad.sql").write_text("INSERT INTO t VALUES (2);\nSELECT nope();\n")
    with psycopg.connect(fresh_db) as conn:
        with pytest.raises(psycopg.errors.UndefinedFunction):
            m.migrate(conn, migrations)
        assert conn.execute("SELECT to_regclass('t')").fetchone() == (None,)


@pytest.mark.db
def test_main_applies_baseline_and_reports(
    fresh_db: str, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("NUNCHI_DATABASE_URL", fresh_db)
    monkeypatch.setenv("NUNCHI_MIGRATIONS_DIR", str(REPO / "db" / "migrations"))
    assert m.main() == 0
    assert "applied ['0001']" in capsys.readouterr().out
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
    assert m.main() == 1
    assert "0001 was edited" in capsys.readouterr().err
