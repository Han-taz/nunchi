from datetime import UTC, date, datetime

import pytest

from nunchi.capture import CaptureContext, Created, capture
from nunchi.capture.vocab import settle_attribute, slug
from nunchi.db import Pool, request_tx
from nunchi.domain import repo
from nunchi.domain.models import (
    Evidence,
    MemoryKind,
    MemoryOrigin,
    ProposeRequest,
    SourceRef,
)
from nunchi.extract import Consensus, ExtractContext, ProposalDraft
from tests.conftest import STORE, USER
from tests.test_repo import world as world  # noqa: PLC0414 - fixture re-export

BORDER = "라이트 테마 --color-border(#D9D9D9)는 흰 배경에서 대비 1.4:1로 미달"
TERTIARY = "라이트 테마 텍스트 삼차색(#9CA3AF)은 흰 배경에서 대비 약 2.46:1로 미달"
BORDER_Q = "라이트 테마 border 색의 대비 비율"
TERTIARY_Q = "라이트 테마 텍스트 삼차색의 대비 비율"


class ByQuestion:
    """Answers every question comparison the same way, counts them, and says values are the same
    when they are equal."""

    def __init__(self, merge: bool = False, error: bool = False) -> None:
        self.merge, self.error, self.asked = merge, error, 0

    def same_question(self, first: str, second: str) -> bool:
        self.asked += 1
        return self.merge and not self.error

    def same(self, first: str, second: str, first_title: str = "", second_title: str = "") -> bool:
        return first.casefold() == second.casefold()


