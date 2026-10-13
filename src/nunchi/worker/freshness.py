from datetime import datetime
from uuid import UUID

from psycopg.rows import class_row

from nunchi.db import Conn
from nunchi.domain.models import Frozen, MemoryKind

STALE_LIMIT = 100


class StaleMemory(Frozen):
    id: UUID
    tenant_id: UUID
    store_id: UUID
    kind: MemoryKind
    title: str
    last_confirmed_at: datetime
    ttl_days: int


class RunResult(Frozen):
    expired: int
    stale: tuple[StaleMemory, ...]


def run_once(conn: Conn, stale_limit: int = STALE_LIMIT) -> RunResult:
    """Expire rows whose valid_to has passed, then list the stale ones (oldest first).
    Sending the "still correct?" cards is the caller's job."""
    with conn.transaction():
        expired = conn.execute("SELECT app_sec.mark_expired()").fetchall()[0][0]
        with conn.cursor(row_factory=class_row(StaleMemory)) as cur:
            stale = cur.execute(
                "SELECT id, tenant_id, store_id, kind, title, last_confirmed_at, ttl_days"
                " FROM app_sec.stale_memories(%s)",
                (stale_limit,),
            ).fetchall()
    return RunResult(expired=int(str(expired)), stale=tuple(stale))
