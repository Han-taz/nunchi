from datetime import date

import pytest

from nunchi.capture import CaptureContext, Created, Reconfirmed, capture
from nunchi.capture.resolve import ResolveConfig
from nunchi.capture.same import numbers_conflict, strip_honorific
from nunchi.db import Pool, request_tx
from nunchi.domain.models import MemoryKind, MemoryOrigin, SourceRef
from nunchi.extract import ExtractContext, ProposalDraft, ValueJudge
from tests.conftest import STORE, USER
from tests.test_repo import world as world  # noqa: PLC0414 - fixture re-export

CTX = CaptureContext(
    store_id=STORE,
    origin=MemoryOrigin.EXTERNAL,
    source_refs=(SourceRef(uri="https://example.slack.com/archives/C1/p1", system="slack"),),
    today=date(2026, 10, 13),
)


@pytest.mark.parametrize(
    ("value", "stripped"),
    [
        ("이민수님", "이민수"),
        ("정하늘 매니저님", "정하늘"),
        ("최지우 매니저", "최지우"),
        ("한솔님", "한솔"),
        ("이민수 씨", "이민수"),
        ("박민수", "박민수"),
        ("이사회", "이사회"),
        ("대리점", "대리점"),
        ("과장", "과장"),
        ("김 과장", "김 과장"),
        ("김 대리", "김 대리"),
        ("이민수 과장님", "이민수"),
        ("이민수 과장", "이민수"),
        ("영업팀장", "영업팀장"),
        ("영업부장", "영업부장"),
        ("개발이사", "개발이사"),
        ("매니저먼트", "매니저먼트"),
        ("이민수과장", "이민수과장"),
        ("Postgres", "Postgres"),
        ("30초", "30초"),
    ],
)
def test_honorific_is_stripped_only_from_a_name(value: str, stripped: str) -> None:
    assert strip_honorific(value) == stripped


@pytest.mark.parametrize(
    ("a", "b", "conflict"),
    [
        ("백업 14일 보관", "백업 30일 보관", True),
        ("백업 14일 보관", "백업 보관", False),
        ("백업 14일 보관", "14일 백업 보관", False),
    ],
)
def test_numbers_that_conflict_are_different_answers(a: str, b: str, conflict: bool) -> None:
    assert numbers_conflict(a, b) is conflict


class FakeJudge:
    """Says what it is told and records what it was asked."""

    def __init__(self, answer: bool = True, topic: bool = True) -> None:
        self.answer = answer
        self.topic = topic
        self.asked: list[tuple[str, str]] = []

    def same_question(self, first: str, second: str) -> bool:
        return self.topic

    def same(self, first: str, second: str, first_title: str = "", second_title: str = "") -> bool:
        self.asked.append((first, second))
        return self.answer


class Say:
    def __init__(
        self, pool: Pool, judge: ValueJudge | None = None, cfg: ResolveConfig | None = None
    ) -> None:
        self.pool, self.judge, self.cfg = pool, judge, cfg

    def __call__(
        self, value: str, *, attribute: str = "담당자", kind: MemoryKind = MemoryKind.FACT
    ) -> Created | Reconfirmed:
        draft_value = value

        class Ex:
            def extract(
                self, source_text: str, context: ExtractContext
            ) -> tuple[ProposalDraft, ...]:
                return (
                    ProposalDraft(
                        kind=kind,
                        title=source_text,
                        body=source_text,
                        subject_name="A사",
                        attribute=attribute,
                        value=draft_value,
                        source_refs=context.source_refs,
                        origin=context.origin,
                    ),
                )

        with request_tx(self.pool, USER, None) as conn:
            result = capture(conn, Ex(), f"{attribute} {value}", CTX, None, self.cfg, self.judge)
        assert isinstance(result, Created | Reconfirmed)
        return result


def stored(pool: Pool) -> list[tuple[str, str]]:
    with request_tx(pool, USER, None) as conn:
        rows = conn.execute(
            "SELECT attribute, value FROM memory WHERE value IS NOT NULL ORDER BY created_at"
        ).fetchall()
    return [(str(a), str(v)) for a, v in rows]


@pytest.mark.db
def test_honorific_variant_reconfirms_and_stores_the_bare_name(world: Pool) -> None:
    say = Say(world)
    first = say("이민수")
    again = say("이민수님")
    assert isinstance(again, Reconfirmed)
    assert again.memory_id == first.memory_id
    assert stored(world) == [("담당자", "이민수")]


@pytest.mark.db
def test_a_different_person_is_an_update_not_a_merge(world: Pool) -> None:
    say = Say(world)
    first = say("이민수님")
    second = say("박민수님")
    assert isinstance(second, Created)
    assert second.conflict_with == first.memory_id
    assert stored(world) == [("담당자", "이민수"), ("담당자", "박민수")]


@pytest.mark.db
def test_a_live_row_with_an_honorific_still_matches_a_bare_name(world: Pool) -> None:
    with request_tx(world, USER, None) as conn:
        conn.execute("SELECT 1")
    say = Say(world)
    first = say("정하늘")
    again = say("정하늘 매니저님")
    assert isinstance(again, Reconfirmed)
    assert again.memory_id == first.memory_id


@pytest.mark.db
def test_synonym_attribute_lands_on_the_existing_key_with_no_embedder(world: Pool) -> None:
    say = Say(world)
    first = say("이민수", attribute="담당자")
    again = say("이민수님", attribute="담당 PM")
    assert isinstance(again, Reconfirmed)
    assert again.memory_id == first.memory_id
    update = say("박민수", attribute="PM")
    assert isinstance(update, Created)
    assert update.conflict_with == first.memory_id
    assert {a for a, _ in stored(world)} == {"담당자"}


