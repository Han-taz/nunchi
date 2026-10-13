import os
import uuid
from collections.abc import Iterator
from pathlib import Path

import psycopg
import pytest
from hypothesis import settings
from psycopg import sql
from psycopg_pool import ConnectionPool

from nunchi import migrate
from nunchi.config import Settings
from nunchi.db import open_pool

REPO = Path(__file__).resolve().parent.parent

settings.register_profile("default", max_examples=100)
settings.register_profile("nightly", max_examples=3000, deadline=None)
settings.load_profile(os.environ.get("NUNCHI_HYPOTHESIS_PROFILE", "default"))
APP_ROLE = "nunchi_test_app"


@pytest.fixture(scope="session")
def admin_url() -> str:
    url = os.environ.get("NUNCHI_TEST_ADMIN_URL")
    if url is None:
        pytest.skip("NUNCHI_TEST_ADMIN_URL is not set")
    return url


@pytest.fixture
def fresh_db(admin_url: str) -> Iterator[str]:
    """A new empty database on the test server. Yields its superuser URL."""
    name = f"nunchi_t_{uuid.uuid4().hex[:12]}"
    base, _, query = admin_url.partition("?")
    with psycopg.connect(admin_url, autocommit=True) as admin:
        admin.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(name)))
        try:
            suffix = f"?{query}" if query else ""
            yield f"{base.rsplit('/', 1)[0]}/{name}{suffix}"
        finally:
            admin.execute(sql.SQL("DROP DATABASE {} WITH (FORCE)").format(sql.Identifier(name)))


USER = uuid.UUID("00000000-0000-0000-0000-0000000000a1")
OTHER = uuid.UUID("00000000-0000-0000-0000-0000000000a2")
AGENT = uuid.UUID("00000000-0000-0000-0000-0000000000b1")
AGENT_NO_GRANT = uuid.UUID("00000000-0000-0000-0000-0000000000b2")
TENANT = uuid.UUID("00000000-0000-0000-0000-0000000000c1")
STORE = uuid.UUID("00000000-0000-0000-0000-0000000000d1")


def app_url(superuser_url: str) -> str:
    return superuser_url.replace("postgres:postgres@", f"{APP_ROLE}:app@", 1)


@pytest.fixture
def seeded(fresh_db: str, admin_url: str) -> Iterator[str]:
    """A migrated database with one active memory that only USER can read. Yields the app URL."""
    with psycopg.connect(fresh_db) as conn:
        migrate.migrate(conn, REPO / "db" / "migrations")
        conn.execute("INSERT INTO tenant (id, name) VALUES (%s, 't')", (TENANT,))
        for pid, kind in (
            (USER, "user"),
            (OTHER, "user"),
            (AGENT, "agent"),
            (AGENT_NO_GRANT, "agent"),
        ):
            conn.execute(
                "INSERT INTO principal (id, tenant_id, kind, external_id, display_name)"
                " VALUES (%s, %s, %s, %s, 'x')",
                (pid, TENANT, kind, str(pid)),
            )
        conn.execute(
            "INSERT INTO store (id, tenant_id, kind, slug, description)"
            " VALUES (%s, %s, 'team', 's', 'd')",
            (STORE, TENANT),
        )
        conn.execute(
            "INSERT INTO store_grant (store_id, principal_id, role, tenant_id)"
            " VALUES (%s, %s, 'contributor', %s), (%s, %s, 'reader', %s)",
            (STORE, USER, TENANT, STORE, AGENT, TENANT),
        )
        conn.execute(
            "INSERT INTO memory (tenant_id, store_id, kind, status, title, created_by)"
            " VALUES (%s, %s, 'note', 'active', 'hello', %s)",
            (TENANT, STORE, USER),
        )
    with psycopg.connect(admin_url, autocommit=True) as admin:
        admin.execute(sql.SQL("DROP ROLE IF EXISTS {}").format(sql.Identifier(APP_ROLE)))
        admin.execute(
            sql.SQL("CREATE ROLE {} LOGIN PASSWORD 'app' IN ROLE app_rw").format(
                sql.Identifier(APP_ROLE)
            )
        )
        try:
            yield app_url(fresh_db)
        finally:
            admin.execute(sql.SQL("DROP ROLE {}").format(sql.Identifier(APP_ROLE)))


@pytest.fixture
def pool(seeded: str) -> Iterator[ConnectionPool[psycopg.Connection[tuple[object, ...]]]]:
    settings = Settings(database_url=seeded, pool_max_size=2)
    opened = open_pool(settings)
    yield opened
    opened.close()
