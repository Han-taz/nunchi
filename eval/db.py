"""A throwaway database: migrated, seeded with one tenant, store, curator and contributor."""

import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import psycopg
from psycopg import sql

from nunchi import migrate

MIGRATIONS = Path(__file__).resolve().parent.parent / "db" / "migrations"
TENANT = uuid.UUID("00000000-0000-0000-0000-0000000000c1")
STORE = uuid.UUID("00000000-0000-0000-0000-0000000000d1")
CONTRIBUTOR = uuid.UUID("00000000-0000-0000-0000-0000000000a1")
CURATORS = (
    uuid.UUID("00000000-0000-0000-0000-0000000000a2"),
    uuid.UUID("00000000-0000-0000-0000-0000000000a3"),
)
_PASSWORD = "eval"  # noqa: S105 - role of a database that exists for one run


def _with(admin_url: str, *, database: str, user: str | None = None) -> str:
    parts = urlsplit(admin_url)
    host = parts.netloc.rpartition("@")[2]
    netloc = f"{user}:{_PASSWORD}@{host}" if user else parts.netloc
    return urlunsplit(parts._replace(netloc=netloc, path=f"/{database}"))


def _seed(conn: psycopg.Connection[tuple[object, ...]]) -> None:
    conn.execute("INSERT INTO tenant (id, name) VALUES (%s, 'eval')", (TENANT,))
    for pid, name in ((CONTRIBUTOR, "contributor"), *((c, "curator") for c in CURATORS)):
        conn.execute(
            "INSERT INTO principal (id, tenant_id, kind, external_id, display_name)"
            " VALUES (%s, %s, 'user', %s, %s)",
            (pid, TENANT, str(pid), name),
        )
    conn.execute(
        "INSERT INTO store (id, tenant_id, kind, slug, description)"
        " VALUES (%s, %s, 'team', 'eval', 'eval store')",
        (STORE, TENANT),
    )
    conn.execute(
        "INSERT INTO store_grant (store_id, principal_id, role, tenant_id)"
        " VALUES (%s, %s, 'contributor', %s)",
        (STORE, CONTRIBUTOR, TENANT),
    )
    for curator in CURATORS:
        conn.execute(
            "INSERT INTO store_grant (store_id, principal_id, role, tenant_id)"
            " VALUES (%s, %s, 'curator', %s)",
            (STORE, curator, TENANT),
        )


def superuser_url(admin_url: str, app_url: str) -> str:
    """The admin role's URL for the database that `app_url` (from fresh_database) points at."""
    return _with(admin_url, database=urlsplit(app_url).path.lstrip("/"))


@contextmanager
def fresh_database(admin_url: str) -> Iterator[str]:
    """Yield a non-superuser URL (so row-level security applies) to a new seeded database."""
    suffix = uuid.uuid4().hex[:12]
    name, role = f"nunchi_eval_{suffix}", f"nunchi_eval_{suffix}"
    with psycopg.connect(admin_url, autocommit=True) as admin:
        admin.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(name)))
        try:
            with psycopg.connect(_with(admin_url, database=name)) as conn:
                migrate.migrate(conn, MIGRATIONS)
                _seed(conn)
            admin.execute(
                sql.SQL("CREATE ROLE {} LOGIN PASSWORD {} IN ROLE app_rw").format(
                    sql.Identifier(role), sql.Literal(_PASSWORD)
                )
            )
            yield _with(admin_url, database=name, user=role)
        finally:
            admin.execute(
                sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(name))
            )
            admin.execute(sql.SQL("DROP ROLE IF EXISTS {}").format(sql.Identifier(role)))
