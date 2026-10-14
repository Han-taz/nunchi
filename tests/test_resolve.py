from datetime import date
from uuid import UUID

import pytest

from nunchi.capture import CaptureContext, Created, capture
from nunchi.capture.resolve import ResolveConfig, match_key
from nunchi.db import Pool, request_tx
from nunchi.domain.models import MemoryKind, MemoryOrigin, SourceRef
from nunchi.embed import Embedder
from nunchi.extract import ExtractContext, ProposalDraft
from tests.conftest import STORE, USER
from tests.embed_fake import DownEmbedder, FakeEmbedder
from tests.test_repo import world as world  # noqa: PLC0414 - fixture re-export

REF = SourceRef(uri="https://example.slack.com/archives/C1/p1", system="slack")
CTX = CaptureContext(
    store_id=STORE, origin=MemoryOrigin.EXTERNAL, source_refs=(REF,), today=date(2026, 10, 13)
)


class Scripted:
    """Returns a draft with the given key and records what the server offered."""

    def __init__(self) -> None:
        self.seen: ExtractContext | None = None
        self.subject: str = ""
        self.attribute: str = ""
        self.entity_id: UUID | None = None
        self.body: str = ""

    def extract(self, source_text: str, context: ExtractContext) -> tuple[ProposalDraft, ...]:
        self.seen = context
        draft = ProposalDraft(
            kind=MemoryKind.FACT,
            title=self.body,
            body=self.body,
            subject_name=self.subject,
            subject_entity_id=self.entity_id,
            attribute=self.attribute,
            source_refs=context.source_refs,
            origin=context.origin,
        )
        return (draft,)


def say(  # noqa: PLR0913, PLR0917 - a spoken fact is five values
    pool: Pool,
    ex: Scripted,
    subject: str,
    attribute: str,
    body: str,
    embedder: Embedder | None = None,
    source: str | None = None,
) -> Created:
    ex.subject, ex.attribute, ex.body = subject, attribute, body
    with request_tx(pool, USER, None) as conn:
        result = capture(conn, ex, source or f"{subject} {attribute} {body}", CTX, embedder)
    assert isinstance(result, Created)
    return result


def keys(pool: Pool) -> list[tuple[str, str, str]]:
    """(canonical entity, attribute, body) of every memory, oldest first."""
    with request_tx(pool, USER, None) as conn:
        rows = conn.execute(
            "SELECT e.canonical_name, m.attribute, m.body FROM memory AS m"
            " JOIN entity AS e ON e.id = m.subject_id ORDER BY m.created_at, m.body"
        ).fetchall()
    return [(str(a), str(b), str(c)) for a, b, c in rows]


@pytest.mark.parametrize(
    ("name", "key"),
    [
        ("A사", "a"),
        ("에이사", "a"),
        ("A Corp", "a"),
        ("에이 사", "a"),
        ("비 주식회사", "b"),
        ("Costco", "costco"),
        ("결제 모듈", "결제모듈"),
        ("결제모듈", "결제모듈"),
        ("B사", "b"),
    ],
)
def test_match_key_collapses_spelling(name: str, key: str) -> None:
    assert match_key(name) == key


@pytest.mark.db
def test_other_spelling_reuses_the_entity_and_detects_the_update(world: Pool) -> None:
    ex = Scripted()
    first = say(world, ex, "A사", "담당자", "A사 담당자: 이OO")
    second = say(world, ex, "에이사", "담당자", "A사 담당자: 박OO")
    assert second.conflict_with == first.memory_id
    assert keys(world) == [
        ("A사", "담당자", "A사 담당자: 이OO"),
        ("A사", "담당자", "A사 담당자: 박OO"),
    ]
    say(world, ex, "A Corp", "담당자", "A사 담당자: 최OO")
    with request_tx(world, USER, None) as conn:
        aliases = conn.execute("SELECT alias_norm FROM entity_alias ORDER BY alias_norm").fetchall()
    assert sorted(aliases) == [("a corp",), ("a사",), ("에이사",)]


@pytest.mark.db
def test_different_subjects_stay_apart(world: Pool) -> None:
    ex = Scripted()
    say(world, ex, "A사", "담당자", "이OO")
    say(world, ex, "B사", "담당자", "최OO")
    say(world, ex, "결제 모듈", "타임아웃", "30초")
    say(world, ex, "결제 서버", "타임아웃", "10초")
    assert [k[0] for k in keys(world)] == ["A사", "B사", "결제 모듈", "결제 서버"]


