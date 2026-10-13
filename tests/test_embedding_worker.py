import uuid

import psycopg
import pytest

from nunchi.db import Pool
from nunchi.worker.__main__ import main
from nunchi.worker.embedding import embed_missing
from tests.conftest import STORE, TENANT, USER
from tests.embed_fake import DownEmbedder, FakeEmbedder
from tests.test_repo import HIDDEN
from tests.test_repo import world as world  # noqa: PLC0414 - fixture re-export

CONCEPTS = {"A사": 0, "에이사": 0, "담당": 1, "서버": 2}
FIRST = uuid.UUID("00000000-0000-0000-0000-0000000000f1")
SECOND = uuid.UUID("00000000-0000-0000-0000-0000000000f2")


@pytest.fixture
def embedded(world: Pool, fresh_db: str) -> FakeEmbedder:
    """Two memories in STORE and the hidden-store memory, all embedded by the worker job."""
    with psycopg.connect(fresh_db) as conn:
        for mid, title, body in (
            (FIRST, "A사 담당자는 이OO", "A사 계약 담당"),
            (SECOND, "배포 서버 점검 주기", "서버 점검은 매주"),
        ):
            conn.execute(
                "INSERT INTO memory"
                " (id, tenant_id, store_id, kind, status, title, body, created_by)"
                " VALUES (%s, %s, %s, 'note', 'active', %s, %s, %s)",
                (mid, TENANT, STORE, title, body, USER),
            )
        conn.execute(
            "UPDATE memory SET title = 'A사 서버 비밀', body = '' WHERE id = %s", (HIDDEN,)
        )
        embedder = FakeEmbedder(CONCEPTS)
        while embed_missing(conn, embedder, batch=2):
            pass
    return embedder


@pytest.mark.db
def test_worker_job_uses_document_prompts_and_is_idempotent(
    world: Pool, embedded: FakeEmbedder, fresh_db: str
) -> None:
    assert {prompt for prompt, _ in embedded.calls} == {"document"}
    with psycopg.connect(fresh_db) as conn:
        assert embed_missing(conn, embedded) == 0
        assert embed_missing(conn, FakeEmbedder(CONCEPTS, model="fake-2")) == 5
        assert conn.execute("SELECT count(*), min(model) FROM memory_embedding").fetchone() == (
            5,
            "fake-2",
        )


@pytest.mark.db
def test_cli_embeds_after_the_freshness_pass(
    world: Pool,
    embedded: FakeEmbedder,
    fresh_db: str,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    with psycopg.connect(fresh_db) as conn:
        conn.execute("UPDATE memory SET body = '새 본문' WHERE id = %s", (FIRST,))
    monkeypatch.setenv("NUNCHI_DATABASE_URL", fresh_db)
    monkeypatch.setattr("nunchi.worker.__main__.embedder_from_settings", lambda s: embedded)
    assert main(["--once"]) == 0
    assert capsys.readouterr().out == "worker: expired 0, stale 0\nworker: embedded 1\n"
    monkeypatch.setattr("nunchi.worker.__main__.embedder_from_settings", lambda s: DownEmbedder())
    with psycopg.connect(fresh_db) as conn:
        conn.execute("UPDATE memory SET body = '또 바뀜' WHERE id = %s", (FIRST,))
    assert main(["--once"]) == 0
    assert capsys.readouterr().out == (
        "worker: expired 0, stale 0\nworker: embedded 0, stopped: service is down\n"
    )
