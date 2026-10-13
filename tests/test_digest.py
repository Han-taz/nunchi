import json
import uuid
from datetime import date
from typing import Any

import httpx
import psycopg
import pytest

from nunchi.db import Pool
from nunchi.domain.models import MemoryKind, MemoryOrigin
from nunchi.extract import ExtractContext, ExtractionError, FailureReason, ProposalDraft
from nunchi.extract.claude import SYSTEM_PROMPT, render_user_content
from nunchi.mattermost.client import Mattermost
from nunchi.mattermost.digest import Digest, DigestLimits, DigestReport, run_digest
from nunchi.worker import __main__ as worker
from tests.conftest import STORE, TENANT, USER

CUR = uuid.UUID("00000000-0000-0000-0000-0000000000a3")
TEAM = "t" * 26
BOT = "b" * 26
ROOM = "c" * 26
DM = "d" * 26
OFF = "f" * 26
ALICE = "a" * 26
BOB = "o" * 26
T0 = 1_700_000_000_000
MIN = 60_000

CHANNELS = {
    ROOM: {"type": "O", "team_id": TEAM},
    OFF: {"type": "P", "team_id": TEAM},
    DM: {"type": "D", "team_id": ""},
}


def post(n: int, at: int, message: str, user: str = ALICE, root: str = "") -> dict[str, Any]:
    pid = f"{n:026d}"
    return {
        "id": pid,
        "channel_id": ROOM,
        "message": message,
        "user_id": user,
        "root_id": f"{root:>026}".replace(" ", "0") if root else "",
        "create_at": T0 + at * MIN,
        "type": "",
        "delete_at": 0,
    }


class FakeMattermost:
    def __init__(self) -> None:
        self.posts: list[dict[str, Any]] = []
        self.requested: list[str] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:  # noqa: PLR0911
        path = request.url.path.removeprefix("/api/v4")
        self.requested.append(path)
        query = request.url.params
        if path.startswith("/channels/") and path.endswith("/posts"):
            channel = path.split("/")[2]
            since, page, per = int(query["since"]), int(query["page"]), int(query["per_page"])
            rows = [p for p in self.posts if p["channel_id"] == channel and p["create_at"] > since]
            rows.sort(key=lambda p: -p["create_at"])
            rows = rows[page * per : (page + 1) * per]
            return httpx.Response(
                200, json={"order": [p["id"] for p in rows], "posts": {p["id"]: p for p in rows}}
            )
        if path.startswith("/channels/") and path.split("/")[2] not in CHANNELS:
            return httpx.Response(404, json={})
        if path.startswith("/channels/"):
            return httpx.Response(
                200, json={"id": path.split("/")[2]} | CHANNELS[path.split("/")[2]]
            )
        if path.startswith("/posts/") and path.endswith("/thread"):
            root = path.split("/")[2]
            rows = [p for p in self.posts if root in (p["id"], p["root_id"])]
            return httpx.Response(200, json={"order": [], "posts": {p["id"]: p for p in rows}})
        if path == "/users/ids":
            names = {ALICE: "minji.kim", BOB: "junho.park"}
            return httpx.Response(
                200, json=[{"id": i, "username": names[i]} for i in json.loads(request.content)]
            )
        if path == "/users/me":
            return httpx.Response(200, json={"id": BOT, "username": "nunchi"})
        if path == f"/teams/{TEAM}":
            return httpx.Response(200, json={"name": "devshow"})
        return httpx.Response(404, json={})


class WindowExtractor:
    """Reads a window the way a model would: the last agreed line decides."""

    def __init__(self) -> None:
        self.seen: list[tuple[str, ExtractContext]] = []
        self.fail = False

    def extract(self, source_text: str, context: ExtractContext) -> ProposalDraft | None:
        self.seen.append((source_text, context))
        if self.fail:
            raise ExtractionError(FailureReason.API, "down")
        value = next(
            (v for v in ("금지", "허용") if f"금요일 배포 {v}로 합의" in source_text), None
        )
        if value is None:
            return None
        return ProposalDraft(
            kind=MemoryKind.DECISION,
            title=f"금요일 배포 {value}",
            body=source_text,
            subject_name="배포",
            attribute="금요일 배포",
            value=value,
            source_refs=context.source_refs,
            origin=context.origin,
        )


