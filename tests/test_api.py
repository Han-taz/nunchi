import uuid
from collections.abc import Iterator
from typing import Any

import psycopg
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from nunchi.api import problems
from nunchi.api.app import create_app
from nunchi.api.deps import Runner
from nunchi.auth.identity import Identity
from nunchi.db import Pool
from tests import jwt_support as j
from tests.conftest import AGENT, AGENT_NO_GRANT, OTHER, STORE, TENANT, USER

OTHER_TENANT = uuid.UUID("00000000-0000-0000-0000-0000000000c2")
pytestmark = pytest.mark.db


@pytest.fixture
def client(pool: Pool) -> Iterator[TestClient]:
    yield TestClient(
        create_app(pool, j.verifier(TENANT, OTHER_TENANT)), raise_server_exceptions=False
    )


def as_user(user: uuid.UUID, agent: uuid.UUID | None = None) -> dict[str, str]:
    headers = j.auth(str(user))
    if agent is not None:
        headers["X-Agent-Token"] = j.mint(str(agent))
    return headers


def test_list_stores(client: TestClient) -> None:
    res = client.get("/v1/stores", headers=as_user(USER))
    assert res.status_code == 200
    assert [(s["slug"], s["role"]) for s in res.json()] == [("s", "contributor")]
    narrowed = client.get("/v1/stores", headers=as_user(USER, AGENT))
    assert [s["role"] for s in narrowed.json()] == ["reader"]
    assert client.get("/v1/stores", headers=as_user(USER, AGENT_NO_GRANT)).json() == []


def test_index_search_get(client: TestClient) -> None:
    h = as_user(USER)
    idx = client.get(f"/v1/stores/{STORE}/memories", headers=h).json()
    assert [m["title"] for m in idx] == ["hello"]
    hits = client.get("/v1/search", params={"q": "hello"}, headers=h).json()
    assert [x["id"] for x in hits] == [idx[0]["id"]]
    assert client.get("/v1/search", params={"q": "hello", "kind": "fact"}, headers=h).json() == []
    got = client.get(f"/v1/memories/{idx[0]['id']}", headers=h)
    assert got.status_code == 200
    assert got.json()["title"] == "hello"
    assert client.get(f"/v1/memories/{idx[0]['id']}", headers=as_user(OTHER)).status_code == 404
    assert client.get("/v1/search", params={"q": ""}, headers=h).status_code == 422


def test_get_unknown_is_a_problem_document(client: TestClient) -> None:
    res = client.get(f"/v1/memories/{uuid.uuid4()}", headers=as_user(USER))
    assert res.status_code == 404
    assert res.headers["content-type"] == "application/problem+json"
    assert res.json() == {
        "type": "about:blank",
        "title": "Not Found",
        "status": 404,
        "detail": "memory not found",
    }


def propose(client: TestClient, headers: dict[str, str], **over: Any) -> Any:  # noqa: ANN401
    body = {"store_id": str(STORE), "kind": "note", "title": "fresh", "body": "b"} | over
    return client.post("/v1/memories", json=body, headers=headers)


def test_propose_history_dependents(client: TestClient) -> None:
    h = as_user(USER)
    res = propose(client, h)
    assert res.status_code == 201
    created = res.json()
    assert res.headers["location"] == f"/v1/memories/{created['id']}"
    assert (created["status"], created["origin"], created["created_by"]) == (
        "provisional",
        "internal",
        str(USER),
    )
    hist = client.get(f"/v1/memories/{created['id']}/history", headers=h).json()
    assert [(v["version"], v["op"]) for v in hist] == [(1, "propose"), (1, "auto_activate")]
    child = propose(
        client,
        h,
        kind="fact",
        title="child",
        source_refs=[{"uri": f"memory://{created['id']}"}],
    )
    assert child.status_code == 201
    deps = client.get(f"/v1/memories/{created['id']}/dependents", headers=h).json()
    assert [d["id"] for d in deps] == [child.json()["id"]]
    assert client.get(f"/v1/memories/{uuid.uuid4()}/history", headers=h).status_code == 404
    assert client.get(f"/v1/memories/{uuid.uuid4()}/dependents", headers=h).status_code == 404


