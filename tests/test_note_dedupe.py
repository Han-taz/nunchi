import psycopg
import pytest

from nunchi.db import Pool, request_tx
from nunchi.domain import repo
from nunchi.domain.models import MemoryKind, ProposeOutcome, ProposeRequest
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


def note(pool: Pool, title: str, body: str) -> ProposeOutcome:
    with request_tx(pool, USER, None) as conn:
        return repo.remember(
            conn, ProposeRequest(store_id=STORE, kind=MemoryKind.NOTE, title=title, body=body)
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
