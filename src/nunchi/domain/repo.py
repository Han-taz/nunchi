"""SQL for the memory API. Every function runs on a request_tx connection, so row-level
security and the app_sec functions decide what comes back; nothing here filters by caller."""

from collections.abc import Sequence
from uuid import UUID

from psycopg import sql
from psycopg.rows import class_row
from psycopg.types.json import Jsonb

from nunchi.config import SEARCH_RRF_K, SEARCH_VECTOR_FLOOR
from nunchi.db import Conn
from nunchi.domain.models import (
    Memory,
    MemoryKind,
    MemoryStatus,
    MemorySummary,
    MemoryVersion,
    ProposeOutcome,
    ProposeRequest,
    SearchHit,
    StoreRole,
)
from nunchi.embed import Embedder, embed_query

NOTE_DEDUPE_DAYS = 14

_MEMORY_COLUMNS = sql.SQL(
    "id, store_id, kind, status, title, body, source_refs, origin, supersedes_id,"
    " created_by, on_behalf_of, valid_from, valid_to, version, created_at, updated_at,"
    " subject_id, attribute, last_confirmed_at, value"
)


def list_stores(conn: Conn) -> list[StoreRole]:
    with conn.cursor(row_factory=class_row(StoreRole)) as cur:
        return cur.execute(
            "SELECT s.id AS store_id, s.slug, s.kind, s.description, r.role"
            " FROM app_sec.my_store_roles() AS r JOIN store AS s ON s.id = r.store_id"
            " WHERE s.archived_at IS NULL ORDER BY s.slug"
        ).fetchall()


def index(conn: Conn, store_id: UUID) -> list[MemorySummary]:
    with conn.cursor(row_factory=class_row(MemorySummary)) as cur:
        return cur.execute(
            "SELECT id, store_id, kind, status, title FROM memory"
            " WHERE store_id = %s AND status = 'active' ORDER BY title, id",
            (store_id,),
        ).fetchall()


def search(  # noqa: PLR0913 - the filters are the search
    conn: Conn,
    query: str,
    stores: Sequence[UUID] | None,
    kinds: Sequence[MemoryKind] | None,
    statuses: Sequence[MemoryStatus],
    *,
    embedder: Embedder | None = None,
    vector_floor: float = SEARCH_VECTOR_FLOOR,
    rrf_k: int = SEARCH_RRF_K,
) -> list[SearchHit]:
    """Trigram search, fused with vector search when an embedder is given and answers."""
    vector = embed_query(embedder, query)
    with conn.cursor(row_factory=class_row(SearchHit)) as cur:
        return cur.execute(
            "SELECT id, store_id, kind, title, status, score, stale, last_confirmed_at"
            " FROM app_sec.search(%s, %s::uuid[], %s::memory_status[], %s::memory_kind[],"
            " %s::real[], %s, %s::real, %s::integer)",
            (
                query,
                list(stores) if stores is not None else None,
                [s.value for s in statuses],
                [k.value for k in kinds] if kinds is not None else None,
                vector,
                embedder.model if embedder is not None and vector is not None else None,
                vector_floor,
                rrf_k,
            ),
        ).fetchall()


def get(conn: Conn, memory_id: UUID) -> Memory | None:
    with conn.cursor(row_factory=class_row(Memory)) as cur:
        return cur.execute(
            sql.SQL("SELECT {} FROM memory WHERE id = %s").format(_MEMORY_COLUMNS),
            (memory_id,),
        ).fetchone()


def propose(conn: Conn, req: ProposeRequest) -> ProposeOutcome:
    """Insert a proposed memory. The trigger and the memory_propose policy bind author, tenant,
    status and version, and a lineage walk sets origin. Only the delegate is spelled out because the
    policy requires on_behalf_of = the user exactly when an agent is present.
    A same-key same-value proposal is a reconfirm: the trigger returns NULL, RETURNING yields no
    row, and the live row's id is looked up under the same request context.
    A keyless note has no such key, so a near-duplicate of a recent note in the same store is
    reconfirmed by app_sec.reconfirm_duplicate_note instead of stored again."""
    if req.kind is MemoryKind.NOTE and req.subject_id is None:
        duplicate = conn.execute(
            "SELECT app_sec.reconfirm_duplicate_note(%s, %s, %s, %s)",
            (req.store_id, req.title, req.body, NOTE_DEDUPE_DAYS),
        ).fetchone()
        if duplicate is not None and duplicate[0] is not None:
            return ProposeOutcome(kind="reconfirmed", memory_id=duplicate[0])
    with conn.cursor() as cur:
        rows = cur.execute(
            sql.SQL(
                "INSERT INTO memory"
                " (store_id, kind, title, body, source_refs, supersedes_id,"
                " subject_id, attribute, value, gate_result, on_behalf_of)"
                " VALUES (%s, %s::memory_kind, %s, %s, %s, %s, %s, %s, %s, %s,"
                " CASE WHEN app_sec.ctx_agent() IS NOT NULL THEN app_sec.ctx_user() END)"
                " RETURNING id"
            ),
            (
                req.store_id,
                req.kind.value,
                req.title,
                req.body,
                Jsonb([ref.model_dump(mode="json") for ref in req.source_refs]),
                req.supersedes_id,
                req.subject_id,
                req.attribute,
                req.value,
                Jsonb({"flags": list(req.gate_flags)}),
            ),
        ).fetchall()
        if rows:
            return ProposeOutcome(kind="created", memory_id=rows[0][0])
        live = cur.execute(
            "SELECT id FROM memory WHERE store_id = %s AND subject_id = %s"
            " AND attribute = app_sec.norm_text(%s) AND status IN ('active', 'provisional')",
            (req.store_id, req.subject_id, req.attribute),
        ).fetchone()
    assert live is not None  # noqa: S101 - the trigger returned NULL only because this row matched
    return ProposeOutcome(kind="reconfirmed", memory_id=live[0])


def history(conn: Conn, memory_id: UUID) -> list[MemoryVersion]:
    with conn.cursor(row_factory=class_row(MemoryVersion)) as cur:
        return cur.execute(
            "SELECT version, op, actor_id, reason, at FROM memory_version"
            " WHERE memory_id = %s ORDER BY id",
            (memory_id,),
        ).fetchall()


def dependents(conn: Conn, memory_id: UUID) -> list[MemorySummary]:
    with conn.cursor(row_factory=class_row(MemorySummary)) as cur:
        return cur.execute(
            "SELECT id, store_id, kind, status, title FROM memory"
            " WHERE source_refs @> %s AND id <> %s ORDER BY created_at, id",
            (Jsonb([{"uri": f"memory://{memory_id}"}]), memory_id),
        ).fetchall()
