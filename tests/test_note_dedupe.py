from datetime import UTC, datetime

import psycopg
import pytest

from nunchi.db import Pool, request_tx
from nunchi.domain import repo
from nunchi.domain.models import Evidence, MemoryKind, ProposeOutcome, ProposeRequest
from tests.conftest import STORE, USER

TITLE = "M1 백엔드 뼈대 작업 현황 (junho.park)"
FIRST = (
    "M1 착수 제안 보고 후 목요일까지 백엔드 뼈대를 구현함: FastAPI 앱 구조, PostgreSQL User 모델, "
    "Mattermost OAuth 2.0 인증 라우터(/auth/mattermost/*), JWT 토큰 서비스, CI 워크플로우"
    "(.github/workflows/ci.yml), docker-compose.yml(db, backend, frontend). ruff lint와 pytest "
    "2개 통과 확인. docker-compose로 3개 서비스 실행은 서연과 함께 진행 예정. 브랜치는 git push "
    "인증 오류로 아직 원격에 올라가지 않았으며 junho.park가 해결 예정."
)
SECOND = (
    "M1 착수 제안 보고 후 목요일까지 백엔드 뼈대를 구현함: FastAPI 앱 구조, PostgreSQL User 모델, "
    "Mattermost OAuth 2.0 인증 라우터, JWT 토큰 서비스, CI 워크플로우, docker-compose.yml. "
    "ruff lint와 pytest 2개 통과. docker-compose 3개 서비스 실행은 서연과 함께 진행 예정. "
    "브랜치는 git push 인증 오류로 아직 원격에 올라가지 않음."
)


def note(pool: Pool, title: str, body: str, evidence: tuple[Evidence, ...] = ()) -> ProposeOutcome:
    with request_tx(pool, USER, None) as conn:
        return repo.remember(
            conn,
            ProposeRequest(store_id=STORE, kind=MemoryKind.NOTE, title=title, body=body),
            "stated",
            evidence,
        )


def said(n: int, author: str) -> Evidence:
    return Evidence(
        uri=f"https://mm.example/devshow/pl/{n}",
        post_id=f"post-{n}",
        author=author,
        author_name=f"name-{author}",
        said_at=datetime(2026, 10, 14, 9, n, tzinfo=UTC),
    )


def titled(url: str, title: str) -> list[str]:
    with psycopg.connect(url) as conn:
        return [r[0] for r in conn.execute("SELECT body FROM memory WHERE title = %s", (title,))]


@pytest.mark.db
def test_the_same_progress_note_stored_ten_minutes_apart_is_one_row_reconfirmed(
    pool: Pool, seeded: str, fresh_db: str
) -> None:
    first = note(pool, TITLE, FIRST)
    second = note(pool, TITLE, SECOND)

    assert (first.kind, second.kind) == ("created", "reconfirmed")
    assert second.memory_id == first.memory_id
    assert titled(fresh_db, TITLE) == [FIRST]
    with psycopg.connect(fresh_db) as conn:
        ops = conn.execute(
            "SELECT op FROM memory_version WHERE memory_id = %s ORDER BY id", (first.memory_id,)
        ).fetchall()
    assert [op for (op,) in ops] == ["propose", "reconfirm"]


@pytest.mark.db
def test_a_note_with_the_same_title_but_another_body_is_a_new_note(
    pool: Pool, fresh_db: str
) -> None:
    note(pool, TITLE, FIRST)

    other = note(pool, TITLE, "오늘은 장애 대응 회고를 진행하고 알림 임계값을 조정하기로 했다.")

    assert other.kind == "created"
    assert len(titled(fresh_db, TITLE)) == 2


@pytest.mark.db
def test_a_note_last_confirmed_over_fourteen_days_ago_is_not_absorbed(
    pool: Pool, fresh_db: str
) -> None:
    first = note(pool, TITLE, FIRST)
    with psycopg.connect(fresh_db) as conn:
        conn.execute("SET session_replication_role = replica")
        conn.execute(
            "UPDATE memory SET last_confirmed_at = now() - interval '15 days' WHERE id = %s",
            (first.memory_id,),
        )

    again = note(pool, TITLE, SECOND)

    assert again.kind == "created"
    assert again.memory_id != first.memory_id


@pytest.mark.db
def test_reconfirming_a_duplicate_note_records_each_new_post_once(
    pool: Pool, fresh_db: str
) -> None:
    first = note(pool, TITLE, FIRST, (said(1, "u1"),))
    note(pool, TITLE, SECOND, (said(2, "u2"),))
    note(pool, TITLE, SECOND, (said(2, "u2"),))

    with psycopg.connect(fresh_db) as conn:
        rows = conn.execute(
            "SELECT op, post_id, author, author_name, basis FROM memory_evidence"
            " WHERE memory_id = %s ORDER BY id",
            (first.memory_id,),
        ).fetchall()
        chain = conn.execute("SELECT app_sec.verify_chain(%s)", (first.memory_id,)).fetchone()
    assert rows == [
        ("propose", "post-1", "u1", "name-u1", "stated"),
        ("reconfirm", "post-2", "u2", "name-u2", "stated"),
    ]
    assert chain == (True,)
