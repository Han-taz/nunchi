"""The capture pipeline (design v1.2 section 6), shared by Slack and MCP.

Every call runs on one request_tx connection, so the candidate search, the entity write and the
proposal share a transaction: an error anywhere stores nothing."""

from datetime import date
from typing import Literal
from uuid import UUID

from nunchi.db import Conn
from nunchi.domain import repo
from nunchi.domain.models import Frozen, MemoryOrigin, MemoryStatus, SourceRef
from nunchi.embed import Embedder
from nunchi.extract import Candidate, ExtractContext, Extractor, to_propose_request
from nunchi.gate import Verdict, evaluate_pair
from nunchi.gate.rules import Action

_CANDIDATES = 5
_QUERY_CHARS = 500
_ENTITY_KIND = "subject"
_LIVE = (MemoryStatus.ACTIVE, MemoryStatus.PROVISIONAL)


class CaptureContext(Frozen):
    store_id: UUID
    origin: MemoryOrigin
    source_refs: tuple[SourceRef, ...] = ()
    today: date


class Skipped(Frozen):
    outcome: Literal["skipped"] = "skipped"


class Rejected(Frozen):
    """Rule ids only: the matched text may be the secret itself."""

    outcome: Literal["rejected"] = "rejected"
    reasons: tuple[str, ...]


class Created(Frozen):
    outcome: Literal["created"] = "created"
    memory_id: UUID
    tier: str
    status: MemoryStatus
    conflict_with: UUID | None = None
    flags: tuple[str, ...] = ()


class Reconfirmed(Frozen):
    outcome: Literal["reconfirmed"] = "reconfirmed"
    memory_id: UUID


CaptureResult = Skipped | Rejected | Created | Reconfirmed


def _candidates(
    conn: Conn, source_text: str, store_id: UUID, embedder: Embedder | None
) -> tuple[Candidate, ...]:
    hits = repo.search(conn, source_text[:_QUERY_CHARS], [store_id], None, _LIVE, embedder=embedder)
    hits = hits[:_CANDIDATES]
    if not hits:
        return ()
    rows = conn.execute(
        "SELECT m.id, m.kind, m.title, left(coalesce(m.body, ''), 300), e.canonical_name,"
        " m.attribute FROM memory AS m LEFT JOIN entity AS e ON e.id = m.subject_id"
        " WHERE m.id = ANY(%s)",
        ([h.id for h in hits],),
    ).fetchall()
    by_id = {r[0]: r for r in rows}
    return tuple(
        Candidate(
            id=h.id,
            kind=by_id[h.id][1],
            title=by_id[h.id][2],
            body_excerpt=by_id[h.id][3],
            subject_name=by_id[h.id][4],
            attribute=by_id[h.id][5],
        )
        for h in hits
        if h.id in by_id
    )


def _resolve_or_create(conn: Conn, name: str) -> UUID:
    row = conn.execute("SELECT app_sec.resolve_entity(%s)", (name,)).fetchone()
    if row is not None and row[0] is not None:
        return row[0]  # type: ignore[return-value]
    created = conn.execute("SELECT app_sec.create_entity(%s, %s)", (name, _ENTITY_KIND)).fetchone()
    assert created is not None  # noqa: S101 - a SELECT of a function always returns one row
    return created[0]  # type: ignore[return-value]


def capture(
    conn: Conn,
    extractor: Extractor,
    source_text: str,
    context: CaptureContext,
    embedder: Embedder | None = None,
) -> CaptureResult:
    candidates = _candidates(conn, source_text, context.store_id, embedder)
    draft = extractor.extract(
        source_text,
        ExtractContext(
            origin=context.origin,
            source_refs=context.source_refs,
            today=context.today,
            store_id=context.store_id,
            candidates=candidates,
        ),
    )
    if draft is None:
        return Skipped()

    gate = evaluate_pair(source_text, f"{draft.title}\n{draft.body or ''}")
    if gate.verdict is Verdict.REJECT:
        return Rejected(reasons=tuple(f.rule_id for f in gate.flags if f.action is Action.REJECT))

    request = to_propose_request(
        draft,
        ExtractContext(
            origin=context.origin,
            source_refs=context.source_refs,
            today=context.today,
            store_id=context.store_id,
        ),
        lambda name: _resolve_or_create(conn, name),
    )
    flags = tuple(f.rule_id for f in gate.flags)
    outcome = repo.propose(conn, request.model_copy(update={"gate_flags": flags}))
    if outcome.kind == "reconfirmed":
        return Reconfirmed(memory_id=outcome.memory_id)
    row = conn.execute(
        "SELECT tier, status, conflict_with FROM memory WHERE id = %s", (outcome.memory_id,)
    ).fetchone()
    assert row is not None  # noqa: S101 - the proposer can read the row it just inserted
    return Created(
        memory_id=outcome.memory_id,
        tier=str(row[0]),
        status=MemoryStatus(str(row[1])),
        conflict_with=row[2],
        flags=flags,
    )