World = tuple[Digest, FakeMattermost, WindowExtractor, str]


def bind(conn: psycopg.Connection[Any], channel: str, kind: str, digest: bool) -> None:
    conn.execute(
        "INSERT INTO room_member (tenant_id, platform, workspace_id, channel_id, platform_user_id)"
        " VALUES (%s, 'mattermost', %s, %s, %s)",
        (TENANT, TEAM, channel, ALICE),
    )
    conn.execute(
        "INSERT INTO room_binding (tenant_id, platform, workspace_id, channel_id, kind, store_id,"
        " bound_by, confirmed_by, confirmed_at, digest_enabled)"
        " VALUES (%s, 'mattermost', %s, %s, %s, %s, %s, %s, now(), %s)",
        (TENANT, TEAM, channel, kind, STORE, USER, CUR, digest),
    )


@pytest.fixture
def world(fresh_db: str, pool: Pool) -> World:
    with psycopg.connect(fresh_db) as conn:
        conn.execute(
            "INSERT INTO principal (id, tenant_id, kind, external_id, display_name)"
            " VALUES (%s, %s, 'user', 'c', 'x')",
            (CUR, TENANT),
        )
        conn.execute(
            "INSERT INTO store_grant (store_id, principal_id, role, tenant_id)"
            " VALUES (%s, %s, 'curator', %s)",
            (STORE, CUR, TENANT),
        )
        conn.execute(
            "INSERT INTO principal_identity (platform, platform_user_id, tenant_id, principal_id,"
            " link_quality) VALUES ('mattermost', %s, %s, %s, 'scim')",
            (BOT, TENANT, USER),
        )
        bind(conn, ROOM, "public", True)
        bind(conn, OFF, "private", False)
        bind(conn, DM, "private", True)  # a DM id bound by mistake must still never be read
    fake = FakeMattermost()
    client = Mattermost("http://mm", "tok", "https://mm.example", httpx.MockTransport(fake))
    extractor = WindowExtractor()
    return Digest(pool, client, extractor, TENANT, BOT), fake, extractor, fresh_db


def rows(url: str) -> list[tuple[Any, ...]]:
    with psycopg.connect(url) as conn:
        return conn.execute(
            "SELECT title, status, conflict_with IS NOT NULL FROM memory WHERE title <> 'hello'"
            " ORDER BY created_at"
        ).fetchall()


def cursor(url: str, channel: str = ROOM) -> int:
    with psycopg.connect(url) as conn:
        row = conn.execute(
            "SELECT digest_cursor FROM room_binding WHERE channel_id = %s", (channel,)
        ).fetchone()
    assert row is not None
    return int(row[0])


def approve(url: str) -> None:
    """Stands in for the curator's approval: the first decision becomes the live row."""
    with psycopg.connect(url, autocommit=True) as conn:
        conn.execute("SET session_replication_role = replica")
        conn.execute("UPDATE memory SET status = 'active' WHERE title = '금요일 배포 금지'")


DECISION = [
    post(1, 0, "금요일 배포 어떻게 할까요?"),
    post(2, 1, "저는 허용 쪽이요", BOB),
    post(3, 3, "그래도 위험해요. 금요일 배포 금지로 합의합시다", ALICE),
    post(4, 4, "좋아요 금요일 배포 금지로 합의", BOB),
]


@pytest.mark.db
def test_a_window_with_a_decision_creates_one_memory_and_a_rerun_creates_none(world: World) -> None:
    digest, fake, extractor, url = world
    fake.posts = list(DECISION)

    report = run_digest(digest)

    assert report == DigestReport(windows=1, created=1)
    assert rows(url) == [("금요일 배포 금지", "proposed", False)]
    text, context = extractor.seen[0]
    assert text.splitlines()[0] == "minji.kim: 금요일 배포 어떻게 할까요?"
    assert len(text.splitlines()) == 4
    assert context.window is True
    assert [r.uri for r in context.source_refs] == [
        f"https://mm.example/devshow/pl/{n:026d}" for n in (1, 2, 3, 4)
    ]
    assert context.source_refs[0].speakers == ("junho.park", "minji.kim")
    assert cursor(url) == T0 + 4 * MIN
    assert run_digest(digest) == DigestReport()

    with psycopg.connect(url) as conn:  # even a lost cursor cannot double-capture a window
        conn.execute("UPDATE room_binding SET digest_cursor = 0 WHERE channel_id = %s", (ROOM,))
    assert run_digest(digest) == DigestReport()
    assert (len(extractor.seen), len(rows(url))) == (1, 1)


