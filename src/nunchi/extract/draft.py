from datetime import date
from enum import StrEnum
from typing import Annotated, Protocol

from pydantic import Field

from nunchi.domain.models import Frozen, MemoryKind, MemoryOrigin, SourceRef


class ProposalDraft(Frozen):
    """Extraction form from design §4. The caller, never the model, sets origin and source_refs."""

    kind: MemoryKind
    title: Annotated[str, Field(min_length=1, max_length=300)]
    body: Annotated[str, Field(max_length=100_000)] | None = None
    subject: str | None = None
    attribute: str | None = None
    source_refs: tuple[SourceRef, ...] = ()
    valid_from: date | None = None
    origin: MemoryOrigin


class ExtractContext(Frozen):
    origin: MemoryOrigin
    source_refs: tuple[SourceRef, ...] = ()
    today: date


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
