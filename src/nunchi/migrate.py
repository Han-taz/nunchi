"""Forward-only SQL migration runner: python -m nunchi.migrate."""

import hashlib
import re
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import cast

import psycopg
from pglast import parse_sql
from pglast.ast import Node, ReindexStmt, TransactionStmt, VacuumStmt
from pglast.enums import TransactionStmtKind
from pglast.parser import ParseError
from pglast.visitors import Visitor

from nunchi.config import Settings

_NAME = re.compile(r"^(\d{4})_[a-z0-9_]+\.sql$")
_MANIFEST = "SHA256SUMS"
_DIGEST = re.compile(r"^[0-9a-f]{64}$")
_LOCK_KEY = 7_262_024_001


class MigrationError(Exception):
    pass


@dataclass(frozen=True)
class Migration:
    version: str
    name: str
    sql: bytes
    checksum: str


def read_manifest(directory: Path) -> dict[str, str]:
    """File name -> sha256 from SHA256SUMS (sha256sum format: digest, two spaces, name)."""
    path = directory / _MANIFEST
    if not path.is_file():
        msg = f"{_MANIFEST} is missing"
        raise MigrationError(msg)
    entries: dict[str, str] = {}
    for line in path.read_text().splitlines():
        digest, _, name = line.partition("  ")
        if _DIGEST.match(digest) is None or not name or name in entries:
            msg = f"{_MANIFEST}: malformed or duplicate line {line!r}"
            raise MigrationError(msg)
        entries[name] = digest
    return entries


class _Unrunnable(Visitor):
    """Records the first statement Postgres refuses to run inside a transaction block."""

    def __init__(self) -> None:
        super().__init__()
        self.found: str | None = None

    def visit(self, ancestors: object, node: Node) -> None:
        if self.found is not None:
            return
        if isinstance(node, TransactionStmt):
            keyword = cast(TransactionStmtKind, node.kind).name.removeprefix("TRANS_STMT_")
            self.found = (
                f"{keyword.replace('_', ' ')} is not allowed; the runner supplies the transaction"
            )
        elif isinstance(node, VacuumStmt) and node.is_vacuumcmd:
            self.found = "VACUUM cannot run inside the runner's transaction"
        elif getattr(node, "concurrent", False) or (
            isinstance(node, ReindexStmt)
            and any(opt.defname == "concurrently" for opt in node.params or ())
        ):
            self.found = "CONCURRENTLY cannot run inside the runner's transaction"


def check_runnable(name: str, sql: bytes) -> None:
    """Refuse SQL that cannot run inside the runner's one transaction per migration.

    Postgres's own parser decides, so no string or comment trick can hide a statement.
    """
    try:
        statements = parse_sql(sql.decode())
    except UnicodeDecodeError as err:
        msg = f"{name}: not valid UTF-8"
        raise MigrationError(msg) from err
    except ParseError as err:
        msg = f"{name}: not parseable as PostgreSQL: {err}"
        raise MigrationError(msg) from err
    visitor = _Unrunnable()
    visitor(statements)
    if visitor.found is not None:
        msg = f"{name}: {visitor.found}"
        raise MigrationError(msg)


def load_migrations(directory: Path) -> list[Migration]:
    """Read the migrations and prove they are exactly the files SHA256SUMS lists, byte for byte."""
    migrations: list[Migration] = []
    actual: dict[str, str] = {}
    for path in sorted(directory.glob("*.sql")):
        match = _NAME.match(path.name)
        if match is None:
            msg = f"{path.name}: migration files are named NNNN_slug.sql"
            raise MigrationError(msg)
        data = path.read_bytes()
        check_runnable(path.name, data)
        checksum = hashlib.sha256(data).hexdigest()
        actual[path.name] = checksum
        migrations.append(Migration(match.group(1), path.name, data, checksum))
    versions = [m.version for m in migrations]
    if len(set(versions)) != len(versions):
        msg = "two migration files share a version number"
        raise MigrationError(msg)
    expected = read_manifest(directory)
    if actual != expected:
        names = sorted(actual.keys() | expected.keys())
        bad = ", ".join(n for n in names if actual.get(n) != expected.get(n))
        msg = f"{_MANIFEST} does not match the migration files: {bad}"
        raise MigrationError(msg)
    return migrations


def pending(disk: Sequence[Migration], applied: Mapping[str, str]) -> list[Migration]:
    """The migrations still to run, after proving the applied ones are untouched."""
    on_disk = {m.version: m for m in disk}
    for version, checksum in applied.items():
        if version not in on_disk:
            msg = f"{version} is applied but its file is gone"
            raise MigrationError(msg)
        if on_disk[version].checksum != checksum:
            msg = f"{version} was edited after it was applied; write a new migration instead"
            raise MigrationError(msg)
    todo = [m for m in disk if m.version not in applied]
    if applied and todo and todo[0].version < max(applied):
        msg = f"{todo[0].version} sorts before an already applied migration"
        raise MigrationError(msg)
    return todo


def migrate(conn: psycopg.Connection[tuple[object, ...]], directory: Path) -> list[str]:
    """Apply pending migrations in order and return their versions. Re-running applies nothing."""
    disk = load_migrations(directory)
    step = "schema_migrations setup"
    try:
        with conn.transaction():
            conn.execute("SELECT pg_advisory_xact_lock(%s)", (_LOCK_KEY,))
            conn.execute(
                "CREATE TABLE IF NOT EXISTS schema_migrations ("
                "version text PRIMARY KEY, checksum text NOT NULL,"
                " applied_at timestamptz NOT NULL DEFAULT now())"
            )
            rows = conn.execute("SELECT version, checksum FROM schema_migrations").fetchall()
            todo = pending(disk, {str(v): str(c) for v, c in rows})
            for migration in todo:
                step = migration.name
                conn.execute(migration.sql)
                conn.execute(
                    "INSERT INTO schema_migrations (version, checksum) VALUES (%s, %s)",
                    (migration.version, migration.checksum),
                )
    except psycopg.Error as err:
        msg = f"{step}: {err}"
        raise MigrationError(msg) from err
    return [m.version for m in todo]


def main() -> int:
    settings = Settings()
    try:
        with psycopg.connect(settings.database_url.get_secret_value()) as conn:
            applied = migrate(conn, settings.migrations_dir)
    except MigrationError as err:
        sys.stderr.write(f"migrate: {err}\n")
        return 1
    except psycopg.Error as err:
        sys.stderr.write(f"migrate: database error: {err}\n")
        return 1
    sys.stdout.write(f"migrate: applied {applied or 'nothing'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
