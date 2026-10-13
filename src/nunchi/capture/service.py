"""The capture pipeline (design v1.2 section 6), shared by Mattermost and MCP.

Every call runs on one request_tx connection, so the candidate search, the entity write and the
proposal share a transaction: an error anywhere stores nothing."""

from datetime import date
from typing import Literal
from uuid import UUID

from nunchi.capture.resolve import ResolveConfig, known_entities, resolve_attribute, resolve_subject
from nunchi.capture.same import canonical_value
from nunchi.db import Conn
from nunchi.domain import repo
from nunchi.domain.models import Frozen, MemoryOrigin, MemoryStatus, SourceRef
from nunchi.embed import Embedder
from nunchi.extract import (
    Candidate,
    ExtractContext,
    Extractor,
    ProposalDraft,
    ValueJudge,
    to_propose_request,
)
from nunchi.gate import Verdict, evaluate_pair
from nunchi.gate.rules import Action

_CANDIDATES = 5
_QUERY_CHARS = 500
_LIVE = (MemoryStatus.ACTIVE, MemoryStatus.PROVISIONAL)


class CaptureContext(Frozen):
    store_id: UUID
    origin: MemoryOrigin
    source_refs: tuple[SourceRef, ...] = ()
    today: date
    window: bool = False


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
) -> tuple[tuple[Candidate, ...], tuple[UUID, ...]]:
    """The candidate memories and the entity ids they are about."""
    hits = repo.search(conn, source_text[:_QUERY_CHARS], [store_id], None, _LIVE, embedder=embedder)
    hits = hits[:_CANDIDATES]
    if not hits:
        return (), ()
    rows = conn.execute(
        "SELECT m.id, m.kind, m.title, left(coalesce(m.body, ''), 300), e.canonical_name,"
        " m.attribute, m.subject_id, m.value FROM memory AS m"
        " LEFT JOIN entity AS e ON e.id = m.subject_id WHERE m.id = ANY(%s)",
        ([h.id for h in hits],),
    ).fetchall()
    by_id = {r[0]: r for r in rows}
    subjects: tuple[UUID, ...] = tuple(dict.fromkeys(r[6] for r in rows if r[6] is not None))  # type: ignore[misc]
    return tuple(
        Candidate(
            id=h.id,
            kind=by_id[h.id][1],
            title=by_id[h.id][2],
            body_excerpt=by_id[h.id][3],
            subject_name=by_id[h.id][4],
            attribute=by_id[h.id][5],
            value=by_id[h.id][7],
        )
        for h in hits
        if h.id in by_id
    ), subjects


def _resolve_key(
    conn: Conn,
    draft: ProposalDraft,
    context: ExtractContext,
    embedder: Embedder | None,
    cfg: ResolveConfig,
) -> tuple[UUID | None, ProposalDraft]:
    """The entity the draft is about and the draft with its attribute canonicalized. The model's
    entity id counts only when this server offered it; any other id falls back to the name."""
    if draft.subject_name is None or draft.attribute is None:
        return None, draft
    offered = {e.id for e in context.entities}
    if draft.subject_entity_id in offered:
        subject_id = draft.subject_entity_id
        conn.execute("SELECT app_sec.add_entity_alias(%s, %s)", (subject_id, draft.subject_name))
    else:
        subject_id = resolve_subject(conn, draft.subject_name, embedder, cfg)
    attribute = resolve_attribute(
        conn, context.store_id, subject_id, draft.attribute, embedder, cfg
    )
    return subject_id, draft.model_copy(update={"attribute": attribute})


def capture_all(  # noqa: PLR0913, PLR0917 - the pipeline inputs plus the optional services
    conn: Conn,
    extractor: Extractor,
    source_text: str,
    context: CaptureContext,
    embedder: Embedder | None = None,
    resolve: ResolveConfig | None = None,
    judge: ValueJudge | None = None,
) -> tuple[CaptureResult, ...]:
    """One result per draft the extractor returned, in order; (Skipped(),) when it returned none.
    A single message (not a window) keeps its first draft only. Later drafts see the entities and
    memories earlier ones wrote, because they share the transaction."""
    cfg = resolve or ResolveConfig()
    candidates, subjects = _candidates(conn, source_text, context.store_id, embedder)
    extract_context = ExtractContext(
        origin=context.origin,
        source_refs=context.source_refs,
        today=context.today,
        store_id=context.store_id,
        candidates=candidates,
        entities=known_entities(conn, context.store_id, source_text, subjects, cfg),
        window=context.window,
    )
    drafts = extractor.extract(source_text, extract_context)
    if not context.window:
        drafts = drafts[:1]
    if not drafts:
        return (Skipped(),)
    return tuple(
        _capture_draft(conn, draft, source_text, extract_context, embedder, cfg, judge)
        for draft in drafts
    )


def capture(  # noqa: PLR0913, PLR0917 - the pipeline inputs plus the optional services
    conn: Conn,
    extractor: Extractor,
    source_text: str,
    context: CaptureContext,
    embedder: Embedder | None = None,
    resolve: ResolveConfig | None = None,
    judge: ValueJudge | None = None,
) -> CaptureResult:
    """The first result, for callers that expect one (the pin path, MCP remember)."""
    return capture_all(conn, extractor, source_text, context, embedder, resolve, judge)[0]


def _capture_draft(  # noqa: PLR0913, PLR0917
    conn: Conn,
    draft: ProposalDraft,
    source_text: str,
    extract_context: ExtractContext,
    embedder: Embedder | None,
    cfg: ResolveConfig,
    judge: ValueJudge | None,
) -> CaptureResult:
    gate = evaluate_pair(source_text, f"{draft.title}\n{draft.body or ''}")
    if gate.verdict is Verdict.REJECT:
        return Rejected(reasons=tuple(f.rule_id for f in gate.flags if f.action is Action.REJECT))

    subject_id, draft = _resolve_key(conn, draft, extract_context, embedder, cfg)
    if subject_id is not None:
        draft = canonical_value(conn, extract_context.store_id, subject_id, draft, judge, cfg)
    request = to_propose_request(draft, extract_context, lambda _name: subject_id)
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
