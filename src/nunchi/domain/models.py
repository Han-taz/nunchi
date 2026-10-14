from datetime import date, datetime
from enum import StrEnum
from typing import Annotated, Literal, Self
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator


class MemoryKind(StrEnum):
    FACT = "fact"
    DECISION = "decision"
    PROCEDURE = "procedure"
    NOTE = "note"


class MemoryStatus(StrEnum):
    PROPOSED = "proposed"
    PROVISIONAL = "provisional"
    CHALLENGER = "challenger"
    ACTIVE = "active"
    SUPERSEDED = "superseded"
    REJECTED = "rejected"
    EXPIRED = "expired"
    DELETED = "deleted"


class MemoryOrigin(StrEnum):
    INTERNAL = "internal"
    EXTERNAL = "external"


class MemoryOp(StrEnum):
    PROPOSE = "propose"
    AUTO_ACTIVATE = "auto_activate"
    APPROVE = "approve"
    CONFIRM = "confirm"
    REJECT = "reject"
    RETRACT = "retract"
    EDIT = "edit"
    SUPERSEDE = "supersede"
    EXPIRE = "expire"
    DELETE = "delete"
    REDACT = "redact"
    RECONFIRM = "reconfirm"
    PROMOTE = "promote"


class PromotionBasis(StrEnum):
    AGREED = "agreed"
    STATED = "stated"
    TIMER = "timer"
    AGENT = "agent"
    USER_STORE = "user_store"
    MIGRATED = "migrated"


class StoreKind(StrEnum):
    ORG = "org"
    TEAM = "team"
    PROJECT = "project"
    USER = "user"


class Role(StrEnum):
    READER = "reader"
    CONTRIBUTOR = "contributor"
    CURATOR = "curator"


class RoomKind(StrEnum):
    PUBLIC = "public"
    PRIVATE = "private"
    CONNECT = "connect"


class LinkQuality(StrEnum):
    SCIM = "scim"
    EMAIL = "email"


class Frozen(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class SourceRef(Frozen):
    uri: Annotated[str, Field(min_length=1, max_length=2048)]
    system: str | None = None
    inherit_acl: bool = False
    workspace_id: str | None = Field(default=None, exclude_if=lambda v: v is None)
    channel_id: str | None = Field(default=None, exclude_if=lambda v: v is None)
    speakers: tuple[str, ...] = Field(default=(), exclude_if=lambda v: not v)


def check_sources(kind: MemoryKind, source_refs: tuple[SourceRef, ...]) -> None:
    if kind is not MemoryKind.NOTE and not source_refs:
        msg = "source_refs is required unless kind is note"
        raise ValueError(msg)


class Evidence(Frozen):
    """One post that states or confirms a memory (design v1.3 6). The server builds it from the
    platform's data; a model only ever names a post number."""

    uri: Annotated[str, Field(min_length=1, max_length=2048)]
    post_id: str
    author: str
    author_name: str | None = None
    said_at: datetime


class ProposeRequest(Frozen):
    """What a caller may say. The server owns origin, author, delegate, tenant, status, version."""

    store_id: UUID
    kind: MemoryKind
    title: Annotated[str, Field(min_length=1, max_length=300)]
    body: Annotated[str, Field(max_length=100_000)] | None = None
    source_refs: Annotated[tuple[SourceRef, ...], Field(max_length=50)] = ()
    subject_id: UUID | None = None
    attribute: Annotated[str, Field(min_length=1, max_length=200)] | None = None
    value: Annotated[str, Field(min_length=1, max_length=200)] | None = None
    gate_flags: tuple[str, ...] = ()
    """Rule ids the write gate raised. Set by server code only; the REST route resets it."""

    @model_validator(mode="after")
    def _only_notes_may_lack_sources(self) -> Self:
        check_sources(self.kind, self.source_refs)
        return self

    @model_validator(mode="after")
    def _only_notes_lack_a_key(self) -> Self:
        has_key = self.subject_id is not None and self.attribute is not None
        has_part = self.subject_id is not None or self.attribute is not None
        is_note = self.kind is MemoryKind.NOTE
        if (is_note and has_part) or (not is_note and not has_key):
            msg = (
                "subject_id and attribute are required unless kind is note (and forbidden for note)"
            )
            raise ValueError(msg)
        return self


class StoreRole(Frozen):
    store_id: UUID
    slug: str
    kind: StoreKind
    description: str
    role: Role


class MemorySummary(Frozen):
    id: UUID
    store_id: UUID
    kind: MemoryKind
    status: MemoryStatus
    title: str


LABELS: dict[MemoryStatus, str] = {
    MemoryStatus.PROVISIONAL: "미확정",
    MemoryStatus.CHALLENGER: "변경 제안 (미확정)",
}


class PendingChange(Frozen):
    """The open challenger of a live row's key (design v1.3 8)."""

    id: UUID
    title: str
    value: str | None
    promote_at: datetime | None


class SearchHit(MemorySummary):
    score: float
    stale: bool
    last_confirmed_at: datetime
    subject_id: UUID | None
    attribute: str | None
    basis: PromotionBasis | None
    promote_at: datetime | None
    flags: int
    label: str | None
    pending_change: PendingChange | None


class Memory(MemorySummary):
    body: str | None
    source_refs: tuple[SourceRef, ...]
    origin: MemoryOrigin
    supersedes_id: UUID | None
    created_by: UUID
    on_behalf_of: UUID | None
    valid_from: date | None
    valid_to: date | None
    version: int
    created_at: datetime
    updated_at: datetime
    subject_id: UUID | None
    attribute: str | None
    last_confirmed_at: datetime
    value: str | None
    basis: PromotionBasis | None
    promote_at: datetime | None


class ProposeOutcome(Frozen):
    """What app_sec.remember did (design v1.3 5.1). created: a new row, provisional or active.
    challenged: a new challenger beside the live row it disagrees with (conflict_with).
    superseded: a newer value replaced the live row. confirmed: another author's statement made
    a provisional row active. reconfirmed: the same value again, no new row. retracted: the target
    was rejected (it was provisional or a challenger) or expired (it was active). memory_id is the
    row the call ended on and status is that row's status."""

    kind: Literal["created", "challenged", "superseded", "confirmed", "reconfirmed", "retracted"]
    memory_id: UUID
    status: MemoryStatus
    conflict_with: UUID | None = None


class Evidence(Frozen):
    """One message behind a transition: its permalink, who said it and when."""

    uri: str | None
    author_name: str | None
    said_at: datetime | None
    basis: PromotionBasis


class MemoryVersion(Frozen):
    version: int
    op: MemoryOp
    actor_id: UUID
    reason: str | None
    at: datetime
    evidence: tuple[Evidence, ...]


class EvidenceSummary(Frozen):
    count: int
    distinct_authors: int
    last_said_at: datetime | None


class DecideOutcome(Frozen):
    """What app_sec.decide did. applied: the verdict changed the row, status is its new state.
    reconfirmed: the caller already stands behind the row (or it is active), only the evidence grew.
    refused: stale (expected_version is old) or not_live (no such live row you may decide)."""

    outcome: Literal["applied", "reconfirmed", "refused"]
    status: MemoryStatus | None
    reason: Literal["stale", "not_live"] | None = None
