from enum import StrEnum
from typing import Any
from uuid import uuid4

import psycopg
import pytest
from pydantic import ValidationError

from nunchi.domain.models import (
    MemoryKind,
    MemoryOp,
    MemoryOrigin,
    MemoryStatus,
    ProposeRequest,
    Role,
    SourceRef,
    StoreKind,
)


@pytest.mark.db
@pytest.mark.parametrize(
    ("pg_type", "enum"),
    [
        ("memory_kind", MemoryKind),
        ("memory_status", MemoryStatus),
        ("memory_origin", MemoryOrigin),
        ("memory_op", MemoryOp),
        ("store_kind", StoreKind),
        ("store_role", Role),
    ],
)
def test_enum_equals_pg_enum_labels(seeded: str, pg_type: str, enum: type[StrEnum]) -> None:
    with psycopg.connect(seeded) as conn:
        labels = [
            r[0]
            for r in conn.execute(
                "SELECT e.enumlabel FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid"
                " WHERE t.typname = %s ORDER BY e.enumsortorder",
                (pg_type,),
            )
        ]
    assert [m.value for m in enum] == labels


def _propose(**over: Any) -> ProposeRequest:  # noqa: ANN401
    fields: dict[str, Any] = {"store_id": uuid4(), "kind": "note", "title": "t"}
    return ProposeRequest.model_validate(fields | over)


def test_origin_is_not_a_client_field() -> None:
    with pytest.raises(ValidationError, match="origin"):
        _propose(origin="internal")


def test_non_note_needs_a_source() -> None:
    with pytest.raises(ValidationError, match="source_refs is required"):
        _propose(kind="fact")
    ok = _propose(kind="fact", source_refs=[{"uri": "https://example.com/a"}])
    assert ok.source_refs[0].uri == "https://example.com/a"
    assert _propose().source_refs == ()


def test_title_must_be_present() -> None:
    with pytest.raises(ValidationError, match="title"):
        _propose(title="")


@pytest.mark.parametrize("kind", ["fact", "decision", "procedure"])
def test_every_non_note_kind_rejects_missing_sources(kind: str) -> None:
    with pytest.raises(ValidationError) as exc:
        _propose(kind=kind)
    assert [e["msg"] for e in exc.value.errors()] == [
        "Value error, source_refs is required unless kind is note"
    ]
    assert _propose(kind=kind, source_refs=[{"uri": "u"}]).kind == kind


def test_note_with_sources_is_accepted() -> None:
    assert len(_propose(source_refs=[{"uri": "u"}, {"uri": "v"}]).source_refs) == 2


def test_models_are_immutable() -> None:
    req = _propose()
    with pytest.raises(ValidationError, match="frozen"):
        req.title = "changed"  # type: ignore[misc]
    ref = SourceRef(uri="https://example.com/a")
    with pytest.raises(ValidationError, match="frozen"):
        ref.uri = "x"  # type: ignore[misc]


def test_source_ref_uri_is_not_empty() -> None:
    with pytest.raises(ValidationError, match="at least 1 character"):
        SourceRef(uri="")
    assert SourceRef(uri="x").uri == "x"
