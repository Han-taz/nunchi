"""Forward-only SQL migration runner: python -m nunchi.migrate."""

import hashlib
import re
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

import psycopg

from nunchi.config import Settings

_NAME = re.compile(r"^(\d{4})_[a-z0-9_]+\.sql$")
_LOCK_KEY = 7_262_024_001


class MigrationError(Exception):
    pass


@dataclass(frozen=True)
class Migration:
    version: str
    sql: bytes
    checksum: str


def load_migrations(directory: Path) -> list[Migration]:
    migrations: list[Migration] = []
    for path in sorted(directory.glob("*.sql")):
        match = _NAME.match(path.name)
        if match is None:
            msg = f"{path.name}: migration files are named NNNN_slug.sql"
            raise MigrationError(msg)
        data = path.read_bytes()
        migrations.append(Migration(match.group(1), data, hashlib.sha256(data).hexdigest()))
    versions = [m.version for m in migrations]
    if len(set(versions)) != len(versions):
        msg = "two migration files share a version number"
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
            conn.execute(migration.sql)
            conn.execute(
                "INSERT INTO schema_migrations (version, checksum) VALUES (%s, %s)",
                (migration.version, migration.checksum),
            )
    return [m.version for m in todo]


def main() -> int:
    settings = Settings()
    with psycopg.connect(settings.database_url.get_secret_value()) as conn:
        try:
            applied = migrate(conn, settings.migrations_dir)
        except MigrationError as err:
            sys.stderr.write(f"migrate: {err}\n")
            return 1
    sys.stdout.write(f"migrate: applied {applied or 'nothing'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
