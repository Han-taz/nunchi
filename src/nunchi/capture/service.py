"""The capture pipeline (design v1.2 section 6), shared by Mattermost and MCP.

Every call runs on one request_tx connection, so the candidate search, the entity write and the
proposal share a transaction: an error anywhere stores nothing."""

import re
from collections.abc import Sequence
from datetime import date
from typing import Literal
from uuid import UUID

from nunchi.capture.resolve import ResolveConfig, known_entities, resolve_attribute, resolve_subject
from nunchi.capture.same import canonical_value
from nunchi.db import Conn
from nunchi.domain import repo
from nunchi.domain.models import (
    Evidence,
    Frozen,
    MemoryOrigin,
    MemoryStatus,
    SearchHit,
    SourceRef,
)
from nunchi.embed import Embedder
from nunchi.extract import (
    Candidate,
    Consensus,
    ExtractContext,
    Extractor,
    ProposalDraft,
    RelationKind,
    ValueJudge,
    WindowPost,
    confirm_consensus,
    evidence_for,
    to_propose_request,
)
from nunchi.gate import Verdict, evaluate_pair
from nunchi.gate.rules import Action

_CANDIDATES = 5
_QUERY_CHARS = 500
_QUERY_LINES = 8
_LIVE = (MemoryStatus.ACTIVE, MemoryStatus.PROVISIONAL, MemoryStatus.CHALLENGER)


class CaptureContext(Frozen):
    store_id: UUID
    origin: MemoryOrigin
    source_refs: tuple[SourceRef, ...] = ()
    today: date
    window: bool = False
    posts: tuple[WindowPost, ...] = ()
    """The window's posts in the order the extractor saw them. A draft's evidence numbers index
    this, and its platform data comes from here, never from the model."""
    consensus: Consensus = Consensus.STATED
    evidence: tuple[Evidence, ...] = ()
    """A single message has no numbers to cite: its caller says who agreed and which posts."""


class Skipped(Frozen):
    outcome: Literal["skipped"] = "skipped"


class Rejected(Frozen):
    """Rule ids only: the matched text may be the secret itself."""

    outcome: Literal["rejected"] = "rejected"
    reasons: tuple[str, ...]


class Created(Frozen):
    outcome: Literal["created"] = "created"
    memory_id: UUID
    status: MemoryStatus
    change: Literal["created", "challenged", "superseded"] = "created"
    conflict_with: UUID | None = None
    flags: tuple[str, ...] = ()


class Reconfirmed(Frozen):
    outcome: Literal["reconfirmed"] = "reconfirmed"
    memory_id: UUID
    confirmed: bool = False
    """True when another person's statement made a provisional row active."""


class Retracted(Frozen):
    outcome: Literal["retracted"] = "retracted"
    memory_id: UUID


CaptureResult = Skipped | Rejected | Created | Reconfirmed | Retracted


_NUMBER_AND_AUTHOR = re.compile(r"(?m)^\[\d+\] [^:\n]*: ")


