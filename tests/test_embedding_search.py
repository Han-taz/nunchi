from datetime import date

import pytest

from nunchi.capture import CaptureContext, capture
from nunchi.db import Pool, request_tx
from nunchi.domain import repo
from nunchi.domain.models import MemoryOrigin, MemoryStatus, SourceRef
from nunchi.extract import ExtractContext, ProposalDraft
from tests.conftest import STORE, USER
from tests.embed_fake import DownEmbedder, FakeEmbedder
from tests.test_embedding_worker import embedded as embedded  # noqa: PLC0414 - fixture re-export
from tests.test_repo import HIDDEN_STORE
from tests.test_repo import world as world  # noqa: PLC0414 - fixture re-export

LIVE = (MemoryStatus.ACTIVE,)


def titles(
    pool: Pool, query: str, embedder: FakeEmbedder | DownEmbedder | None, floor: float = 0.4
) -> list[str]:
    with request_tx(pool, USER, None) as conn:
        hits = repo.search(conn, query, None, None, LIVE, embedder=embedder, vector_floor=floor)
        return [h.title for h in hits]


@pytest.mark.db
def test_a_variant_spelling_finds_the_memory_only_when_vectors_are_on(
    world: Pool, embedded: FakeEmbedder
) -> None:
    assert titles(world, "에이사", None) == []
    assert titles(world, "에이사", embedded) == ["A사 담당자는 이OO"]


@pytest.mark.db
def test_the_vector_floor_decides_how_close_a_vector_match_must_be(
    world: Pool, embedded: FakeEmbedder
) -> None:
    """ "에이사" and the A사 memory share one of two concepts: cosine similarity 0.707."""
    assert titles(world, "에이사", embedded, floor=0.7) == ["A사 담당자는 이OO"]
    assert titles(world, "에이사", embedded, floor=0.8) == []


@pytest.mark.db
def test_a_down_service_gives_exactly_the_trigram_answer(
    world: Pool, embedded: FakeEmbedder
) -> None:
    assert titles(world, "점검 주기", DownEmbedder()) == titles(world, "점검 주기", None)
    assert titles(world, "점검 주기", None) == ["배포 서버 점검 주기"]


@pytest.mark.db
def test_the_store_the_reader_cannot_see_never_surfaces(
    world: Pool, embedded: FakeEmbedder
) -> None:
    found = titles(world, "A사 서버", embedded)
    assert "A사 서버 비밀" not in found
    assert found == ["A사 담당자는 이OO", "배포 서버 점검 주기"]
    with request_tx(world, USER, None) as conn:
        assert repo.search(conn, "A사 서버", [HIDDEN_STORE], None, LIVE, embedder=embedded) == []


class RecordingExtractor:
    def __init__(self) -> None:
        self.candidates: list[str] = []

    def extract(self, source_text: str, context: ExtractContext) -> ProposalDraft | None:
        self.candidates = [c.title for c in context.candidates]
        return None


@pytest.mark.db
def test_capture_surfaces_the_existing_memory_under_another_spelling(
    world: Pool, embedded: FakeEmbedder
) -> None:
    ctx = CaptureContext(
        store_id=STORE,
        origin=MemoryOrigin.EXTERNAL,
        source_refs=(SourceRef(uri="https://x.slack.com/archives/C1/p1", system="slack"),),
        today=date(2026, 10, 13),
    )
    for embedder, expected in ((None, []), (embedded, ["A사 담당자는 이OO"])):
        extractor = RecordingExtractor()
        with request_tx(world, USER, None) as conn:
            capture(conn, extractor, "에이사 건", ctx, embedder)
        assert extractor.candidates == expected


@pytest.mark.db
def test_the_query_is_embedded_with_the_query_prompt(world: Pool, embedded: FakeEmbedder) -> None:
    titles(world, "에이사", embedded)
    assert embedded.calls[-1] == ("query", 1)
