import gc
import json
import threading
import time
import uuid
from collections.abc import Iterator
from datetime import date
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
from nunchi.mcp.server import AGENT_HEADER, build_server
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
                "content": [{"type": "text", "text": json.dumps({"items": [self.reply]})}],
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
        conn.execute(
            "UPDATE store_grant SET role = 'contributor' WHERE store_id = %s AND principal_id = %s",
            (STORE, AGENT),
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


def test_new_then_reconfirm_then_conflict(url: str, script: Script) -> None:
    first = remember(url, script, "이OO")
    assert (first["outcome"], first["conflict_with"]) == ("created", None)
    assert first["status"] == "provisional"

    again = remember(url, script, "이OO")
    assert again == {
        "outcome": "reconfirmed",
        "memory_id": first["memory_id"],
        "confirmed": False,
    }

    changed = remember(url, script, "박OO")
    assert (changed["outcome"], changed["conflict_with"]) == ("created", first["memory_id"])
    assert changed["status"] == "challenger"


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


def fetch(url: str, sub: uuid.UUID, tool: str, args: dict[str, Any]) -> Any:  # noqa: ANN401
    out = anyio.run(call, url, sub, tool, args)
    return out.get("result", out)


def memory_of(url: str, script: Script, owner: str) -> dict[str, Any]:
    out = remember(url, script, owner)
    row: dict[str, Any] = fetch(url, USER, "get", {"memory_id": out["memory_id"]})
    return row


def decide(
    url: str, sub: uuid.UUID, row: dict[str, Any], verdict: str, agent: uuid.UUID | None = None
) -> dict[str, Any]:
    args = {
        "memory_id": row["id"],
        "verdict": verdict,
        "expected_version": row["version"],
        "source_refs": REFS,
    }
    return anyio.run(call, url, sub, "decide", args, agent)


def evidence_ops(db_url: str, memory_id: str) -> list[tuple[str, str]]:
    with psycopg.connect(db_url) as conn:
        return conn.execute(
            "SELECT op::text, basis::text FROM memory_evidence WHERE memory_id = %s ORDER BY id",
            (memory_id,),
        ).fetchall()


def test_an_agent_retracts_a_provisional_memory_with_one_evidence_row(
    url: str, script: Script, fresh_db: str
) -> None:
    row = memory_of(url, script, "이OO")
    assert (row["data"]["status"], row["label"]) == ("provisional", "미확정")

    done = decide(url, USER, row, "retract", agent=AGENT)

    assert done == {"outcome": "applied", "status": "rejected", "reason": None}
    assert evidence_ops(fresh_db, row["id"]) == [("propose", "stated"), ("retract", "agent")]


def test_the_speaker_confirming_alone_only_reconfirms_and_a_second_person_confirms(
    url: str, script: Script, fresh_db: str
) -> None:
    row = memory_of(url, script, "이OO")

    same = decide(url, USER, row, "confirm")
    assert same == {"outcome": "reconfirmed", "status": "provisional", "reason": None}

    row = fetch(url, USER, "get", {"memory_id": row["id"]})
    other = decide(url, CURATOR, row, "confirm")
    assert other == {"outcome": "applied", "status": "active", "reason": None}

    done = fetch(url, USER, "get", {"memory_id": row["id"]})
    assert (done["label"], done["basis"], done["promote_at"]) == (None, "agent", None)
    assert done["evidence"]["count"] == 3
    assert done["evidence"]["distinct_authors"] == 2
    assert [op for op, _ in evidence_ops(fresh_db, row["id"])] == [
        "propose",
        "reconfirm",
        "confirm",
    ]


def test_a_stale_version_is_refused(url: str, script: Script) -> None:
    row = memory_of(url, script, "이OO")
    decide(url, USER, row, "confirm")
    assert decide(url, USER, row, "confirm")["reason"] == "stale"


def test_a_challenger_shows_on_the_live_row_and_never_in_as_of(url: str, script: Script) -> None:
    live = memory_of(url, script, "이OO")
    changed = remember(url, script, "박OO")
    assert changed["status"] == "challenger"

    hits = fetch(url, CURATOR, "search", {"query": "박OO"})
    assert [(h["id"], h["status"], h["label"]) for h in hits] == [
        (live["id"], "provisional", "미확정")
    ]
    pending = hits[0]["pending_change"]
    assert (pending["id"], pending["title"]) == (changed["memory_id"], "A사 담당자는 박OO")

    keys = fetch(url, USER, "search", {"query": "이OO"})[0]
    as_of = fetch(
        url,
        USER,
        "as_of",
        {
            "store_id": str(STORE),
            "subject_id": keys["subject_id"],
            "attribute": keys["attribute"],
            "on": date.today().isoformat(),
        },
    )
    assert as_of["id"] == live["id"]

    own = fetch(url, USER, "search", {"query": "박OO", "statuses": ["challenger"]})
    assert [(h["id"], h["label"], h["pending_change"]) for h in own] == [
        (changed["memory_id"], "변경 제안 (미확정)", None)
    ]


def test_history_lists_the_evidence_behind_each_version(url: str, script: Script) -> None:
    row = memory_of(url, script, "이OO")
    decide(url, USER, row, "confirm")

    versions = fetch(url, USER, "history", {"memory_id": row["id"]})

    assert [(v["op"], [e["uri"] for e in v["evidence"]]) for v in versions] == [
        ("propose", [REFS[0]["uri"]]),
        ("reconfirm", [REFS[0]["uri"]]),
    ]
    assert versions[1]["evidence"][0]["basis"] == "agent"