def say(  # noqa: PLR0913, PLR0917 - one message: key, question, value, how sure
    pool: Pool,
    key: str,
    question: str | None,
    title: str,
    value: str,
    n: int,
    *,
    agreed: bool = True,
    judge: ByQuestion | None = None,
) -> Created:
    class Ex:
        def extract(self, source_text: str, context: ExtractContext) -> tuple[ProposalDraft, ...]:
            return (
                ProposalDraft(
                    kind="decision",
                    title=title,
                    body=title,
                    subject_name="globals.css",
                    attribute=key,
                    attribute_label=key.replace("-", " "),
                    attribute_question=question,
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
        result = capture(conn, Ex(), title, context, None, None, judge or ByQuestion())
    assert isinstance(result, Created)
    return result


def rows(pool: Pool) -> list[tuple[str, str, str]]:
    with request_tx(pool, USER, None) as conn:
        found = conn.execute(
            "SELECT attribute, value, status::text FROM memory WHERE value IS NOT NULL"
            " ORDER BY created_at, id"
        ).fetchall()
    return [(str(a), str(v), str(s)) for a, v, s in found]


def vocabulary(pool: Pool) -> list[tuple[str, str, str]]:
    with request_tx(pool, USER, None) as conn:
        found = conn.execute(
            "SELECT key, label, question FROM attribute_vocab ORDER BY created_at, key"
        ).fetchall()
    return [(str(k), str(lb), str(q)) for k, lb, q in found]


@pytest.mark.parametrize(
    ("text", "key"),
    [
        ("Border Contrast", "border-contrast"),
        ("v1.0 포함 여부", "v1-0-포함-여부"),
        ("  --color-border 대비 ", "color-border-대비"),
        ("???", "attribute"),
        ("x" * 60, "x" * 40),
        ("가나다-" * 20, ("가나다-" * 20)[:40].strip("-")),
    ],
)
def test_a_key_is_a_short_lowercase_slug(text: str, key: str) -> None:
    assert slug(text) == key


@pytest.mark.db
def test_two_questions_of_one_subject_keep_both_decisions_live(world: Pool) -> None:
    """The live failure: border contrast was superseded by the tertiary text's contrast."""
    border = say(world, "border-contrast", BORDER_Q, BORDER, "라이트 1.4:1 미달", 1)
    tertiary = say(world, "tertiary-contrast", TERTIARY_Q, TERTIARY, "라이트 2.46:1 미달", 2)
    assert (border.change, tertiary.change) == ("created", "created")
    assert rows(world) == [
        ("border-contrast", "라이트 1.4:1 미달", "active"),
        ("tertiary-contrast", "라이트 2.46:1 미달", "active"),
    ]
    assert vocabulary(world) == [
        ("border-contrast", "border contrast", BORDER_Q),
        ("tertiary-contrast", "tertiary contrast", TERTIARY_Q),
    ]


@pytest.mark.db
def test_the_same_key_is_the_same_topic_and_a_new_value_supersedes_without_a_judge(
    world: Pool,
) -> None:
    judge = ByQuestion()
    first = say(world, "border-contrast", BORDER_Q, BORDER, "라이트 1.4:1 미달", 1, judge=judge)
    changed = say(world, "border-contrast", None, BORDER, "라이트 3.1:1 통과", 2, judge=judge)
    assert (changed.change, changed.memory_id != first.memory_id) == ("superseded", True)
    assert [(v, s) for _a, v, s in rows(world)] == [
        ("라이트 1.4:1 미달", "superseded"),
        ("라이트 3.1:1 통과", "active"),
    ]
    assert judge.asked == 0
    assert len(vocabulary(world)) == 1


@pytest.mark.db
def test_a_new_key_that_asks_an_existing_question_lands_on_that_key(world: Pool) -> None:
    say(world, "border-contrast", BORDER_Q, BORDER, "라이트 1.4:1 미달", 1)
    again = say(
        world,
        "border-color-ratio",
        "border 색은 흰 배경과 몇 대 몇인가",
        BORDER,
        "라이트 3.1:1 통과",
        2,
        judge=ByQuestion(merge=True),
    )
    assert again.change == "superseded"
    assert [a for a, _v, _s in rows(world)] == ["border-contrast", "border-contrast"]
    assert [k for k, _l, _q in vocabulary(world)] == ["border-contrast"]


@pytest.mark.db
@pytest.mark.parametrize("judge", [ByQuestion(error=True), None])
def test_without_a_working_judge_a_new_key_is_a_new_question_and_nothing_is_replaced(
    world: Pool, judge: ByQuestion | None
) -> None:
    say(world, "border-contrast", BORDER_Q, BORDER, "라이트 1.4:1 미달", 1)
    other = say(
        world,
        "tertiary-contrast",
        TERTIARY_Q,
        TERTIARY,
        "라이트 2.46:1 미달",
        2,
        judge=judge or ByQuestion(error=True),
    )
    assert other.change == "created"
    assert [s for _a, _v, s in rows(world)] == ["active", "active"]


@pytest.mark.db
def test_a_proposal_without_a_question_registers_its_label_as_the_question(world: Pool) -> None:
    say(world, "border-contrast", None, BORDER, "라이트 1.4:1 미달", 1)
    assert vocabulary(world) == [("border-contrast", "border contrast", "border contrast")]


@pytest.mark.db
def test_an_attribute_stored_before_the_vocabulary_is_a_key_the_subject_already_has(
    world: Pool,
) -> None:
    ref = SourceRef(uri="https://mm.example/p/old", system="mattermost")
    with request_tx(world, USER, None) as conn:
        subject = conn.execute("SELECT app_sec.create_entity('globals.css', 'subject')").fetchone()
        assert subject is not None
        repo.remember(
            conn,
            ProposeRequest(
                store_id=STORE,
                kind=MemoryKind.DECISION,
                title=BORDER,
                source_refs=(ref,),
                subject_id=subject[0],
                attribute="border 대비",
                value="라이트 1.4:1 미달",
            ),
        )
    judge = ByQuestion(merge=True)
    again = say(world, "border 대비", None, BORDER, "라이트 3.1:1 통과", 2, judge=judge)
    assert (again.change, judge.asked, vocabulary(world)) == ("superseded", 0, [])
    assert [a for a, _v, _s in rows(world)] == ["border 대비", "border 대비"]


@pytest.mark.db
def test_a_note_has_no_attribute_to_settle(world: Pool) -> None:
    note = ProposalDraft(kind=MemoryKind.NOTE, title="메모", origin=MemoryOrigin.EXTERNAL)
    with request_tx(world, USER, None) as conn:
        assert settle_attribute(conn, STORE, STORE, note, None) is note
