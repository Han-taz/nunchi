import contextlib
import importlib.util
import io
import sys
from types import ModuleType

import psycopg
import pytest

from nunchi.db import Pool, request_tx
from tests.conftest import REPO, STORE, USER

SCRIPT = REPO / "scripts" / "cleanup-u39.py"
SAME_PAIRS = ({"제거", "제외"}, {"제거", "v1.0에서 제거"}, {"제외", "v1.0에서 제거"})


class PairJudge:
    """Same only for the listed value pairs: a stand-in for the model."""

    def same(self, first: str, second: str, first_title: str = "", second_title: str = "") -> bool:
        return {first, second} in SAME_PAIRS


def load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("cleanup_u39", SCRIPT)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["cleanup_u39"] = module
    spec.loader.exec_module(module)
    return module


def put(  # noqa: PLR0913, PLR0917 - one stored message
    pool: Pool, subject: str, attribute: str, value: str, title: str, n: int
) -> None:
    """One message stored by the old pipeline: no judge, so a paraphrase became a challenger."""
    with request_tx(pool, USER, None) as conn:
        entity = conn.execute("SELECT app_sec.resolve_entity(%s)", (subject,)).fetchone()
        assert entity is not None
        subject_id = (
            entity[0]
            or conn.execute("SELECT app_sec.create_entity(%s, 'subject')", (subject,)).fetchone()[0]  # type: ignore[index]
        )
        conn.execute(
            "SELECT app_sec.remember(%s, 'decision', %s, %s, %s::jsonb, %s, %s, %s, '{}'::jsonb,"
            " 'stated', %s::jsonb)",
            (
                STORE,
                title,
                title,
                f'[{{"uri": "https://mm.example/p/{n}", "system": "mattermost"}}]',
                subject_id,
                attribute,
                value,
                f'[{{"uri": "https://mm.example/p/{n}", "post_id": "p{n}"}}]',
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


def evidence_ops(url: str, value: str) -> list[str]:
    with psycopg.connect(url) as conn:
        return [
            str(r[0])
            for r in conn.execute(
                "SELECT e.op FROM memory_evidence e JOIN memory m ON m.id = e.memory_id"
                " WHERE m.value = %s AND m.status = 'provisional' ORDER BY e.id",
                (value,),
            ).fetchall()
        ]


MESSAGES = (
    ("Cloudflare beacon", "v1.0 포함 여부", "제거", "Cloudflare beacon은 v1.0에서 제거"),
    ("Cloudflare beacon", "v1.0 포함 여부", "제외", "Cloudflare beacon은 v1.0 범위에서 제외"),
    ("frontend page.tsx", "cloudflare beacon", "v1.0에서 제거", "v1.0에서 beacon 스크립트 제거"),
    (
        "login page",
        "oauth url",
        "/auth/authorize",
        "로그인 OAuth URL을 /auth/authorize로 수정 필요",
    ),
    ("백엔드 로그아웃", "구현 상태", "구현 완료", "백엔드 로그아웃 엔드포인트 구현 완료"),
    ("F2 팀 정보", "조회 방식", "Mattermost API로 조회", "F2는 Mattermost API로 조회"),
    ("F2 팀 정보", "조회 방식", "User.teams 읽기", "F2는 로그인 시 저장한 User.teams를 읽는다"),
)


@pytest.fixture
def messy(fresh_db: str, pool: Pool) -> str:
    for n, message in enumerate(MESSAGES):
        put(pool, *message, n)
    return fresh_db


def run(url: str, *args: str) -> str:
    if "--apply" in args:
        args = (*args, "--as-user", str(USER))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        assert load().main(["--dsn", url, *args], judge=PairJudge()) == 0
    return out.getvalue()


MESSY = [
    ("v1.0 포함 여부", "제거", "provisional"),
    ("v1.0 포함 여부", "제외", "challenger"),
    ("cloudflare beacon", "v1.0에서 제거", "provisional"),
    ("oauth url", "/auth/authorize", "provisional"),
    ("구현 상태", "구현 완료", "provisional"),
    ("조회 방식", "mattermost api로 조회", "provisional"),
    ("조회 방식", "user.teams 읽기", "challenger"),
]


@pytest.mark.db
def test_dry_run_prints_the_plan_and_writes_nothing(messy: str) -> None:
    out = run(messy)
    assert [line.split()[0] for line in out.splitlines()[:-1]] == [
        "reject",
        "reject",
        "collapse",
        "merge",
    ]
    assert out.splitlines()[-1] == (
        "dry run, nothing written: {'reject': 2, 'collapse': 1, 'merge': 1}"
    )
    assert state(messy) == MESSY


@pytest.mark.db
def test_apply_rejects_collapses_and_merges_then_a_second_run_does_nothing(messy: str) -> None:
    out = run(messy, "--apply")
    assert out.splitlines()[-1] == "applied: {'reject': 2, 'collapse': 1, 'merge': 1}"
    assert state(messy) == [
        ("v1.0 포함 여부", "제거", "provisional"),
        ("v1.0 포함 여부", "제외", "rejected"),
        ("cloudflare beacon", "v1.0에서 제거", "rejected"),
        ("oauth url", "/auth/authorize", "rejected"),
        ("구현 상태", "구현 완료", "rejected"),
        ("조회 방식", "mattermost api로 조회", "provisional"),
        ("조회 방식", "user.teams 읽기", "challenger"),
    ]
    assert evidence_ops(messy, "제거") == ["propose", "reconfirm", "reconfirm"]
    again = run(messy, "--apply")
    assert again == "applied: {'reject': 0, 'collapse': 0, 'merge': 0}\n"


def test_apply_needs_a_judge_and_an_acting_principal(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    assert load().main(["--dsn", "postgresql://unused", "--apply", "--as-user", str(USER)]) == 2
    with pytest.raises(SystemExit):
        load().main(["--dsn", "postgresql://unused", "--apply"], judge=PairJudge())


def test_dry_run_without_a_judge_lists_pairs_unjudged() -> None:
    module = load()
    base = {"store_id": 1, "subject_id": 1, "version": 1, "created_at": 0}
    rows = [
        {
            **base,
            "id": "a",
            "status": "provisional",
            "title": "T 제거",
            "value": "제거",
            "attribute": "k",
        },
        {
            **base,
            "id": "b",
            "status": "challenger",
            "title": "T 제외",
            "value": "제외",
            "attribute": "k",
        },
    ]
    plan = module.build_plan(rows, None)
    assert [(a.kind, a.judged) for a in plan] == [("collapse", False)]
