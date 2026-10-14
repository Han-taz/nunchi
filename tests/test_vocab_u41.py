import contextlib
import importlib.util
import io
import json
import sys
from types import ModuleType

import psycopg
import pytest

from nunchi.db import Pool, request_tx
from nunchi.extract import AttributeSpec
from tests.conftest import REPO, STORE, USER

SCRIPT = REPO / "scripts" / "vocab-u41.py"
CSS = "프론트 스타일링 방식으로 CSS Modules + CSS 커스텀 프로퍼티 채택"
NEXT = "프론트 ?next= 처리는 PR #21과 병행하지 않고 독립 PR로 진행"
TAILWIND = "프론트 스타일링을 Tailwind로 변경"
BACKUP = "백업은 14일 보관"
GUIDE = "스타일 가이드는 Figma로 공유"


SENTENCE = "프론트 ?next= 처리는 PR #21과 병행하지 않고 독립 PR로 진행"
SPECS = {
    "Figma": AttributeSpec(
        key="guide-tool", label="가이드 도구", question="스타일 가이드는 어디에?"
    ),
    "스타일": AttributeSpec(key="Styling", label="스타일링", question="프론트 스타일링 방식은?"),
    "?next=": AttributeSpec(key="next-owner", label="next 담당", question="?next= 처리는 누가?"),
    "백업": AttributeSpec(key="backup-days", label="보관 기간", question="백업 보관 기간은?"),
}


class Questions:
    """Describes a memory by the keyword in its title; two questions are the same when equal."""

    def __init__(self, blind: bool = False) -> None:
        self.blind = blind

    def describe(self, title: str, value: str, attribute: str) -> AttributeSpec | None:
        found = [spec for word, spec in SPECS.items() if word in title]
        return None if self.blind or not found else found[0]

    def same_question(self, first: str, second: str) -> bool:
        return first == second


def load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("vocab_u41", SCRIPT)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["vocab_u41"] = module
    spec.loader.exec_module(module)
    return module


def put(  # noqa: PLR0913, PLR0917 - one message stored by the pre-U40 pipeline
    pool: Pool,
    subject: str,
    attribute: str,
    value: str,
    title: str,
    n: int,
    agreed: bool,
) -> None:
    evidence = [
        {"uri": f"https://mm.example/p/{n}{w}", "post_id": f"p{n}{w}", "author": w}
        for w in (("a", "b") if agreed else ("a",))
    ]
    with request_tx(pool, USER, None) as conn:
        entity = conn.execute("SELECT app_sec.resolve_entity(%s)", (subject,)).fetchone()
        assert entity is not None
        subject_id = (
            entity[0]
            or conn.execute("SELECT app_sec.create_entity(%s, 'subject')", (subject,)).fetchone()[0]  # type: ignore[index]
        )
        conn.execute(
            "SELECT app_sec.remember(%s, 'decision', %s, %s, %s::jsonb, %s, %s, %s, '{}'::jsonb,"
            " %s, %s::jsonb)",
            (
                STORE,
                title,
                title,
                json.dumps([{"uri": f"https://mm.example/p/{n}a", "system": "mattermost"}]),
                subject_id,
                attribute,
                value,
                "agreed" if agreed else "stated",
                json.dumps(evidence),
            ),
        )


def state(url: str) -> list[tuple[str, str, str]]:
    with psycopg.connect(url) as conn:
        return [
            (str(a), str(v), str(s))
            for a, v, s in conn.execute(
                "SELECT attribute, value, status FROM memory WHERE value IS NOT NULL"
                " ORDER BY created_at, id"
            ).fetchall()
        ]


def run(url: str, *args: str, judge: Questions | None = None) -> str:
    if "--apply" in args and args[0] == "repair":
        args = (*args, "--as-user", str(USER))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        assert load().main([args[0], "--dsn", url, *args[1:]], judge=judge or Questions()) == 0
    return out.getvalue()


def vocab(url: str) -> list[tuple[str, str, str]]:
    with psycopg.connect(url) as conn:
        return [
            (str(k), str(lb), str(q))
            for k, lb, q in conn.execute(
                "SELECT key, label, question FROM attribute_vocab ORDER BY key"
            ).fetchall()
        ]


@pytest.fixture
def incident(fresh_db: str, pool: Pool) -> str:
    put(pool, "프론트", "스타일 방식", "CSS Modules + CSS 커스텀 프로퍼티", CSS, 1, True)
    put(pool, "프론트", "스타일 방식", "독립 PR", NEXT, 2, True)
    put(pool, "디자인", "스타일 방식", "CSS Modules", CSS, 3, True)
    put(pool, "디자인", "스타일 방식", "Tailwind로 변경", TAILWIND, 4, True)
    put(pool, "백업", "보관 기간", "14일", BACKUP, 5, True)
    put(pool, "백업", "보관 기간", "Figma", GUIDE, 6, False)
    return fresh_db


BEFORE = [
    ("스타일 방식", "css modules + css 커스텀 프로퍼티", "superseded"),
    ("스타일 방식", "독립 pr", "active"),
    ("스타일 방식", "css modules", "superseded"),
    ("스타일 방식", "tailwind로 변경", "active"),
    ("보관 기간", "14일", "active"),
    ("보관 기간", "figma", "challenger"),
]
SUMMARY = "{'restore': 1, 'detach': 1, 'manual': 0, 'unjudged': 0}"


