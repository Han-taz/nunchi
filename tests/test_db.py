import uuid

import psycopg
import pytest
from psycopg_pool import ConnectionPool, PoolTimeout

from nunchi.config import Settings
from nunchi.db import bind_identity, open_pool, request_tx
from tests.conftest import AGENT, AGENT_NO_GRANT, OTHER, STORE, TENANT, USER


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


@pytest.mark.db
def test_agent_without_a_grant_sees_nothing(
    pool: ConnectionPool[psycopg.Connection[tuple[object, ...]]],
) -> None:
    assert count_visible(pool, USER, None) == 1
    assert count_visible(pool, USER, AGENT_NO_GRANT) == 0


@pytest.mark.db
def test_bind_identity_carries_the_agent(
    pool: ConnectionPool[psycopg.Connection[tuple[object, ...]]],
) -> None:
    with pool.connection() as conn, conn.transaction():
        bind_identity(conn, USER, AGENT)
        row = conn.execute("SELECT app_sec.ctx_user(), app_sec.ctx_agent()").fetchone()
    assert row == (USER, AGENT)


def test_open_pool_gives_up_when_the_server_is_unreachable() -> None:
    settings = Settings(
        database_url="postgresql://u:p@127.0.0.1:1/db",
        db_pool_timeout=0.5,
        db_connect_timeout=1,
    )
    with pytest.raises(PoolTimeout):
        open_pool(settings)


@pytest.mark.db
def test_a_connection_the_server_killed_is_replaced(seeded: str, admin_url: str) -> None:
    pool = open_pool(Settings(database_url=seeded, pool_min_size=1, pool_max_size=1))
    try:
        with pool.connection() as conn:
            row = conn.execute("SELECT pg_backend_pid()").fetchone()
        assert row is not None
        with psycopg.connect(admin_url, autocommit=True) as admin:
            admin.execute("SELECT pg_terminate_backend(%s)", (row[0],))
        assert count_visible(pool, USER, None) == 1
    finally:
        pool.close()