def _candidates(
    conn: Conn, source_text: str, store_id: UUID, embedder: Embedder | None
) -> tuple[tuple[Candidate, ...], tuple[UUID, ...]]:
    """The candidate memories, each live row followed by the challenger beside it, and the entity
    ids they are about. Each of the newest lines is searched on its own, without its `[n] author:`
    prefix, so a one-line retraction is not diluted by the rest of the window."""
    found: dict[UUID, SearchHit] = {}
    for line in _NUMBER_AND_AUTHOR.sub("", source_text).splitlines()[-_QUERY_LINES:] or [""]:
        for hit in repo.search(
            conn, line[:_QUERY_CHARS], [store_id], None, _LIVE, embedder=embedder
        ):
            if hit.id not in found or found[hit.id].score < hit.score:
                found[hit.id] = hit
    hits = sorted(found.values(), key=lambda h: (-h.score, str(h.id)))[:_CANDIDATES]
    if not hits:
        return (), ()
    rows = conn.execute(
        "SELECT m.id, m.kind, m.title, left(coalesce(m.body, ''), 300), e.canonical_name,"
        " m.attribute, m.subject_id, m.value, m.status, m.conflict_with FROM memory AS m"
        " LEFT JOIN entity AS e ON e.id = m.subject_id"
        " WHERE m.id = ANY(%s) OR (m.status = 'challenger' AND m.conflict_with = ANY(%s))",
        ([h.id for h in hits], [h.id for h in hits]),
    ).fetchall()
    by_id = {r[0]: r for r in rows}
    challenger = {r[9]: r for r in rows if r[8] == MemoryStatus.CHALLENGER}
    ordered = [
        by_id[i]
        for h in hits
        if h.id in by_id
        for i in (h.id, challenger.get(h.id, (None,))[0])
        if i in by_id
    ][:_CANDIDATES]
    subjects: tuple[UUID, ...] = tuple(dict.fromkeys(r[6] for r in ordered if r[6] is not None))  # type: ignore[misc]
    return tuple(
        Candidate(
            id=r[0],
            kind=r[1],
            status=r[8],
            title=r[2],
            body_excerpt=r[3],
            subject_name=r[4],
            attribute=r[5],
            value=r[7],
        )
        for r in ordered
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
        _capture_draft(conn, draft, source_text, context, extract_context, embedder, cfg, judge)
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


def _verdict(
    draft: ProposalDraft, context: CaptureContext
) -> tuple[Consensus, tuple[Evidence, ...]]:
    """What the server believes about the draft. A window's claim is checked against its posts
    and lowered to `stated` unless they prove it; a single message takes its caller's word."""
    if not context.window:
        return context.consensus, context.evidence
    verified = confirm_consensus(draft.consensus, draft.evidence, context.posts)
    return verified, evidence_for(draft.evidence, context.posts)


def _capture_draft(  # noqa: PLR0913, PLR0917
    conn: Conn,
    draft: ProposalDraft,
    source_text: str,
    context: CaptureContext,
    extract_context: ExtractContext,
    embedder: Embedder | None,
    cfg: ResolveConfig,
    judge: ValueJudge | None,
) -> CaptureResult:
    consensus, evidence = _verdict(draft, context)
    if draft.relation.kind is RelationKind.RETRACTS:
        return _retract(conn, draft, extract_context, evidence)
    gate = evaluate_pair(source_text, f"{draft.title}\n{draft.body or ''}")
    if gate.verdict is Verdict.REJECT:
        return Rejected(reasons=tuple(f.rule_id for f in gate.flags if f.action is Action.REJECT))

    subject_id, draft = _resolve_key(conn, draft, extract_context, embedder, cfg)
    if subject_id is not None:
        draft = canonical_value(conn, extract_context.store_id, subject_id, draft, judge, cfg)
    request = to_propose_request(draft, extract_context, lambda _name: subject_id)
    flags = tuple(f.rule_id for f in gate.flags)
    outcome = repo.remember(
        conn, request.model_copy(update={"gate_flags": flags}), consensus.value, evidence
    )
    if outcome.kind in ("confirmed", "reconfirmed"):
        return Reconfirmed(memory_id=outcome.memory_id, confirmed=outcome.kind == "confirmed")
    return Created(
        memory_id=outcome.memory_id,
        status=outcome.status,
        change="created" if outcome.kind == "created" else outcome.kind,
        conflict_with=outcome.conflict_with,
        flags=flags,
    )


def _retract(
    conn: Conn, draft: ProposalDraft, extract_context: ExtractContext, evidence: Sequence[Evidence]
) -> CaptureResult:
    """Only a memory this server offered as a candidate can be retracted, and only on the word of
    a post: with none cited nobody is on record as having said it."""
    target = draft.relation.target_id
    if target is None or target not in {c.id for c in extract_context.candidates} or not evidence:
        return Skipped()
    outcome = repo.retract(conn, extract_context.store_id, target, evidence)
    return Retracted(memory_id=outcome.memory_id)