def test_propose_rejections(client: TestClient) -> None:
    h = as_user(USER)
    assert propose(client, h, origin="external").status_code == 422
    assert propose(client, h, kind="fact").status_code == 422
    assert propose(client, as_user(OTHER)).status_code == 403
    assert propose(client, as_user(USER, AGENT)).status_code == 403
    assert propose(client, h, supersedes_id=str(uuid.uuid4())).status_code == 404


def test_decide_is_a_typed_501(client: TestClient) -> None:
    res = client.post(f"/v1/memories/{uuid.uuid4()}/decision", headers=as_user(USER))
    assert (res.status_code, res.json()["detail"]) == (501, "decide is not implemented")
    assert client.post(f"/v1/memories/{uuid.uuid4()}/decision").status_code == 401


@pytest.mark.parametrize(
    "headers",
    [
        {},
        {"Authorization": "Basic abc"},
        {"Authorization": "Bearer"},
        {"Authorization": "Bearer junk"},
        j.auth(str(USER), exp_in=-5),
        j.auth(str(uuid.uuid4())),
        j.auth(str(AGENT)),
        j.auth(str(USER), iss=j.ISSUER_B),
    ],
    ids=range(8),
)
def test_unauthenticated_is_401(client: TestClient, headers: dict[str, str]) -> None:
    res = client.get("/v1/stores", headers=headers)
    assert res.status_code == 401
    assert res.headers["www-authenticate"] == "Bearer"
    assert res.json()["detail"] == "authentication failed"


@pytest.mark.parametrize(
    ("sqlstate", "status"),
    [
        ("42501", 403),
        ("23505", 409),
        ("23503", 404),
        ("28000", 401),
        ("P0001", 409),
        ("40001", 503),
        ("23514", 422),
        ("XX000", 500),
    ],
)
def test_sqlstate_table(sqlstate: str, status: int) -> None:
    app = FastAPI()
    problems.install(app)

    @app.get("/boom")
    def boom() -> None:
        raise psycopg.errors.lookup(sqlstate)("db detail\nsecond line")

    res = TestClient(app, raise_server_exceptions=False).get("/boom")
    assert res.status_code == status
    assert res.headers["content-type"] == "application/problem+json"
    assert "second line" not in res.text
    if status == 500:
        assert "db detail" not in res.text


def test_runner_retries_serialization_failures(pool: Pool) -> None:
    run = Runner(pool, Identity(USER, None))
    calls: list[int] = []

    def flaky(conn: object) -> str:
        calls.append(1)
        if len(calls) < 3:
            raise psycopg.errors.SerializationFailure
        return "done"

    assert run(flaky) == "done"
    assert len(calls) == 3
    calls.clear()

    def always(conn: object) -> str:
        calls.append(1)
        raise psycopg.errors.SerializationFailure

    with pytest.raises(psycopg.errors.SerializationFailure):
        run(always)
    assert len(calls) == 3


def test_http_exception_and_validation_shapes(client: TestClient) -> None:
    missing = client.get("/nope")
    assert (missing.status_code, missing.headers["content-type"]) == (
        404,
        "application/problem+json",
    )
    bad = client.get("/v1/memories/not-a-uuid", headers=as_user(USER))
    assert bad.status_code == 422
    assert bad.json()["detail"].startswith("path.memory_id")


def test_a_request_cannot_choose_the_tenant(client: TestClient) -> None:
    # USER lives in TENANT, which ISSUER_A maps to. Naming another tenant anywhere changes nothing.
    forged = {
        **as_user(USER),
        "X-Tenant-Id": str(OTHER_TENANT),
        "X-Nunchi-Tenant": str(OTHER_TENANT),
    }
    params = {"tenant_id": str(OTHER_TENANT), "tenant": str(OTHER_TENANT)}
    res = client.get("/v1/stores", headers=forged, params=params)
    assert [s["slug"] for s in res.json()] == ["s"]
    # the same sub through the issuer of another tenant is unknown there, whatever else is sent
    foreign = {**j.auth(str(USER), iss=j.ISSUER_B), "X-Tenant-Id": str(TENANT)}
    assert (
        client.get("/v1/stores", headers=foreign, params={"tenant_id": str(TENANT)}).status_code
        == 401
    )
    unknown_issuer = j.auth(str(USER), iss="https://evil.test")
    assert client.get("/v1/stores", headers=unknown_issuer).status_code == 401
