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


def check_sources(kind: MemoryKind, source_refs: tuple[SourceRef, ...]) -> None:
    if kind is not MemoryKind.NOTE and not source_refs:
        msg = "source_refs is required unless kind is note"
        raise ValueError(msg)


class ProposeRequest(Frozen):
    """What a caller may say. The server owns origin, author, delegate, tenant, status, version."""

    store_id: UUID
    kind: MemoryKind
    title: Annotated[str, Field(min_length=1, max_length=300)]
    body: Annotated[str, Field(max_length=100_000)] | None = None
    source_refs: Annotated[tuple[SourceRef, ...], Field(max_length=50)] = ()
    supersedes_id: UUID | None = None
    subject_id: UUID | None = None
    attribute: Annotated[str, Field(min_length=1, max_length=200)] | None = None

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


class SearchHit(MemorySummary):
    score: float
    stale: bool
    last_confirmed_at: datetime


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


class ProposeOutcome(Frozen):
    """created: a new proposed row. reconfirmed: the DB found a live row with the same key and
    value, wrote no new row, and refreshed that row's last_confirmed_at."""

    kind: Literal["created", "reconfirmed"]
    memory_id: UUID


class MemoryVersion(Frozen):
    version: int
    op: MemoryOp
    actor_id: UUID
    reason: str | None
    at: datetime
