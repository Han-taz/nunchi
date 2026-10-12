from collections.abc import Iterator
from contextlib import contextmanager
from uuid import UUID

import psycopg
from psycopg_pool import ConnectionPool

from nunchi.config import Settings


def open_pool(settings: Settings) -> ConnectionPool[psycopg.Connection[tuple[object, ...]]]:
    pool = ConnectionPool[psycopg.Connection[tuple[object, ...]]](
        settings.database_url.get_secret_value(),
        min_size=settings.pool_min_size,
        max_size=settings.pool_max_size,
        open=False,
    )
    pool.open(wait=True)
    return pool


@contextmanager
def request_tx(
    pool: ConnectionPool[psycopg.Connection[tuple[object, ...]]],
    user_id: UUID,
    agent_id: UUID | None,
) -> Iterator[psycopg.Connection[tuple[object, ...]]]:
    """One transaction carrying the caller's identity to row-level security.

    Commits on a clean exit and rolls back on an exception. The identity is
    bound to the transaction id by app_sec.begin_request, so a pooled connection
    never leaks it to the next request.
    """
    with pool.connection() as conn, conn.transaction():
        conn.execute("SELECT app_sec.begin_request(%s, %s)", (user_id, agent_id))
        yield conn