@pytest.mark.db
def test_dry_run_lists_the_rows_that_answer_another_question_and_writes_nothing(
    incident: str,
) -> None:
    assert state(incident) == BEFORE
    out = run(incident, "repair")
    assert [line.split()[0] for line in out.splitlines()[:-1]] == ["restore", "detach"]
    assert out.splitlines()[-1] == f"dry run, nothing written: {SUMMARY}"
    assert state(incident) == BEFORE


@pytest.mark.db
def test_apply_restores_the_live_row_and_gives_the_other_question_its_own_key(
    incident: str,
) -> None:
    assert run(incident, "repair", "--apply").splitlines()[-1] == f"applied: {SUMMARY}"
    after = state(incident)
    assert after[:6] == [
        *BEFORE[:1],
        ("스타일 방식", "독립 pr", "expired"),
        *BEFORE[2:5],
        ("보관 기간", "figma", "rejected"),
    ]
    assert sorted(after[6:]) == sorted(
        [
            ("스타일 방식", "css modules + css 커스텀 프로퍼티", "active"),
            ("next-owner", "독립 pr", "active"),
            ("guide-tool", "figma", "provisional"),
        ]
    )


@pytest.mark.db
def test_a_second_apply_finds_nothing(incident: str) -> None:
    run(incident, "repair", "--apply")
    after = state(incident)
    out = run(incident, "repair", "--apply")
    assert out == "applied: {'restore': 0, 'detach': 0, 'manual': 0, 'unjudged': 0}\n"
    assert state(incident) == after


@pytest.mark.db
def test_only_limits_the_apply_to_the_reviewed_ids(incident: str) -> None:
    with psycopg.connect(incident) as conn:
        (rid,) = conn.execute("SELECT id FROM memory WHERE value = 'figma'").fetchone()  # type: ignore[misc]
    out = run(incident, "repair", "--apply", "--only", str(rid))
    assert (
        out.splitlines()[-1] == "applied: {'restore': 0, 'detach': 1, 'manual': 0, 'unjudged': 0}"
    )
    assert ("스타일 방식", "독립 pr", "active") in state(incident)


@pytest.mark.db
def test_a_pair_the_judge_cannot_describe_is_listed_and_never_applied(incident: str) -> None:
    out = run(incident, "repair", "--apply", judge=Questions(blind=True))
    assert out.count("(unjudged: needs a judge answer)") == 3
    assert out.splitlines()[-1] == (
        "applied: {'restore': 0, 'detach': 0, 'manual': 0, 'unjudged': 3}"
    )
    assert state(incident) == BEFORE


@pytest.mark.db
def test_rows_older_than_the_window_are_left_alone(incident: str) -> None:
    out = run(incident, "repair", "--days", "0")
    assert out == (
        "dry run, nothing written: {'restore': 0, 'detach': 0, 'manual': 0, 'unjudged': 0}\n"
    )


def test_apply_needs_a_judge_and_repair_an_acting_principal(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    assert load().main(["backfill", "--dsn", "postgresql://unused", "--apply"]) == 2
    with pytest.raises(SystemExit):
        load().main(["repair", "--dsn", "postgresql://unused", "--apply"], judge=Questions())


@pytest.mark.db
def test_backfill_dry_run_lists_every_attribute_without_an_entry_and_writes_nothing(
    incident: str,
) -> None:
    out = run(incident, "backfill")
    assert out.splitlines()[-1] == "dry run, nothing written: {'entries': 3, 'unjudged': 0}"
    assert vocab(incident) == []


@pytest.mark.db
def test_backfill_registers_the_questions_and_a_second_run_finds_nothing(incident: str) -> None:
    run(incident, "repair", "--apply")
    assert run(incident, "backfill", "--apply").splitlines()[-1] == (
        "applied: {'entries': 5, 'unjudged': 0}"
    )
    assert sorted(vocab(incident)) == sorted(
        [
            ("guide-tool", "가이드 도구", "스타일 가이드는 어디에?"),
            ("next-owner", "next 담당", "?next= 처리는 누가?"),
            ("스타일 방식", "스타일링", "프론트 스타일링 방식은?"),
            ("스타일 방식", "스타일링", "프론트 스타일링 방식은?"),
            ("보관 기간", "보관 기간", "백업 보관 기간은?"),
        ]
    )
    assert run(incident, "backfill", "--apply").splitlines()[-1] == (
        "applied: {'entries': 0, 'unjudged': 0}"
    )


@pytest.mark.db
def test_backfill_renames_a_sentence_attribute_on_all_its_rows(fresh_db: str, pool: Pool) -> None:
    put(pool, "프론트", SENTENCE.casefold(), "독립 PR", NEXT, 1, True)
    put(pool, "프론트", SENTENCE.casefold(), "별도 PR", NEXT, 2, True)
    run(fresh_db, "backfill", "--apply")
    assert [(a, s) for a, _v, s in state(fresh_db)] == [
        ("next-owner", "superseded"),
        ("next-owner", "active"),
    ]
    assert vocab(fresh_db) == [("next-owner", "next 담당", "?next= 처리는 누가?")]


@pytest.mark.db
def test_backfill_without_a_description_lists_the_entry_unjudged_and_skips_it(
    incident: str,
) -> None:
    out = run(incident, "backfill", "--apply", judge=Questions(blind=True))
    assert out.splitlines()[-1] == "applied: {'entries': 3, 'unjudged': 3}"
    assert vocab(incident) == []
