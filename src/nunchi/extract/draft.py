from datetime import date
from enum import StrEnum
from typing import Annotated, Protocol, Self
from uuid import UUID

from pydantic import Field, model_validator

from nunchi.domain.models import Frozen, MemoryKind, MemoryOrigin, SourceRef


class RelationKind(StrEnum):
    NEW = "new"
    SAME_AS = "same_as"
    UPDATES = "updates"
    NOT_WORTH = "not_worth"


class Relation(Frozen):
    """The extractor's hint about an existing memory (design §6). The server decides."""

    kind: RelationKind = RelationKind.NEW
    target_id: UUID | None = None

    @model_validator(mode="after")
    def _target_iff_pointing(self) -> Self:
        points = self.kind in (RelationKind.SAME_AS, RelationKind.UPDATES)
        if points != (self.target_id is not None):
            msg = "target_id is required for same_as and updates, and forbidden otherwise"
            raise ValueError(msg)
        return self


class Candidate(Frozen):
    """An existing memory the caller found by search, shown to the extractor as data."""

    id: UUID
    kind: MemoryKind
    title: str
    body_excerpt: Annotated[str, Field(max_length=300)] = ""
    subject_name: str | None = None
    attribute: str | None = None


class EntityContext(Frozen):
    """An entity the store already knows, offered to the extractor so it reuses the id."""

    id: UUID
    name: str
    aliases: tuple[str, ...] = ()
    attributes: tuple[str, ...] = ()


class ProposalDraft(Frozen):
    """Extraction form from design §6. The caller, never the model, sets origin and source_refs."""

    kind: MemoryKind
    title: Annotated[str, Field(min_length=1, max_length=300)]
    body: Annotated[str, Field(max_length=100_000)] | None = None
    subject_name: str | None = None
    subject_entity_id: UUID | None = None
    attribute: str | None = None
    source_refs: tuple[SourceRef, ...] = ()
    valid_from: date | None = None
    origin: MemoryOrigin
    relation: Relation = Relation()

    @model_validator(mode="after")
    def _only_notes_lack_a_key(self) -> Self:
        has_key = bool(self.subject_name) and bool(self.attribute)
        has_part = self.subject_name is not None or self.attribute is not None
        is_note = self.kind is MemoryKind.NOTE
        if (is_note and has_part) or (not is_note and not has_key):
            msg = (
                "subject_name and attribute are required unless kind is note (and absent for note)"
            )
            raise ValueError(msg)
        return self


class ExtractContext(Frozen):
    origin: MemoryOrigin
    source_refs: tuple[SourceRef, ...] = ()
    today: date
    store_id: UUID
    candidates: Annotated[tuple[Candidate, ...], Field(max_length=5)] = ()
    entities: Annotated[tuple[EntityContext, ...], Field(max_length=10)] = ()


class FailureReason(StrEnum):
    API = "api"
    REFUSED = "refused"
    TRUNCATED = "truncated"
    MALFORMED = "malformed"


class ExtractionError(Exception):
    def __init__(self, reason: FailureReason, detail: str) -> None:
        super().__init__(f"{reason}: {detail}")
        self.reason = reason
        self.detail = detail


class Extractor(Protocol):
    def extract(self, source_text: str, context: ExtractContext) -> ProposalDraft | None: ...
