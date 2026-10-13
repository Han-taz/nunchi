import gc
import json
import threading
import time
import uuid
from collections.abc import Iterator
from typing import Any

import anthropic
import anyio
import httpx
import httpx2
import psycopg
import pytest
import uvicorn
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from nunchi.db import Pool
from nunchi.extract import ClaudeExtractor
from nunchi.extract.claude import MODEL
from nunchi.mcp.server import AGENT_HEADER, build_server, decided_outcome
from tests.conftest import AGENT, OTHER, STORE, TENANT, USER
from tests.jwt_support import mint, verifier
from tests.test_repo import world as world  # noqa: PLC0414 - fixture re-export

pytestmark = [
    pytest.mark.db,
    pytest.mark.filterwarnings("ignore:Unclosed <MemoryObject:ResourceWarning"),
    pytest.mark.filterwarnings(
        "ignore:Exception ignored in.*MemoryObject:pytest.PytestUnraisableExceptionWarning"
    ),
]
REFS = [{"uri": "https://example.slack.com/archives/C1/p1", "system": "slack"}]
CURATOR = OTHER


@pytest.fixture(autouse=True)
def _collect_leaked_streams() -> Iterator[None]:
    yield
    gc.collect()


def reply(owner: str) -> dict[str, Any]:
    return {
        "relation": "new",
        "relation_id": None,
        "kind": "fact",
        "title": f"A사 담당자는 {owner}",
        "body": f"A사 담당자: {owner}",
        "subject_name": "A사",
        "attribute": "담당자",
        "valid_from": None,
    }


class Script:
    """What the fake Anthropic endpoint answers next."""

    def __init__(self) -> None:
        self.reply: dict[str, Any] | None = None

    def extractor(self) -> ClaudeExtractor:
        def answer(_req: httpx2.Request) -> httpx2.Response:
            message = {
                "id": "msg_01",
                "type": "message",
                "role": "assistant",
                "model": MODEL,
                "content": [{"type": "text", "text": json.dumps(self.reply)}],
                "stop_reason": "end_turn",
                "stop_sequence": None,
                "usage": {"input_tokens": 1, "output_tokens": 1},
            }
            return httpx2.Response(200, json=message)

        client = anthropic.Anthropic(
            api_key="test-key",
            max_retries=0,
            http_client=anthropic.DefaultHttpxClient(transport=httpx2.MockTransport(answer)),
        )
        return ClaudeExtractor(client)


@pytest.fixture
def script() -> Script:
    return Script()


@pytest.fixture
def url(world: Pool, fresh_db: str, script: Script) -> Iterator[str]:
    with psycopg.connect(fresh_db) as conn:
        conn.execute(
            "UPDATE store_grant SET role = 'curator' WHERE store_id = %s AND principal_id = %s",
            (STORE, CURATOR),
        )
    app = build_server(world, verifier(TENANT), extractor=script.extractor()).streamable_http_app()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=0, log_level="warning"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    while not server.started:
        time.sleep(0.01)
    port = server.servers[0].sockets[0].getsockname()[1]
    yield f"http://127.0.0.1:{port}/mcp"
    server.should_exit = True
    thread.join()


async def call(
    url: str, sub: uuid.UUID, tool: str, args: dict[str, Any], agent: uuid.UUID | None = None
) -> dict[str, Any]:
    headers = {"Authorization": f"Bearer {mint(str(sub))}"}
    if agent is not None:
        headers[AGENT_HEADER] = mint(str(agent))
    async with (
        httpx.AsyncClient(headers=headers) as http,
        streamable_http_client(url, http_client=http) as (r, w, _),
        ClientSession(r, w) as s,
    ):
        await s.initialize()
        result = await s.call_tool(tool, args)
    assert not result.isError, result.content
    assert result.structuredContent is not None
    return result.structuredContent


def remember(url: str, script: Script, owner: str) -> dict[str, Any]:
    script.reply = reply(owner)
    args = {"text": f"A사 담당자는 {owner}입니다", "store_id": str(STORE), "source_refs": REFS}
    return anyio.run(call, url, USER, "remember", args)


