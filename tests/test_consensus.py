from datetime import UTC, datetime

import pytest

from nunchi.domain.models import Evidence
from nunchi.extract import (
    Consensus,
    WindowPost,
    confirm_consensus,
    evidence_for,
    render_numbered,
)

A, B = "minji.kim", "junho.park"


def post(author: str, text: str = "네", *, bot: bool = False) -> WindowPost:
    return WindowPost(author=author, text=text, bot=bot)


def test_the_window_renders_one_numbered_line_per_post() -> None:
    posts = [post(A, "스타일은 CSS Modules로 가요 "), post(B, "좋아요")]
    assert (
        render_numbered(posts)
        == "[0] minji.kim: 스타일은 CSS Modules로 가요\n[1] junho.park: 좋아요"
    )


def test_two_authors_among_the_evidence_are_agreed() -> None:
    posts = [post(A, "코드 프리즈는 12/18이 어때요?"), post(B, "좋아요, 12/18로 가죠")]
    assert confirm_consensus(Consensus.AGREED, [0, 1], posts) is Consensus.AGREED


def test_one_author_cited_twice_is_stated() -> None:
    posts = [post(A, "백업은 30일로 할게요"), post(A, "30일 보관이요")]
    assert confirm_consensus(Consensus.AGREED, [0, 1], posts) is Consensus.STATED


def test_a_declaration_answered_later_by_someone_else_is_agreed() -> None:
    posts = [post(A, "로그 레벨은 운영에서 warn으로 확정합니다"), post(B, "네")]
    assert confirm_consensus(Consensus.AGREED, [0], posts) is Consensus.AGREED


def test_a_declaration_that_ends_the_window_is_stated() -> None:
    posts = [post(B, "점심 뭐 먹죠"), post(A, "로그 레벨은 운영에서 warn으로 확정합니다")]
    assert confirm_consensus(Consensus.AGREED, [1], posts) is Consensus.STATED


def test_an_answer_before_the_declaration_does_not_count() -> None:
    posts = [post(B, "네"), post(A, "warn으로 확정합니다")]
    assert confirm_consensus(Consensus.AGREED, [1], posts) is Consensus.STATED


def test_a_reply_by_the_same_author_does_not_answer_the_declaration() -> None:
    posts = [post(A, "warn으로 확정합니다"), post(A, "참고로 운영 기준입니다")]
    assert confirm_consensus(Consensus.AGREED, [0], posts) is Consensus.STATED


def test_a_statement_without_a_decision_marker_needs_two_authors() -> None:
    posts = [post(A, "정기 배포는 목요일로 하죠"), post(B, "저는 아직 잘 모르겠어요")]
    assert confirm_consensus(Consensus.AGREED, [0], posts) is Consensus.STATED


def test_bot_posts_are_not_counted_as_a_second_author() -> None:
    posts = [post(A, "배포 주기는 격주로 정했습니다"), post("nunchi", "기록할게요", bot=True)]
    assert confirm_consensus(Consensus.AGREED, [0, 1], posts) is Consensus.STATED


def test_a_bot_does_not_answer_a_declaration() -> None:
    posts = [post(A, "warn으로 확정합니다"), post("nunchi", "알림 설정됨", bot=True)]
    assert confirm_consensus(Consensus.AGREED, [0], posts) is Consensus.STATED


def test_a_bots_own_declaration_is_not_a_declaration() -> None:
    posts = [post("nunchi", "배포 주기 확정", bot=True), post(A, "네")]
    assert confirm_consensus(Consensus.AGREED, [0], posts) is Consensus.STATED


@pytest.mark.parametrize("marker", ["결정", "확정", "합의", "하기로 했", "으로 가기로"])
def test_every_decision_marker_counts(marker: str) -> None:
    posts = [post(A, f"스타일은 CSS {marker}"), post(B)]
    assert confirm_consensus(Consensus.AGREED, [0], posts) is Consensus.AGREED


@pytest.mark.parametrize("evidence", [[], [5], [-1]])
def test_evidence_outside_the_window_proves_nothing(evidence: list[int]) -> None:
    posts = [post(A, "warn으로 확정합니다"), post(B)]
    assert confirm_consensus(Consensus.AGREED, evidence, posts) is Consensus.STATED


def test_a_stated_claim_stays_stated_whatever_the_window_shows() -> None:
    posts = [post(A, "12/18로 확정"), post(B, "좋아요")]
    assert confirm_consensus(Consensus.STATED, [0, 1], posts) is Consensus.STATED


def test_evidence_for_returns_the_platform_data_of_cited_human_posts_in_window_order() -> None:
    def ref(n: int) -> Evidence:
        return Evidence(
            uri=f"https://mm/pl/{n}",
            post_id=f"p{n}",
            author=f"u{n}",
            said_at=datetime(2026, 10, 14, 9, n, tzinfo=UTC),
        )

    posts = [
        WindowPost(author="a", text="x", ref=ref(0)),
        WindowPost(author="b", text="x", bot=True, ref=ref(1)),
        WindowPost(author="c", text="x"),
        WindowPost(author="d", text="x", ref=ref(3)),
    ]

    assert [e.post_id for e in evidence_for([3, 0, 0, 1, 2, 9, -1], posts)] == ["p0", "p3"]