@pytest.mark.db
def test_trigram_reuses_a_close_spelling_and_attribute(world: Pool) -> None:
    ex = Scripted()
    say(world, ex, "Payment Gateway", "알림 채널", "#pay")
    say(world, ex, "Payment Gateways", "알림 채널명", "#pay-ops")
    assert [k[:2] for k in keys(world)] == [("Payment Gateway", "알림 채널")] * 2


@pytest.mark.db
def test_attribute_below_the_trigram_floor_stays_a_new_key(world: Pool) -> None:
    ex = Scripted()
    say(world, ex, "A사", "계약 만료일", "2027-01-01")
    say(world, ex, "A사", "계약 시작일", "2026-01-01")
    assert [k[1] for k in keys(world)] == ["계약 만료일", "계약 시작일"]


EMBED = FakeEmbedder({"결제 모듈": 1, "payment module": 1, "컨택": 2, "담당자": 2, "계약": 3})


@pytest.mark.db
def test_embedding_reuses_entity_and_attribute_with_no_shared_letters(world: Pool) -> None:
    ex = Scripted()
    first = say(world, ex, "결제 모듈", "담당자", "이OO", EMBED)
    second = say(world, ex, "payment module", "컨택", "박OO", EMBED)
    assert second.conflict_with == first.memory_id
    assert [k[:2] for k in keys(world)] == [("결제 모듈", "담당자")] * 2


@pytest.mark.db
def test_embedding_outage_creates_instead_of_failing(world: Pool) -> None:
    ex = Scripted()
    say(world, ex, "결제 모듈", "담당자", "이OO", DownEmbedder())
    say(world, ex, "payment module", "컨택", "박OO", DownEmbedder())
    assert [k[:2] for k in keys(world)] == [("결제 모듈", "담당자"), ("payment module", "컨택")]


@pytest.mark.db
@pytest.mark.parametrize(
    ("floor", "entities"), [(0.5, ["결제 모듈"]), (0.8, ["결제 모듈", "결제 모듈 서비스"])]
)
def test_the_cosine_floor_decides_the_embedding_merge(
    world: Pool, floor: float, entities: list[str]
) -> None:
    ex = Scripted()
    embedder = FakeEmbedder({"결제 모듈": 1, "서비스": 5})
    ex.attribute, ex.body = "담당자", "이OO"
    with request_tx(world, USER, None) as conn:
        for subject in ("결제 모듈", "결제 모듈 서비스"):
            ex.subject = subject
            capture(
                conn,
                ex,
                "x",
                CTX,
                embedder,
                ResolveConfig(subject_cosine_min=floor, trigram_min=1.0),
            )
    assert sorted({k[0] for k in keys(world)}) == entities


@pytest.mark.db
def test_the_extractor_is_offered_known_entities_with_attributes(world: Pool) -> None:
    ex = Scripted()
    say(world, ex, "A사", "담당자", "이OO")
    say(world, ex, "A사", "계약 만료일", "2027-01-01")
    say(world, ex, "A사", "담당자", "소식", source="A사 소식")
    assert ex.seen is not None
    [offered] = ex.seen.entities
    assert (offered.name, offered.aliases, sorted(offered.attributes)) == (
        "A사",
        ("a사",),
        ["계약 만료일", "담당자"],
    )


@pytest.mark.db
def test_only_an_offered_entity_id_is_trusted(world: Pool) -> None:
    ex = Scripted()
    say(world, ex, "A사", "담당자", "이OO")
    say(world, ex, "B사", "담당자", "최OO")
    say(world, ex, "B사", "담당자", "최OO 휴직", source="A사와 B사 담당자 정리")
    assert ex.seen is not None
    a_id = next(e.id for e in ex.seen.entities if e.name == "A사")
    ex.entity_id = a_id
    say(world, ex, "컨택처", "담당자", "박OO", source="A사 소식")
    ex.entity_id = UUID(int=7)
    say(world, ex, "C사", "담당자", "정OO", source="A사 소식")
    assert [k[0] for k in keys(world)] == ["A사", "B사", "B사", "A사", "C사"]
