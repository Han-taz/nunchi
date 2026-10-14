import asyncio
import json
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from typing import Any

import httpx
import psycopg
import pytest

from nunchi.capture import Created, Reconfirmed, Rejected, Retracted, Skipped
from nunchi.db import Pool
from nunchi.domain.models import MemoryKind, MemoryStatus
from nunchi.extract import ExtractContext, ExtractionError, FailureReason, ProposalDraft
from nunchi.mattermost import __main__ as mm_main
from nunchi.mattermost.client import Mattermost, room_facts
from nunchi.mattermost.events import Deps, _reply, handle_event
from nunchi.mattermost.ws import listen
from tests.conftest import STORE, TENANT, USER

SECRET_STORE = uuid.UUID("00000000-0000-0000-0000-0000000000d2")

CUR = uuid.UUID("00000000-0000-0000-0000-0000000000a3")
TEAM = "t" * 26
BOT = "b" * 26
PUBLIC = "c" * 26
SHARED = "s" * 26
DIRECT = "d" * 26
REACTOR = "r" * 26
CURATOR = "k" * 26
CONFIDENTIAL = "f" * 26
STRANGER = "x" * 26
TEXT = "배포는 금요일에 하지 않는다"
POSTED_MS = 1_700_000_000_000
NAMES = {REACTOR: "minji.kim", CURATOR: "yuna.choi"}
CHANNELS: dict[str, dict[str, Any]] = {
    PUBLIC: {"type": "O", "team_id": TEAM},
    SHARED: {"type": "O", "team_id": TEAM, "shared": True},
    DIRECT: {"type": "D", "team_id": ""},
    CONFIDENTIAL: {"type": "O", "team_id": TEAM},
    "n" * 26: {"type": "P", "team_id": TEAM},
}


def post(
    post_id: str, channel: str, message: str, root: str = "", user: str = REACTOR
) -> dict[str, Any]:
    return {
        "id": post_id,
        "channel_id": channel,
        "message": message,
        "root_id": root,
        "user_id": user,
        "create_at": POSTED_MS,
    }


POSTS: dict[str, dict[str, Any]] = {
    "p" * 26: post("p" * 26, PUBLIC, TEXT),
    "q" * 26: post("q" * 26, PUBLIC, "스레드 답글", root="p" * 26),
    "u" * 26: post("u" * 26, SHARED, TEXT),
    "v" * 26: post("v" * 26, DIRECT, TEXT),
    "w" * 26: post("w" * 26, "n" * 26, TEXT),
    "m" * 26: post("m" * 26, PUBLIC, "@nunchi 스테이징은 매일 초기화된다"),
    "e" * 26: post("e" * 26, CONFIDENTIAL, TEXT),
    "b" * 26: post("b" * 26, PUBLIC, "봇이 한 말", user=BOT),
}


class FakeServer:
    def __init__(self) -> None:
        self.ephemerals: list[dict[str, Any]] = []
        self.paths: list[str] = []
        self.users_down = False

    def __call__(self, request: httpx.Request) -> httpx.Response:  # noqa: PLR0911
        path = request.url.path.removeprefix("/api/v4")
        self.paths.append(path)
        assert request.headers["Authorization"] == "Bearer tok"
        body: Any = json.loads(request.content) if request.content else None
        if path == "/posts/ephemeral":
            self.ephemerals.append(body)
            return httpx.Response(201, json={})
        if path == "/teams/" + TEAM:
            return httpx.Response(200, json={"name": "devshow"})
        for prefix, table in (("/posts/", POSTS), ("/channels/", CHANNELS)):
            if path.startswith(prefix) and path.removeprefix(prefix) in table:
                return httpx.Response(
                    200, json={"id": path.removeprefix(prefix)} | table[path.removeprefix(prefix)]
                )
        if path == "/users/ids":
            if self.users_down:
                return httpx.Response(500, json={})
            return httpx.Response(
                200, json=[{"id": i, "username": NAMES[i]} for i in body if i in NAMES]
            )
        if path == "/users/me":
            return httpx.Response(500, json={})
        return httpx.Response(404, json={})