@pytest.mark.db
def test_a_chit_chat_window_creates_nothing_but_the_cursor_moves(world: World) -> None:
    digest, fake, _, url = world
    fake.posts = [post(1, 0, "점심 뭐 드실래요?"), post(2, 1, "김치찌개요", BOB)]

    report = run_digest(digest)

    assert report == DigestReport(windows=1, stored_nothing=1)
    assert rows(url) == []
    assert cursor(url) == T0 + 1 * MIN


@pytest.mark.db
def test_a_later_window_reversing_the_decision_is_an_update_conflict(world: World) -> None:
    digest, fake, _, url = world
    fake.posts = list(DECISION)
    run_digest(digest)
    approve(url)
    fake.posts += [
        post(5, 120, "지난번 결정 다시 보죠"),
        post(6, 121, "이제 안정돼서 금요일 배포 허용로 합의했어요", BOB),
    ]

    report = run_digest(digest)

    assert report == DigestReport(windows=1, created=1, conflicts=1)
    assert rows(url) == [
        ("금요일 배포 금지", "active", False),
        ("금요일 배포 허용", "proposed", True),
    ]


@pytest.mark.db
def test_a_thread_is_one_window_and_loose_posts_split_at_15_minutes(world: World) -> None:
    digest, fake, extractor, url = world
    fake.posts = [
        post(1, 0, "루트: 배포 규칙 논의"),
        post(2, 300, "답글 하나", BOB, root="1"),
        post(3, 301, "금요일 배포 금지로 합의", ALICE, root="1"),
        post(4, 10, "따로 한마디"),
        post(5, 20, "열 분 뒤 한마디"),
        post(6, 40, "한참 뒤 한마디"),
    ]

    report = run_digest(digest)

    texts = [t for t, _ in extractor.seen]
    assert report.windows == 3
    assert sorted(len(t.splitlines()) for t in texts) == [1, 2, 3]
    assert next(t for t in texts if "루트" in t).splitlines() == [
        "minji.kim: 루트: 배포 규칙 논의",
        "junho.park: 답글 하나",
        "minji.kim: 금요일 배포 금지로 합의",
    ]
    assert len(rows(url)) == 1


@pytest.mark.db
def test_dm_and_unswitched_channels_are_never_read(world: World) -> None:
    digest, fake, _, _ = world
    fake.posts = list(DECISION)

    run_digest(digest)

    assert sorted({p for p in fake.requested if p.endswith("/posts")}) == [
        f"/channels/{ROOM}/posts"
    ]
    assert f"/channels/{DM}" in fake.requested
    assert f"/channels/{DM}/posts" not in fake.requested
    assert f"/channels/{OFF}" not in fake.requested


@pytest.mark.db
def test_the_window_cap_defers_the_rest_without_losing_it(world: World) -> None:
    digest, fake, extractor, url = world
    fake.posts = [post(1, 0, "첫째 잡담"), post(2, 60, "둘째 잡담"), post(3, 120, "셋째 잡담")]
    capped = Digest(
        digest.pool, digest.client, extractor, TENANT, BOT, limits=DigestLimits(max_windows=1)
    )

    assert run_digest(capped) == DigestReport(windows=1, stored_nothing=1, deferred=2)
    assert cursor(url) == T0 + 60 * MIN - 1
    assert run_digest(capped) == DigestReport(windows=1, stored_nothing=1, deferred=1)
    assert run_digest(capped) == DigestReport(windows=1, stored_nothing=1)
    assert [t for t, _ in extractor.seen] == [
        "minji.kim: 첫째 잡담",
        "minji.kim: 둘째 잡담",
        "minji.kim: 셋째 잡담",
    ]


@pytest.mark.db
def test_an_extraction_failure_keeps_the_cursor_and_the_retry_succeeds(world: World) -> None:
    digest, fake, extractor, url = world
    fake.posts = list(DECISION)
    extractor.fail = True

    failed = run_digest(digest)

    assert failed == DigestReport(failed=1)
    assert cursor(url) == T0 - 1
    assert rows(url) == []
    assert run_digest(digest) == DigestReport(failed=1)
    assert cursor(url) == T0 - 1
    extractor.fail = False
    assert run_digest(digest) == DigestReport(windows=1, created=1)


