import contextlib
import importlib.util
import io
import json
import sys
from types import ModuleType

import psycopg
import pytest

from nunchi.db import Pool, request_tx
from tests.conftest import REPO, STORE, USER

SCRIPT = REPO / "scripts" / "repair-u40.py"
CSS = "프론트 스타일링 방식으로 CSS Modules + CSS 커스텀 프로퍼티 채택"
NEXT = "프론트 ?next= 처리는 PR #21과 병행하지 않고 독립 PR로 진행"
TAILWIND = "프론트 스타일링을 Tailwind로 변경"
BACKUP = "백업은 14일 보관"
GUIDE = "스타일 가이드는 Figma로 공유"


class TopicJudge:
    def same(self, first: str, second: str, first_title: str = "", second_title: str = "") -> bool:
        return False

    def same_topic(
        self, first: str, second: str, first_title: str = "", second_title: str = ""
    ) -> bool:
        styling = ("스타일", "tailwind")
        return any(k in first_title for k in styling) == any(k in second_title for k in styling)


def load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("repair_u40", SCRIPT)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["repair_u40"] = module
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


def run(url: str, *args: str) -> str:
    if "--apply" in args:
        args = (*args, "--as-user", str(USER))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        assert load().main(["--dsn", url, *args], judge=TopicJudge()) == 0
    return out.getvalue()


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


@pytest.mark.db
def test_dry_run_lists_the_other_topic_rows_and_writes_nothing(incident: str) -> None:
    assert state(incident) == BEFORE
    out = run(incident)
    assert [line.split()[0] for line in out.splitlines()[:-1]] == ["restore", "detach"]
    assert (
        out.splitlines()[-1] == "dry run, nothing written: {'restore': 1, 'detach': 1, 'manual': 0}"
    )
    assert state(incident) == BEFORE


@pytest.mark.db
def test_apply_restores_the_live_row_and_gives_the_other_topic_its_own_key(incident: str) -> None:
    out = run(incident, "--apply")
    assert out.splitlines()[-1] == "applied: {'restore': 1, 'detach': 1, 'manual': 0}"
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
            (NEXT.casefold(), "독립 pr", "active"),
            (GUIDE.casefold(), "figma", "provisional"),
        ]
    )


@pytest.mark.db
def test_a_second_apply_finds_nothing(incident: str) -> None:
    run(incident, "--apply")
    after = state(incident)
    assert run(incident, "--apply") == "applied: {'restore': 0, 'detach': 0, 'manual': 0}\n"
    assert state(incident) == after


@pytest.mark.db
def test_rows_older_than_the_window_are_left_alone(incident: str) -> None:
    assert (
        run(incident, "--days", "0")
        == "dry run, nothing written: {'restore': 0, 'detach': 0, 'manual': 0}\n"
    )


def test_apply_needs_a_judge_and_an_acting_principal(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    assert load().main(["--dsn", "postgresql://unused", "--apply", "--as-user", str(USER)]) == 2
    with pytest.raises(SystemExit):
        load().main(["--dsn", "postgresql://unused", "--apply"], judge=TopicJudge())


def pair(**over: object) -> dict[str, object]:
    return {
        "rid": "r", "oid": "o", "attribute": "k", "rstatus": "active", "rvalue": "독립 PR",
        "rtitle": NEXT, "ovalue": "CSS Modules", "otitle": CSS, "blocked": False, **over,
    }  # fmt: skip


def test_dry_run_without_a_judge_lists_candidates_unjudged() -> None:
    plan = load().build_plan([pair()], None)
    assert [(a.kind, a.judged) for a in plan] == [("restore", False)]
    assert "(unjudged: needs ANTHROPIC_API_KEY)" in plan[0].line()


def test_a_row_with_its_own_challenger_is_left_to_a_person() -> None:
    plan = load().build_plan([pair(blocked=True)], TopicJudge())
    assert [a.kind for a in plan] == ["manual"]
