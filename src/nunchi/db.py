from collections.abc import Iterator
from contextlib import contextmanager
from typing import TypeAlias
from uuid import UUID

import psycopg
from psycopg_pool import ConnectionPool

from nunchi.config import Settings

Conn: TypeAlias = psycopg.Connection[tuple[object, ...]]  # noqa: UP040
Pool: TypeAlias = ConnectionPool[Conn]  # noqa: UP040


def open_pool(settings: Settings) -> Pool:
    """Open the pool and block until min_size connections exist or db_pool_timeout passes.

    Every checkout runs ConnectionPool.check_connection, so a connection the server
    killed while idle is replaced instead of failing the next request.
    """
    pool: Pool = ConnectionPool(
        settings.database_url.get_secret_value(),
        min_size=settings.pool_min_size,
        max_size=settings.pool_max_size,
        timeout=settings.db_pool_timeout,
        kwargs={"connect_timeout": settings.db_connect_timeout},
        check=ConnectionPool.check_connection,
        open=True,
    )
    try:
        pool.wait(timeout=settings.db_pool_timeout)
    except BaseException:
        pool.close()
        raise
    return pool


def bind_identity(conn: Conn, user_id: UUID, agent_id: UUID | None) -> None:
    """Bind (user, agent) to the transaction. Outside the generator so mutmut mutates it."""
    conn.execute("SELECT app_sec.begin_request(%s, %s)", (user_id, agent_id))


@contextmanager
def request_tx(pool: Pool, user_id: UUID, agent_id: UUID | None) -> Iterator[Conn]:
    """One transaction carrying the caller's identity to row-level security.

    Commits on a clean exit and rolls back on an exception. The identity is
    bound to the transaction id by app_sec.begin_request, so a pooled connection
    never leaks it to the next request.
    """
    with pool.connection() as conn, conn.transaction():
        bind_identity(conn, user_id, agent_id)
        yield conn
