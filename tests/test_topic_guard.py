from datetime import UTC, date, datetime

import pytest

from nunchi.capture import CaptureContext, Created, capture
from nunchi.db import Pool, request_tx
from nunchi.domain.models import Evidence, MemoryOrigin, SourceRef
from nunchi.extract import Consensus, ExtractContext, ProposalDraft
from tests.conftest import STORE, USER
from tests.test_repo import world as world  # noqa: PLC0414 - fixture re-export

CSS_TITLE = "프론트 스타일링 방식으로 CSS Modules + CSS 커스텀 프로퍼티 채택"
NEXT_TITLE = "프론트 ?next= 처리는 PR #21과 병행하지 않고 독립 PR로 진행"
TAILWIND_TITLE = "프론트 스타일링을 Tailwind로 변경"
STYLING = ("스타일", "css", "tailwind")


class TopicJudge:
    """Topics by keyword; never the same decision when the values differ."""

    def __init__(self, error: bool = False) -> None:
        self.error = error

    def same(self, first: str, second: str, first_title: str = "", second_title: str = "") -> bool:
        return first.casefold() == second.casefold()

    def same_topic(
        self, first: str, second: str, first_title: str = "", second_title: str = ""
    ) -> bool:
        if self.error:
            return False
        about = [any(k in t.casefold() for k in STYLING) for t in (first_title, second_title)]
        return about[0] == about[1]


def say(  # noqa: PLR0913 - one message: who, what, how sure
    pool: Pool,
    title: str,
    value: str,
    n: int,
    *,
    agreed: bool = True,
    judge: TopicJudge | None = None,
) -> Created:
    class Ex:
        def extract(self, source_text: str, context: ExtractContext) -> tuple[ProposalDraft, ...]:
            return (
                ProposalDraft(
                    kind="decision",
                    title=title,
                    body=title,
                    subject_name="프론트",
                    attribute="스타일 방식",
                    value=value,
                    source_refs=context.source_refs,
                    origin=context.origin,
                ),
            )

    evidence = tuple(
        Evidence(
            uri=f"https://mm.example/p/{n}{who}",
            post_id=f"p{n}{who}",
            author=who,
            said_at=datetime(2026, 10, 14, 6, n, tzinfo=UTC),
        )
        for who in ("a", "b")
    )
    context = CaptureContext(
        store_id=STORE,
        origin=MemoryOrigin.EXTERNAL,
        source_refs=(SourceRef(uri=f"https://mm.example/p/{n}a", system="mattermost"),),
        today=date(2026, 10, 14),
        consensus=Consensus.AGREED if agreed else Consensus.STATED,
        evidence=evidence if agreed else evidence[:1],
    )
    with request_tx(pool, USER, None) as conn:
        result = capture(conn, Ex(), title, context, None, None, judge or TopicJudge())
    assert isinstance(result, Created)
    return result


def rows(pool: Pool) -> list[tuple[str, str, str]]:
    with request_tx(pool, USER, None) as conn:
        found = conn.execute(
            "SELECT attribute, value, status::text FROM memory WHERE value IS NOT NULL"
            " ORDER BY created_at, id"
        ).fetchall()
    return [(str(a), str(v), str(s)) for a, v, s in found]


@pytest.mark.db
def test_another_topic_agreed_under_an_occupied_key_gets_its_own_attribute(world: Pool) -> None:
    css = say(world, CSS_TITLE, "CSS Modules + CSS 커스텀 프로퍼티", 1)
    other = say(world, NEXT_TITLE, "독립 PR", 2)
    assert (css.status.value, css.change) == ("active", "created")
    assert (other.status.value, other.change) == ("active", "created")
    assert rows(world) == [
        ("스타일 방식", "css modules + css 커스텀 프로퍼티", "active"),
        (NEXT_TITLE.casefold(), "독립 pr", "active"),
    ]


@pytest.mark.db
def test_another_topic_stated_under_an_occupied_key_is_no_challenger(world: Pool) -> None:
    say(world, CSS_TITLE, "CSS Modules + CSS 커스텀 프로퍼티", 1)
    other = say(world, NEXT_TITLE, "독립 PR", 2, agreed=False)
    assert (other.status.value, other.change, other.conflict_with) == (
        "provisional",
        "created",
        None,
    )
    assert [s for _a, _v, s in rows(world)] == ["active", "provisional"]


@pytest.mark.db
def test_a_judge_error_means_another_topic_never_a_supersede(world: Pool) -> None:
    say(world, CSS_TITLE, "CSS Modules", 1)
    changed = say(world, TAILWIND_TITLE, "Tailwind", 2, judge=TopicJudge(error=True))
    assert changed.change == "created"
    assert [(v, s) for _a, v, s in rows(world)] == [
        ("css modules", "active"),
        ("tailwind", "active"),
    ]


@pytest.mark.db
def test_a_real_topic_change_still_supersedes(world: Pool) -> None:
    css = say(world, CSS_TITLE, "CSS Modules", 1)
    tailwind = say(world, TAILWIND_TITLE, "Tailwind로 변경", 2)
    assert tailwind.change == "superseded"
    assert rows(world) == [
        ("스타일 방식", "css modules", "superseded"),
        ("스타일 방식", "tailwind로 변경", "active"),
    ]
    assert tailwind.memory_id != css.memory_id


@pytest.mark.db
def test_a_real_topic_change_stated_is_still_a_challenger(world: Pool) -> None:
    css = say(world, CSS_TITLE, "CSS Modules", 1)
    tailwind = say(world, TAILWIND_TITLE, "Tailwind로 변경", 2, agreed=False)
    assert (tailwind.change, tailwind.conflict_with) == ("challenged", css.memory_id)