@pytest.mark.db
def test_the_bot_and_system_posts_are_not_part_of_a_window(world: World) -> None:
    digest, fake, extractor, _ = world
    fake.posts = [
        post(1, 0, "봇이 한 말", BOT),
        post(2, 1, "joined the channel") | {"type": "system_join_channel"},
        post(3, 2, "지운 글") | {"delete_at": T0},
        post(4, 3, "사람이 한 말"),
    ]

    run_digest(digest)

    assert [t for t, _ in extractor.seen] == ["minji.kim: 사람이 한 말"]


def test_the_client_pages_until_a_page_is_short() -> None:
    fake = FakeMattermost()
    fake.posts = [post(n, n, f"m{n}") for n in range(1, 6)]
    client = Mattermost("http://mm", "tok", "https://mm.example", httpx.MockTransport(fake))

    got = [p["id"] for p in client.channel_posts(ROOM, 0, per_page=2)]

    assert got == [f"{n:026d}" for n in (5, 4, 3, 2, 1)]
    assert [q for q in fake.requested] == [f"/channels/{ROOM}/posts"] * 3


def test_the_window_instruction_reaches_the_extractor_prompt() -> None:
    context = ExtractContext(
        origin=MemoryOrigin.INTERNAL,
        today=date(2026, 1, 1),
        store_id=STORE,
        window=True,
    )
    assert "source: conversation window" in render_user_content("a: b", context)
    assert (
        "A conversation window may contain zero, one or several durable items; decisions only"
        " when the group agreed; ignore debate before agreement." in SYSTEM_PROMPT
    )


@pytest.mark.db
def test_worker_digest_flag_runs_the_digest_every_period(
    world: World, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    digest, fake, extractor, url = world
    fake.posts = list(DECISION)
    monkeypatch.setenv("NUNCHI_DATABASE_URL", url)
    monkeypatch.setenv("MM_BOT_TOKEN", "tok")
    monkeypatch.setenv("MM_ACTION_SECRET", "s3cret")
    monkeypatch.setenv("NUNCHI_TENANT_ID", str(TENANT))
    monkeypatch.setattr(worker, "Mattermost", lambda *_a: digest.client)
    monkeypatch.setattr(worker, "open_pool", lambda _s: digest.pool)
    monkeypatch.setattr(worker, "build_extractor", lambda: extractor)
    sleeps: list[float] = []

    def stop(seconds: float) -> None:
        sleeps.append(seconds)
        raise KeyboardInterrupt

    monkeypatch.setattr("nunchi.worker.__main__.time.sleep", stop)
    with pytest.raises(KeyboardInterrupt):
        worker.main(["--digest", "--every", "600", "--digest-max-windows", "5"])
    first = capsys.readouterr().out
    assert worker.main(["--digest", "--once"]) == 0

    assert sleeps == [600.0]
    assert first == f"digest: {DigestReport(windows=1, created=1)}\n"
    assert capsys.readouterr().out == f"digest: {DigestReport()}\n"


@pytest.mark.db
def test_an_unreadable_channel_is_counted_and_does_not_stop_the_run(world: World) -> None:
    digest, fake, _, url = world
    fake.posts = list(DECISION)
    with psycopg.connect(url) as conn:
        bind(conn, "e" * 26, "public", True)  # the server answers 404 for this channel

    assert run_digest(digest) == DigestReport(windows=1, created=1, failed=1)


@pytest.mark.db
def test_an_unlinked_bot_reads_nothing(world: World) -> None:
    digest, fake, extractor, _ = world
    fake.posts = list(DECISION)
    stranger = Digest(digest.pool, digest.client, extractor, TENANT, "z" * 26)

    assert run_digest(stranger) == DigestReport()
    assert fake.requested == []


@pytest.mark.db
def test_a_later_window_restating_the_live_decision_only_reconfirms_it(world: World) -> None:
    digest, fake, _, url = world
    fake.posts = list(DECISION)
    run_digest(digest)
    approve(url)
    fake.posts.append(post(7, 200, "다시 확인: 금요일 배포 금지로 합의"))

    assert run_digest(digest) == DigestReport(windows=1, stored_nothing=1)
    assert len(rows(url)) == 1