PROC = MemoryKind.FACT  # a procedure proposal is not live until approved, so a fact stands in
OLD = "PR 머지→릴리즈 태그→deploy prod→스모크 테스트 5분 확인"
RESTATED = "머지 후 태그 달고 deploy 하고 스모크 확인하는 순서로"


@pytest.mark.db
def test_restated_procedure_merges_when_the_judge_says_same(world: Pool) -> None:
    judge = FakeJudge(True)
    say = Say(world, judge)
    first = say(OLD, attribute="procedure", kind=PROC)
    again = say(RESTATED, attribute="procedure", kind=PROC)
    assert isinstance(again, Reconfirmed)
    assert again.memory_id == first.memory_id
    assert stored(world) == [("procedure", OLD.lower())]
    assert judge.asked == [(RESTATED, OLD.lower())]


@pytest.mark.db
def test_restated_procedure_is_an_update_when_the_judge_says_different(world: Pool) -> None:
    say = Say(world, FakeJudge(False))
    first = say(OLD, attribute="procedure", kind=PROC)
    changed = say(RESTATED, attribute="procedure", kind=PROC)
    assert isinstance(changed, Created)
    assert changed.conflict_with == first.memory_id


@pytest.mark.db
def test_no_judge_means_a_restated_procedure_is_an_update(world: Pool) -> None:
    say = Say(world, None)
    first = say(OLD, attribute="procedure", kind=PROC)
    again = say(RESTATED, attribute="procedure", kind=PROC)
    assert isinstance(again, Created)
    assert again.conflict_with == first.memory_id


@pytest.mark.db
def test_differing_numbers_are_different_without_asking_the_judge(world: Pool) -> None:
    judge = FakeJudge(True)
    say = Say(world, judge)
    first = say("매일 새벽 3시 백업하고 14일 동안 보관한다", attribute="백업")
    again = say("매일 새벽 3시 백업하고 30일 동안 보관한다", attribute="백업")
    assert isinstance(again, Created)
    assert again.conflict_with == first.memory_id
    assert judge.asked == []


@pytest.mark.db
def test_short_paraphrase_reconfirms_when_the_judge_says_same(world: Pool) -> None:
    judge = FakeJudge(True)
    say = Say(world, judge)
    first = say("v1.0에서 제거", attribute="v1.0 포함 여부")
    again = say("v1.0 범위에서 제외", attribute="v1.0 포함 여부")
    assert isinstance(again, Reconfirmed)
    assert again.memory_id == first.memory_id
    assert stored(world) == [("v1-0-포함-여부", "v1.0에서 제거")]
    assert judge.asked == [("v1.0 범위에서 제외", "v1.0에서 제거")]


@pytest.mark.db
def test_short_value_the_judge_calls_different_is_a_challenger(world: Pool) -> None:
    say = Say(world, FakeJudge(False))
    first = say("Mattermost API로 조회", attribute="조회 방식")
    other = say("User.teams 읽기", attribute="조회 방식")
    assert isinstance(other, Created)
    assert other.status.value == "challenger"
    assert other.conflict_with == first.memory_id


@pytest.mark.db
def test_a_paraphrase_of_the_open_challenger_reconfirms_the_challenger(world: Pool) -> None:
    class ByWord:
        def same(
            self, first: str, second: str, first_title: str = "", second_title: str = ""
        ) -> bool:
            return ("읽기" in first) == ("읽기" in second)

        def same_question(self, first: str, second: str) -> bool:
            return True

    say = Say(world, ByWord())
    live = say("Mattermost API로 조회", attribute="조회 방식")
    challenger = say("User.teams 읽기", attribute="조회 방식")
    again = say("User.teams 를 읽기", attribute="조회 방식")
    assert isinstance(challenger, Created)
    assert isinstance(again, Reconfirmed)
    assert again.memory_id == challenger.memory_id
    assert challenger.conflict_with == live.memory_id


@pytest.mark.db
def test_same_decision_under_another_attribute_lands_on_the_existing_key(world: Pool) -> None:
    judge = FakeJudge(True)
    say = Say(world, judge)
    first = say("Mattermost 팀 멤버십", attribute="팀 정보 출처")
    again = say("Mattermost API 팀 멤버십 조회", attribute="_user_teams 조회 방식")
    assert isinstance(again, Reconfirmed)
    assert again.memory_id == first.memory_id
    assert stored(world) == [("팀-정보-출처", "mattermost 팀 멤버십")]


@pytest.mark.db
def test_other_attribute_with_a_different_decision_stays_a_new_key(world: Pool) -> None:
    say = Say(world, FakeJudge(False, topic=False))
    say("Mattermost 팀 멤버십", attribute="팀 정보 출처")
    other = say("Mattermost API 팀 멤버십 조회", attribute="_user_teams 조회 방식")
    assert isinstance(other, Created)
    assert [a for a, _ in stored(world)] == ["팀-정보-출처", "user_teams-조회-방식"]


@pytest.mark.db
def test_values_of_another_question_never_reach_the_value_judge(world: Pool) -> None:
    judge = FakeJudge(True, topic=False)
    say = Say(world, judge)
    say("이민수", attribute="담당자")
    say("매월 1일", attribute="정산일")
    assert judge.asked == []


@pytest.mark.db
def test_title_glued_to_a_word_is_not_a_person(world: Pool) -> None:
    say = Say(world, None)
    first = say("영업부장", attribute="담당")
    other = say("영업팀장", attribute="담당")
    assert isinstance(other, Created)
    assert other.conflict_with == first.memory_id