def decide(url: str, sub: uuid.UUID, memory_id: str, verdict: str, version: int) -> dict[str, Any]:
    args = {"memory_id": memory_id, "decision": verdict, "expected_version": version}
    return anyio.run(call, url, sub, "decide", args)


def test_new_then_reconfirm_then_conflict_then_curator_supersedes(url: str, script: Script) -> None:
    first = remember(url, script, "이OO")
    assert (first["outcome"], first["conflict_with"]) == ("created", None)
    assert first["status"] == "provisional"

    again = remember(url, script, "이OO")
    assert again == {"outcome": "reconfirmed", "memory_id": first["memory_id"]}

    changed = remember(url, script, "박OO")
    assert (changed["outcome"], changed["conflict_with"]) == ("created", first["memory_id"])
    assert changed["tier"] in ("one_curator", "two_curators")
    assert changed["status"] == "proposed"
    assert decide(url, CURATOR, changed["memory_id"], "approve", 1) == {
        "outcome": "applied",
        "status": "active",
    }

    old = anyio.run(call, url, USER, "get", {"memory_id": first["memory_id"]})
    new = anyio.run(call, url, USER, "get", {"memory_id": changed["memory_id"]})
    assert (old["data"]["status"], new["data"]["status"]) == ("superseded", "active")


def test_agent_cannot_decide_even_with_a_curator_user(url: str, script: Script) -> None:
    created = remember(url, script, "이OO")
    refused = anyio.run(
        call,
        url,
        CURATOR,
        "decide",
        {"memory_id": created["memory_id"], "decision": "approve", "expected_version": 1},
        AGENT,
    )
    assert refused == {"outcome": "refused", "reason": "agent_may_not_decide"}
    got = anyio.run(call, url, USER, "get", {"memory_id": created["memory_id"]})
    assert got["data"]["status"] == "provisional"


def test_non_curator_and_stale_version_are_refused(url: str, script: Script) -> None:
    created = remember(url, script, "이OO")
    mid = created["memory_id"]
    assert decide(url, USER, mid, "approve", 1) == {"outcome": "refused", "reason": "not_curator"}
    assert decide(url, CURATOR, mid, "approve", 7) == {"outcome": "refused", "reason": "stale"}


def test_secret_is_rejected_and_chit_chat_is_skipped(url: str, script: Script) -> None:
    script.reply = reply("이OO")
    secret = "AKIAIOSFODNN7EXAMPLE"  # noqa: S105 - AWS documentation example key
    args = {"text": f"담당자 이OO key {secret}", "store_id": str(STORE), "source_refs": REFS}
    rejected = anyio.run(call, url, USER, "remember", args)
    assert rejected["outcome"] == "rejected"
    assert rejected["reasons"]
    assert secret not in json.dumps(rejected)

    script.reply = {**reply("x"), "relation": "not_worth", "kind": "note", "body": None}
    script.reply |= {"subject_name": None, "attribute": None}
    skipped = anyio.run(call, url, USER, "remember", args | {"text": "점심 뭐 먹지"})
    assert skipped == {"outcome": "skipped"}


def test_extractor_failure_is_a_tool_error(url: str, script: Script) -> None:
    script.reply = {"unexpected": True}
    args = {"text": "A사 담당자는 이OO입니다", "store_id": str(STORE), "source_refs": REFS}
    with pytest.raises(AssertionError, match="extraction failed: malformed"):
        anyio.run(call, url, USER, "remember", args)


@pytest.mark.parametrize(
    ("raw", "typed"),
    [
        ("active", {"outcome": "applied", "status": "active"}),
        ("rejected", {"outcome": "applied", "status": "rejected"}),
        ("pending_quorum:1/2", {"outcome": "pending", "have": 1, "needed": 2}),
        ("self_review", {"outcome": "refused", "reason": "self_review"}),
    ],
)
def test_decide_result_strings_map_to_typed_outcomes(raw: str, typed: dict[str, Any]) -> None:
    assert decided_outcome(raw) == typed