class CountingExtractor:
    def __init__(self) -> None:
        self.calls = 0
        self.fail = False
        self.skip = False

    def extract(self, source_text: str, context: ExtractContext) -> tuple[ProposalDraft, ...]:
        self.calls += 1
        if self.fail:
            raise ExtractionError(FailureReason.API, "down")
        if self.skip:
            return ()
        text = source_text.strip()
        draft = ProposalDraft(
            kind=MemoryKind.PROCEDURE,
            title=text.splitlines()[0],
            body=text,
            subject_name="A사",
            attribute=text,
            source_refs=context.source_refs,
            origin=context.origin,
        )
        return (draft,)


World = tuple[Deps, FakeServer, CountingExtractor]


@pytest.fixture
def mm_db(fresh_db: str, pool: Pool) -> Pool:
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
            " link_quality) VALUES ('mattermost', %s, %s, %s, 'scim'),"
            " ('mattermost', %s, %s, %s, 'scim')",
            (REACTOR, TENANT, USER, CURATOR, TENANT, CUR),
        )
        conn.execute(
            "INSERT INTO store (id, tenant_id, kind, slug, description, confidential)"
            " VALUES (%s, %s, 'team', 'secret', 'd', true)",
            (SECRET_STORE, TENANT),
        )
        conn.execute(
            "INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES"
            " (%s, %s, 'curator', %s), (%s, %s, 'contributor', %s)",
            (SECRET_STORE, CUR, TENANT, SECRET_STORE, USER, TENANT),
        )
        conn.execute(
            "INSERT INTO room_member (tenant_id, platform, workspace_id, channel_id,"
            " platform_user_id) VALUES (%s, 'mattermost', %s, %s, %s)",
            (TENANT, TEAM, CONFIDENTIAL, REACTOR),
        )
        conn.execute(
            "INSERT INTO room_binding (tenant_id, platform, workspace_id, channel_id, kind,"
            " store_id, bound_by, confirmed_by, confirmed_at)"
            " VALUES (%s, 'mattermost', %s, %s, 'public', %s, %s, %s, now())",
            (TENANT, TEAM, CONFIDENTIAL, SECRET_STORE, USER, CUR),
        )
        for channel, kind in ((PUBLIC, "public"), (SHARED, "connect")):
            conn.execute(
                "INSERT INTO room_member (tenant_id, platform, workspace_id, channel_id,"
                " platform_user_id) VALUES (%s, 'mattermost', %s, %s, %s)",
                (TENANT, TEAM, channel, REACTOR),
            )
            conn.execute(
                "INSERT INTO room_binding (tenant_id, platform, workspace_id, channel_id, kind,"
                " store_id, bound_by, confirmed_by, confirmed_at)"
                " VALUES (%s, 'mattermost', %s, %s, %s, %s, %s, %s, now())",
                (TENANT, TEAM, channel, kind, STORE, USER, CUR),
            )
    return pool


@pytest.fixture
def world(mm_db: Pool) -> World:
    server = FakeServer()
    client = Mattermost("http://mm", "tok", "https://mm.example/", httpx.MockTransport(server))
    extractor = CountingExtractor()
    return Deps(mm_db, extractor, TENANT, client, BOT, "nunchi"), server, extractor


def reaction(
    post_id: str = "p" * 26, emoji: str = "pushpin", user: str = REACTOR, channel: str = PUBLIC
) -> dict[str, Any]:
    body = {"user_id": user, "post_id": post_id, "emoji_name": emoji}
    data = {"reaction": json.dumps(body)}
    return {"event": "reaction_added", "data": data, "broadcast": {"channel_id": channel}, "seq": 3}


def mention(message: str, root: str = "", user: str = REACTOR) -> dict[str, Any]:
    body = post("m" * 26, PUBLIC, message, root, user)
    return {"event": "posted", "data": {"post": json.dumps(body)}, "broadcast": {}, "seq": 4}


def memories(fresh_db: str) -> list[tuple[Any, ...]]:
    with psycopg.connect(fresh_db) as conn:
        return conn.execute(
            "SELECT title, status, origin, source_refs->0->>'uri', source_refs->0->>'channel_id'"
            " FROM memory WHERE title <> 'hello' ORDER BY created_at"
        ).fetchall()


