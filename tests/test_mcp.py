import gc
import threading
import time
import uuid
from collections.abc import AsyncIterator, Iterator
from contextlib import asynccontextmanager
from typing import Any

import anyio
import httpx
import psycopg
import pytest
import uvicorn
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from nunchi.db import Pool
from nunchi.mcp.server import NOTICE, build_server
from tests.conftest import OTHER, STORE, TENANT, USER
from tests.jwt_support import mint, verifier

# The SDK client and server leave anyio memory streams to the garbage collector on every session;
# the filter is scoped to this module and to exactly that message.
pytestmark = [
    pytest.mark.db,
    pytest.mark.filterwarnings("ignore:Unclosed <MemoryObject:ResourceWarning"),
    pytest.mark.filterwarnings(
        "ignore:Exception ignored in.*MemoryObject:pytest.PytestUnraisableExceptionWarning"
    ),
]


@pytest.fixture(autouse=True)
def _collect_leaked_streams() -> Iterator[None]:
    """Make the leaked streams die here, under the filter, not during an unrelated later test."""
    yield
    gc.collect()


HIDDEN_STORE = uuid.UUID("00000000-0000-0000-0000-0000000000d2")
SUBJECT = uuid.UUID("00000000-0000-0000-0000-0000000000e4")
KOREAN = uuid.UUID("00000000-0000-0000-0000-0000000000e1")
OLD = uuid.UUID("00000000-0000-0000-0000-0000000000e2")
HIDDEN = uuid.UUID("00000000-0000-0000-0000-0000000000e3")


@pytest.fixture
def world(fresh_db: str, pool: Pool) -> Pool:
    """STORE: USER contributor. HIDDEN_STORE: only OTHER can read it."""
    with psycopg.connect(fresh_db) as conn:
        conn.execute(
            "INSERT INTO store (id, tenant_id, kind, slug, description)"
            " VALUES (%s, %s, 'project', 'hidden', 'x')",
            (HIDDEN_STORE, TENANT),
        )
        conn.execute(
            "INSERT INTO store_grant (store_id, principal_id, role, tenant_id)"
            " VALUES (%s, %s, 'reader', %s)",
            (HIDDEN_STORE, OTHER, TENANT),
        )
        conn.execute(
            "INSERT INTO entity (id, tenant_id, kind, canonical_name)"
            " VALUES (%s, %s, 'team', 'Infra')",
            (SUBJECT, TENANT),
        )
        rows = (
            (
                KOREAN,
                STORE,
                "active",
                "배포 담당",
                "배포 담당자는 김철수입니다",
                "owner",
                "2026-01-01",
                None,
            ),
            (
                OLD,
                STORE,
                "superseded",
                "배포 담당 (이전)",
                "이전 담당자는 이영희",
                "owner",
                "2025-01-01",
                "2026-01-01",
            ),
            (HIDDEN, HIDDEN_STORE, "active", "비밀 담당", "비밀 담당자", "secret", None, None),
        )
        for mid, store, status, title, body, attr, vfrom, vto in rows:
            conn.execute(
                "INSERT INTO memory (id, tenant_id, store_id, kind, status, title, body,"
                " subject_id, attribute, valid_from, valid_to, created_by, source_refs)"
                " VALUES (%s, %s, %s, 'fact', %s, %s, %s, %s, %s, %s, %s, %s,"
                ' \'[{"uri": "doc:1"}]\')',
                (mid, TENANT, store, status, title, body, SUBJECT, attr, vfrom, vto, USER),
            )
    return pool


@pytest.fixture
def url(world: Pool) -> Iterator[str]:
    app = build_server(world, verifier(TENANT)).streamable_http_app()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=0, log_level="warning"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    while not server.started:
        time.sleep(0.01)
    port = server.servers[0].sockets[0].getsockname()[1]
    yield f"http://127.0.0.1:{port}/mcp"
    server.should_exit = True
    thread.join()


@asynccontextmanager
async def session(url: str, token: str | None) -> AsyncIterator[ClientSession]:
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    async with (
        httpx.AsyncClient(headers=headers) as http,
        streamable_http_client(url, http_client=http) as (r, w, _),
        ClientSession(r, w) as s,
    ):
        await s.initialize()
        yield s


async def call(url: str, sub: uuid.UUID, tool: str, args: dict[str, Any] | None = None) -> Any:  # noqa: ANN401
    async with session(url, mint(str(sub))) as s:
        result = await s.call_tool(tool, args or {})
    assert not result.isError, result.content
    data = result.structuredContent or {}
    return data.get("result", data) if data else None


def test_reader_sees_only_their_stores(url: str) -> None:
    mine = anyio.run(call, url, USER, "list_stores")
    other = anyio.run(call, url, OTHER, "list_stores")
    assert [s["slug"] for s in mine] == ["s"]
    assert [s["slug"] for s in other] == ["hidden"]


def test_search_finds_korean_without_body(url: str) -> None:
    hits = anyio.run(call, url, USER, "search", {"query": "담당자"})
    assert [(h["id"], h["title"], h["status"], h["attribute"]) for h in hits] == [
        (str(KOREAN), "배포 담당", "active", "owner")
    ]
    assert "body" not in hits[0] and hits[0]["last_confirmed_at"]
    hidden = anyio.run(call, url, OTHER, "search", {"query": "담당자"})
    assert [h["id"] for h in hidden] == [str(HIDDEN)]


def test_get_wraps_body_as_data(url: str) -> None:
    got = anyio.run(call, url, USER, "get", {"memory_id": str(KOREAN)})
    assert got == {
        "id": str(KOREAN),
        "title": "배포 담당",
        "notice": NOTICE,
        "data": {
            "type": "memory",
            "origin": "internal",
            "status": "active",
            "body": "배포 담당자는 김철수입니다",
        },
    }


def test_get_hidden_memory_is_not_found(url: str) -> None:
    async def run() -> bool:
        async with session(url, mint(str(USER))) as s:
            result = await s.call_tool("get", {"memory_id": str(HIDDEN)})
        return result.isError

    assert anyio.run(run)


def test_history_lists_versions(url: str) -> None:
    versions = anyio.run(call, url, USER, "history", {"memory_id": str(KOREAN)})
    assert [(v["version"], v["op"]) for v in versions] == [(1, "propose")]


def test_as_of_picks_the_version_valid_on_that_date(url: str) -> None:
    args = {"store_id": str(STORE), "subject_id": str(SUBJECT), "attribute": "owner"}
    old = anyio.run(call, url, USER, "as_of", {**args, "on": "2025-06-01"})
    now = anyio.run(call, url, USER, "as_of", {**args, "on": "2026-06-01"})
    none = anyio.run(call, url, USER, "as_of", {**args, "on": "2020-01-01"})
    assert old["data"]["body"] == "이전 담당자는 이영희"
    assert (now["data"]["body"], now["valid_from"]) == ("배포 담당자는 김철수입니다", "2026-01-01")
    assert none is None


@pytest.mark.parametrize("token", [None, "garbage", "wrong"])
def test_missing_or_invalid_token_is_refused(url: str, token: str | None) -> None:
    if token == "wrong":  # noqa: S105
        token = mint(str(USER), aud="someone-else")

    async def run() -> None:
        async with session(url, token):
            pass

    with pytest.raises(BaseException):  # noqa: B017 - the client surfaces a 401 as a group
        anyio.run(run)


def test_unknown_principal_is_refused(url: str) -> None:
    async def run() -> None:
        async with session(url, mint(str(uuid.uuid4()))) as s:
            result = await s.call_tool("list_stores", {})
            assert result.isError

    anyio.run(run)
