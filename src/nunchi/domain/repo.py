"""SQL for the memory API. Every function runs on a request_tx connection, so row-level
security and the app_sec functions decide what comes back; nothing here filters by caller."""

from collections.abc import Sequence
from typing import Any, Literal
from uuid import UUID

from psycopg import sql
from psycopg.rows import class_row, dict_row
from psycopg.types.json import Jsonb

from nunchi.config import SEARCH_RRF_K, SEARCH_VECTOR_FLOOR
from nunchi.db import Conn
from nunchi.domain.models import (
    LABELS,
    DecideOutcome,
    EvidenceSummary,
    Memory,
    MemoryKind,
    MemoryStatus,
    MemorySummary,
    MemoryVersion,
    PendingChange,
    ProposeOutcome,
    ProposeRequest,
    SearchHit,
    SourceRef,
    StoreRole,
)
from nunchi.embed import Embedder, embed_query

NOTE_DEDUPE_DAYS = 14
CONSENSUS = "stated"

_MEMORY_COLUMNS = sql.SQL(
    "id, store_id, kind, status, title, body, source_refs, origin, supersedes_id,"
    " created_by, on_behalf_of, valid_from, valid_to, version, created_at, updated_at,"
    " subject_id, attribute, last_confirmed_at, value, basis, promote_at"
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
    """Trigram search, fused with vector search when an embedder is given and answers. An open
    challenger is folded into its key's live row as `pending_change`, even when only the
    challenger's text matched; ask for the challenger status to get it as a row of its own."""
    vector = embed_query(embedder, query)
    with conn.cursor(row_factory=dict_row) as cur:
        rows = cur.execute(
            "SELECT * FROM app_sec.search(%s, %s::uuid[], %s::memory_status[], %s::memory_kind[],"
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
    return [_hit(row) for row in rows]


def _hit(row: dict[str, Any]) -> SearchHit:
    pending = (
        PendingChange(
            id=row["pending_id"],
            title=row["pending_title"],
            value=row["pending_value"],
            promote_at=row["pending_promote_at"],
        )
        if row["pending_id"] is not None
        else None
    )
    fields = {k: v for k, v in row.items() if not k.startswith("pending_")}
    return SearchHit(**fields, label=LABELS.get(row["status"]), pending_change=pending)


def get(conn: Conn, memory_id: UUID) -> Memory | None:
    with conn.cursor(row_factory=class_row(Memory)) as cur:
        return cur.execute(
            sql.SQL("SELECT {} FROM memory WHERE id = %s").format(_MEMORY_COLUMNS),
            (memory_id,),
        ).fetchone()


def remember(conn: Conn, req: ProposeRequest) -> ProposeOutcome:
    """Write through app_sec.remember, the only way into memory: the function binds author,
    delegate and tenant to the request, decides the state from the key's live row and the
    consensus, and records the evidence. Every caller says `stated` until U34/U35 bring the
    consensus judgement; each source ref becomes one evidence line.
    A keyless note has no key, so a near-duplicate of a recent note in the same store is
    reconfirmed by app_sec.reconfirm_duplicate_note instead of stored again."""
    if req.kind is MemoryKind.NOTE and req.subject_id is None:
        duplicate = conn.execute(
            "SELECT app_sec.reconfirm_duplicate_note(%s, %s, %s, %s)",
            (req.store_id, req.title, req.body, NOTE_DEDUPE_DAYS),
        ).fetchone()
        if duplicate is not None and duplicate[0] is not None:
            known = conn.execute(
                "SELECT status FROM memory WHERE id = %s", (duplicate[0],)
            ).fetchone()
            assert known is not None  # noqa: S101 - the function just refreshed this row
            return ProposeOutcome.model_validate(
                {"kind": "reconfirmed", "memory_id": duplicate[0], "status": known[0]}
            )
    row = conn.execute(
        "SELECT r_outcome, r_id, r_status, r_conflict FROM app_sec.remember("
        "%s, %s::memory_kind, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
        (
            req.store_id,
            req.kind.value,
            req.title,
            req.body,
            Jsonb([ref.model_dump(mode="json") for ref in req.source_refs]),
            req.subject_id,
            req.attribute,
            req.value,
            Jsonb({"flags": list(req.gate_flags)}),
            CONSENSUS,
            Jsonb([{"uri": ref.uri} for ref in req.source_refs]),
        ),
    ).fetchone()
    assert row is not None  # noqa: S101 - a set-returning function that writes always returns its row
    return ProposeOutcome.model_validate(
        {"kind": row[0], "memory_id": row[1], "status": row[2], "conflict_with": row[3]}
    )


def history(conn: Conn, memory_id: UUID) -> list[MemoryVersion]:
    """Every version with the messages that caused it (permalink, author name, time)."""
    with conn.cursor(row_factory=class_row(MemoryVersion)) as cur:
        return cur.execute(
            "SELECT v.version, v.op, v.actor_id, v.reason, v.at, coalesce(("
            " SELECT jsonb_agg(jsonb_build_object('uri', e.uri, 'author_name', e.author_name,"
            " 'said_at', e.said_at, 'basis', e.basis) ORDER BY e.id)"
            " FROM memory_evidence AS e"
            " WHERE e.memory_id = v.memory_id AND e.version = v.version AND e.op = v.op"
            "), '[]'::jsonb) AS evidence"
            " FROM memory_version AS v WHERE v.memory_id = %s ORDER BY v.id",
            (memory_id,),
        ).fetchall()


def evidence_summary(conn: Conn, memory_id: UUID) -> EvidenceSummary:
    with conn.cursor(row_factory=class_row(EvidenceSummary)) as cur:
        row = cur.execute(
            "SELECT count(*)::integer AS count,"
            " count(DISTINCT author)::integer AS distinct_authors,"
            " max(said_at) AS last_said_at FROM memory_evidence WHERE memory_id = %s",
            (memory_id,),
        ).fetchone()
    assert row is not None  # noqa: S101 - an aggregate always returns one row
    return row


def decide(
    conn: Conn,
    memory_id: UUID,
    verdict: Literal["confirm", "retract"],
    expected_version: int,
    source_refs: Sequence[SourceRef],
) -> DecideOutcome:
    """confirm or retract one live row through app_sec.decide. The evidence author is the
    caller, whatever the refs say."""
    row = conn.execute(
        "SELECT r_outcome, r_status, r_reason FROM app_sec.decide(%s, %s, %s, %s)",
        (memory_id, verdict, expected_version, Jsonb([{"uri": ref.uri} for ref in source_refs])),
    ).fetchone()
    assert row is not None  # noqa: S101 - the function returns exactly one row
    return DecideOutcome(outcome=row[0], status=row[1], reason=row[2])


def dependents(conn: Conn, memory_id: UUID) -> list[MemorySummary]:
    with conn.cursor(row_factory=class_row(MemorySummary)) as cur:
        return cur.execute(
            "SELECT id, store_id, kind, status, title FROM memory"
            " WHERE source_refs @> %s AND id <> %s ORDER BY created_at, id",
            (Jsonb([{"uri": f"memory://{memory_id}"}]), memory_id),
        ).fetchall()