class FakeSocket:
    def __init__(self, frames: list[dict[str, Any]]) -> None:
        self.sent: list[dict[str, Any]] = []
        self._frames = frames

    async def send(self, message: str, /) -> None:
        self.sent.append(json.loads(message))

    async def __aiter__(self) -> AsyncIterator[str]:
        for frame in self._frames:
            yield json.dumps(frame)


def run_socket(deps: Deps, frames: list[dict[str, Any]]) -> FakeSocket:
    socket = FakeSocket(frames)

    @asynccontextmanager
    async def connect() -> AsyncIterator[FakeSocket]:
        yield socket

    asyncio.run(listen(deps, connect, "tok"))
    return socket


@pytest.mark.db
def test_pushpin_over_the_websocket_captures_once_despite_replay_and_a_broken_frame(
    world: World, fresh_db: str
) -> None:
    deps, server, extractor = world
    broken = {"event": "reaction_added", "data": {}}
    other: list[dict[str, Any]] = [{"status": "OK"}, {"event": "hello", "data": {}}, broken]
    socket = run_socket(deps, [*other, reaction(), reaction() | {"seq": 99}])
    assert socket.sent == [
        {"seq": 1, "action": "authentication_challenge", "data": {"token": "tok"}}
    ]
    assert memories(fresh_db) == [
        (TEXT, "provisional", "internal", f"https://mm.example/devshow/pl/{'p' * 26}", PUBLIC)
    ]
    assert (extractor.calls, len(server.ephemerals)) == (1, 1)


@pytest.mark.db
def test_a_failed_capture_does_not_burn_the_event(world: World, fresh_db: str) -> None:
    deps, server, extractor = world
    extractor.fail = True
    handle_event(deps, reaction())
    extractor.fail = False
    handle_event(deps, reaction())
    assert [e["post"]["message"] for e in server.ephemerals] == [
        "저장 안 함: 내용을 정리하지 못했습니다. 다시 시도해 주세요",
        "저장됨: 기간 안에 이의가 없으면 확정됩니다. 다른 분이 같은 내용을 말하면 바로 확정됩니다",
    ]
    assert len(memories(fresh_db)) == 1


@pytest.mark.db
@pytest.mark.parametrize(
    ("event", "title", "post_id"),
    [
        (reaction("q" * 26), "스레드 답글", "q" * 26),
        (mention("@nunchi 이거 기억해", root="p" * 26), TEXT, "p" * 26),
        (mention("@nunchi 스테이징은 매일 초기화된다"), "스테이징은 매일 초기화된다", "m" * 26),
    ],
)
def test_a_capture_finds_the_right_post_and_strips_the_mention(
    world: World, fresh_db: str, event: dict[str, Any], title: str, post_id: str
) -> None:
    handle_event(world[0], event)
    assert [(m[0], m[3]) for m in memories(fresh_db)] == [
        (title, f"https://mm.example/devshow/pl/{post_id}")
    ]


@pytest.mark.db
@pytest.mark.parametrize(
    "event",
    [
        reaction(emoji="thumbsup"),
        mention("그냥 대화"),
        mention("@nunchi 자기 글", user=BOT),
        mention("@nunchiary 다른 사람"),
    ],
)
def test_events_that_are_not_a_capture_request_do_nothing(
    world: World, fresh_db: str, event: dict[str, Any]
) -> None:
    deps, server, extractor = world
    handle_event(deps, event)
    assert (extractor.calls, server.ephemerals, memories(fresh_db)) == (0, [], [])


@pytest.mark.db
@pytest.mark.parametrize(
    ("post_id", "user", "message"),
    [
        ("p" * 26, STRANGER, "Mattermost 계정이 연결되어 있지 않습니다"),
        ("v" * 26, REACTOR, "이 채널은 기억 저장소에 연결되어 있지 않습니다"),
        ("w" * 26, REACTOR, "이 채널은 기억 저장소에 연결되어 있지 않습니다"),
        ("g" * 26, REACTOR, "원문을 찾지 못했습니다"),
    ],
)
def test_a_capture_that_cannot_proceed_says_why_and_saves_nothing(
    world: World, fresh_db: str, post_id: str, user: str, message: str
) -> None:
    deps, server, extractor = world
    handle_event(deps, reaction(post_id, user=user))
    assert server.ephemerals == [
        {"user_id": user, "post": {"channel_id": PUBLIC, "message": message}}
    ]
    assert (extractor.calls, memories(fresh_db)) == (0, [])


