import uuid
from collections.abc import Iterator

import psycopg
import pytest
from psycopg import sql
from psycopg_pool import ConnectionPool

from nunchi import migrate
from nunchi.config import Settings
from nunchi.db import open_pool, request_tx
from tests.conftest import APP_ROLE, REPO

USER = uuid.UUID("00000000-0000-0000-0000-0000000000a1")
OTHER = uuid.UUID("00000000-0000-0000-0000-0000000000a2")
AGENT = uuid.UUID("00000000-0000-0000-0000-0000000000b1")
TENANT = uuid.UUID("00000000-0000-0000-0000-0000000000c1")
STORE = uuid.UUID("00000000-0000-0000-0000-0000000000d1")


def _app_url(superuser_url: str) -> str:
    return superuser_url.replace("postgres:postgres@", f"{APP_ROLE}:app@", 1)


@pytest.fixture
def seeded(fresh_db: str, admin_url: str) -> Iterator[str]:
    """A migrated database with one active memory that only USER can read. Yields the app URL."""
    with psycopg.connect(fresh_db) as conn:
        migrate.migrate(conn, REPO / "db" / "migrations")
        conn.execute("INSERT INTO tenant (id, name) VALUES (%s, 't')", (TENANT,))
        for pid, kind in ((USER, "user"), (OTHER, "user"), (AGENT, "agent")):
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
            yield _app_url(fresh_db)
        finally:
            admin.execute(sql.SQL("DROP ROLE {}").format(sql.Identifier(APP_ROLE)))


@pytest.fixture
def pool(seeded: str) -> Iterator[ConnectionPool[psycopg.Connection[tuple[object, ...]]]]:
    settings = Settings(database_url=seeded, pool_max_size=2)
    opened = open_pool(settings)
    yield opened
    opened.close()


def count_visible(
    pool: ConnectionPool[psycopg.Connection[tuple[object, ...]]],
    user: uuid.UUID,
    agent: uuid.UUID | None,
) -> object:
    with request_tx(pool, user, agent) as conn:
        row = conn.execute("SELECT count(*) FROM memory").fetchone()
    assert row is not None
    return row[0]


@pytest.mark.db
def test_rls_sees_the_requesting_user(
    pool: ConnectionPool[psycopg.Connection[tuple[object, ...]]],
) -> None:
    assert count_visible(pool, USER, None) == 1
    assert count_visible(pool, OTHER, None) == 0


@pytest.mark.db
def test_agent_is_intersected_with_user(
    pool: ConnectionPool[psycopg.Connection[tuple[object, ...]]],
) -> None:
    assert count_visible(pool, USER, AGENT) == 1
    assert count_visible(pool, OTHER, AGENT) == 0


@pytest.mark.db
def test_identity_does_not_leak_to_the_next_request(
    pool: ConnectionPool[psycopg.Connection[tuple[object, ...]]],
) -> None:
    assert count_visible(pool, USER, None) == 1
    with pool.connection() as conn:
        row = conn.execute("SELECT count(*) FROM memory").fetchone()
    assert row == (0,)


@pytest.mark.db
def test_unknown_user_is_rejected_by_begin_request(
    pool: ConnectionPool[psycopg.Connection[tuple[object, ...]]],
) -> None:
    stranger = uuid.UUID("00000000-0000-0000-0000-0000000000ff")
    with (
        pytest.raises(psycopg.errors.InvalidAuthorizationSpecification),
        request_tx(pool, stranger, None),
    ):
        pass


@pytest.mark.db
def test_exception_rolls_back_the_transaction(
    pool: ConnectionPool[psycopg.Connection[tuple[object, ...]]],
) -> None:
    with pytest.raises(RuntimeError), request_tx(pool, USER, None) as conn:
        conn.execute(
            "INSERT INTO memory (tenant_id, store_id, kind, status, title, created_by)"
            " VALUES (%s, %s, 'note', 'proposed', 'x', %s)",
            (TENANT, STORE, USER),
        )
        raise RuntimeError
    assert count_visible(pool, USER, None) == 1


@pytest.mark.db
def test_open_pool_honours_the_configured_bounds(seeded: str) -> None:
    pool = open_pool(Settings(database_url=seeded, pool_min_size=2, pool_max_size=3))
    try:
        assert (pool.min_size, pool.max_size) == (2, 3)
        assert pool.get_stats()["pool_size"] == 2
    finally:
        pool.close()