@pytest.mark.db
def test_a_shared_channel_capture_is_external(world: World, fresh_db: str) -> None:
    deps, _, _ = world
    handle_event(deps, reaction("u" * 26))
    assert [(m[1], m[2]) for m in memories(fresh_db)] == [("provisional", "external")]


@pytest.mark.parametrize(
    ("channel", "kind", "origin"),
    [
        ({"type": "O", "team_id": "t"}, "public", "internal"),
        ({"type": "P", "team_id": "t"}, "private", "internal"),
        ({"type": "D"}, None, "internal"),
        ({"type": "G", "team_id": "t"}, None, "internal"),
        ({"type": "O", "team_id": "t", "shared": True}, "connect", "external"),
        ({"type": "D", "shared": True}, None, "external"),
    ],
)
def test_only_open_and_private_channels_are_bindable(
    channel: dict[str, Any], kind: str | None, origin: str
) -> None:
    facts = room_facts(channel)
    assert (facts.kind, facts.origin.value) == (kind, origin)


@pytest.mark.db
@pytest.mark.parametrize(
    ("platform", "channel_id", "accepted"),
    [
        ("mattermost", "a1" * 13, True),
        ("mattermost", "C0123456789", False),
        ("mattermost", "A" * 26, False),
        ("mattermost", "a" * 25, False),
        ("slack", "C0123456789", True),
        ("slack", "a1" * 13, False),
    ],
)
def test_the_channel_id_rule_depends_on_the_platform(
    mm_db: Pool, fresh_db: str, platform: str, channel_id: str, accepted: bool
) -> None:
    def bind() -> None:
        with psycopg.connect(fresh_db) as conn:
            conn.execute(
                "INSERT INTO room_binding (tenant_id, platform, workspace_id, channel_id, kind,"
                " store_id, bound_by) VALUES (%s, %s, 'w', %s, 'public', %s, %s)",
                (TENANT, platform, channel_id, STORE, USER),
            )

    if accepted:
        bind()
    else:
        with pytest.raises(psycopg.errors.CheckViolation):
            bind()


def test_client_builds_permalinks(world: World) -> None:
    deps, _server, _ = world
    assert deps.client.permalink(TEAM, "p" * 26) == f"https://mm.example/devshow/pl/{'p' * 26}"


def test_each_capture_result_has_its_reply_text() -> None:
    mid = uuid.UUID(int=1)
    provisional = Created(memory_id=mid, status=MemoryStatus.PROVISIONAL)
    agreed = Created(memory_id=mid, status=MemoryStatus.ACTIVE)
    assert [
        _reply(Skipped()),
        _reply(Rejected(reasons=("secret",))),
        _reply(Reconfirmed(memory_id=mid)),
        _reply(Reconfirmed(memory_id=mid, confirmed=True)),
        _reply(Retracted(memory_id=mid)),
        _reply(provisional),
        _reply(agreed),
        _reply(provisional.model_copy(update={"change": "challenged", "conflict_with": mid})),
        _reply(agreed.model_copy(update={"change": "superseded", "conflict_with": mid})),
    ] == [
        "저장 안 함: 오래 남길 내용이 아니라고 판단했습니다",
        "거부: 비밀값이 들어 있습니다",
        "이미 알고 있음 (재확인했습니다)",
        "다른 분의 말로 확정됐습니다",
        "철회했습니다",
        "저장됨: 기간 안에 이의가 없으면 확정됩니다. 다른 분이 같은 내용을 말하면 바로 확정됩니다",
        "저장됨: 두 분이 동의한 내용이라 바로 확정했습니다",
        "기존 값과 달라 대기 중: 다른 분이 동의하거나 기간 안에 이의가 없으면 바뀝니다",
        "기존 값을 새 값으로 바꿨습니다",
    ]


def evidence(fresh_db: str) -> list[tuple[Any, ...]]:
    with psycopg.connect(fresh_db) as conn:
        return conn.execute(
            "SELECT op, post_id, author, author_name, said_at, basis FROM memory_evidence"
            " ORDER BY id"
        ).fetchall()


@pytest.mark.db
def test_a_pin_by_someone_else_is_two_voices_and_the_memory_is_active(
    world: World, fresh_db: str
) -> None:
    deps, server, _ = world
    handle_event(deps, reaction(user=CURATOR))
    assert [(m[0], m[1]) for m in memories(fresh_db)] == [(TEXT, "active")]
    said = datetime.fromtimestamp(POSTED_MS / 1000, UTC)
    rows = evidence(fresh_db)
    assert [r[:4] + r[5:] for r in rows] == [
        ("propose", "p" * 26, REACTOR, "minji.kim", "agreed"),
        ("propose", f"{'p' * 26}:{CURATOR}", CURATOR, "yuna.choi", "agreed"),
    ]
    assert rows[0][4] == said
    assert [e["post"]["message"] for e in server.ephemerals] == [
        "저장됨: 두 분이 동의한 내용이라 바로 확정했습니다"
    ]


@pytest.mark.db
def test_a_pin_by_the_author_is_one_voice_even_when_names_cannot_be_looked_up(
    world: World, fresh_db: str
) -> None:
    deps, server, _ = world
    server.users_down = True
    handle_event(deps, reaction())
    assert [(m[0], m[1]) for m in memories(fresh_db)] == [(TEXT, "provisional")]
    assert [(r[0], r[2], r[3], r[5]) for r in evidence(fresh_db)] == [
        ("propose", REACTOR, None, "stated")
    ]


@pytest.mark.db
def test_pinning_the_bots_own_post_is_not_agreement(world: World, fresh_db: str) -> None:
    deps, _, _ = world
    handle_event(deps, reaction("b" * 26, user=CURATOR))
    assert [(m[0], m[1]) for m in memories(fresh_db)] == [("봇이 한 말", "provisional")]
    assert [(r[2], r[5]) for r in evidence(fresh_db)] == [(BOT, "stated")]


@pytest.mark.db
def test_main_connects_with_the_bot_token_and_reconnects(
    world: World, fresh_db: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    deps, server, _ = world
    me = {"id": BOT, "username": "nunchi"}

    def with_me(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v4/users/me":
            return httpx.Response(200, json=me)
        return server(request)

    urls: list[str] = []
    sockets = [FakeSocket([reaction()]), FakeSocket([])]

    @asynccontextmanager
    async def fake_connect(url: str) -> AsyncIterator[FakeSocket]:
        urls.append(url)
        if len(urls) == 2:
            raise ConnectionRefusedError
        yield sockets.pop(0)

    class Stop(Exception):
        pass

    async def stop(_seconds: float) -> None:
        if len(urls) >= 2:
            raise Stop

    monkeypatch.setenv("MM_BOT_TOKEN", "tok")
    monkeypatch.setenv("MM_URL", "http://mm")
    monkeypatch.setenv("NUNCHI_TENANT_ID", str(TENANT))
    monkeypatch.setenv("NUNCHI_DATABASE_URL", "postgresql://unused")
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("NUNCHI_EMBEDDING_BASE_URL", raising=False)
    monkeypatch.setattr(mm_main, "connect", fake_connect)
    monkeypatch.setattr(asyncio, "sleep", stop)
    monkeypatch.setattr(mm_main, "open_pool", lambda _s: deps.pool)
    monkeypatch.setattr(
        mm_main,
        "Mattermost",
        lambda url, token, site: Mattermost(url, token, site, httpx.MockTransport(with_me)),
    )
    monkeypatch.setattr(mm_main, "build_extractor", lambda: deps.extractor)
    monkeypatch.setattr(mm_main, "build_judge", lambda: None)
    with pytest.raises(Stop):
        asyncio.run(mm_main.run(mm_main.MattermostEnv()))
    assert urls == ["ws://mm/api/v4/websocket"] * 2
    assert len(memories(fresh_db)) == 1


@pytest.mark.db
@pytest.mark.parametrize("post_id", ["p" * 26, "e" * 26])
def test_a_capture_replies_in_the_channel_and_sends_no_dm(
    world: World, fresh_db: str, post_id: str
) -> None:
    deps, server, _ = world
    handle_event(deps, reaction(post_id))
    assert (len(server.ephemerals), len(memories(fresh_db))) == (1, 1)
    assert {"/channels/direct", "/posts"}.isdisjoint(server.paths)
