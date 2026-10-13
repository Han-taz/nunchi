import json
import uuid
from collections.abc import Iterator
from typing import Any

import psycopg
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import FastAPI
from fastapi.testclient import TestClient

from nunchi.api import problems
from nunchi.api.app import create_app
from nunchi.api.deps import Runner
from nunchi.auth.identity import Identity
from nunchi.auth.tokens import MAX_TOKEN_CHARS, IssuerConfig, OidcSettings, TokenVerifier
from nunchi.db import Pool
from tests import jwt_support as j
from tests.conftest import AGENT, AGENT_NO_GRANT, API_SUBJECT, OTHER, STORE, TENANT, USER

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
    assert set(created) == {"id", "outcome"}
    assert created["outcome"] == "created"
    assert res.headers["location"] == f"/v1/memories/{created['id']}"
    got = client.get(f"/v1/memories/{created['id']}", headers=h).json()
    assert (got["status"], got["origin"], got["created_by"]) == (
        "provisional",
        "internal",
        str(USER),
    )
    assert (got["subject_id"], got["attribute"]) == (None, None)
    hist = client.get(f"/v1/memories/{created['id']}/history", headers=h).json()
    assert [(v["version"], v["op"]) for v in hist] == [(1, "propose"), (1, "auto_activate")]
    child = propose(
        client,
        h,
        kind="fact",
        title="child",
        source_refs=[{"uri": f"memory://{created['id']}"}],
        subject_id=str(API_SUBJECT),
        attribute="owner",
    )
    assert child.status_code == 201
    deps = client.get(f"/v1/memories/{created['id']}/dependents", headers=h).json()
    assert [d["id"] for d in deps] == [child.json()["id"]]
    assert client.get(f"/v1/memories/{uuid.uuid4()}/history", headers=h).status_code == 404
    assert client.get(f"/v1/memories/{uuid.uuid4()}/dependents", headers=h).status_code == 404


def test_propose_same_key_and_value_reconfirms(client: TestClient) -> None:
    h = as_user(USER)
    fact = {
        "kind": "fact",
        "title": "Infra owner",
        "body": "Kim",
        "source_refs": [{"uri": "https://example.com/org"}],
        "subject_id": str(API_SUBJECT),
        "attribute": "Owner",
    }
    first = propose(client, h, **fact)
    again = propose(client, h, **fact)
    assert (first.status_code, first.json()["outcome"]) == (201, "created")
    assert (again.status_code, again.json()) == (
        200,
        {"id": first.json()["id"], "outcome": "reconfirmed"},
    )
    got = client.get(f"/v1/memories/{first.json()['id']}", headers=h).json()
    assert (got["subject_id"], got["attribute"]) == (str(API_SUBJECT), "owner")
    assert got["last_confirmed_at"] is not None


def test_propose_rejections(client: TestClient) -> None:
    h = as_user(USER)
    assert propose(client, h, origin="external").status_code == 422
    assert propose(client, h, kind="fact").status_code == 422
    assert propose(client, h, subject_id=str(API_SUBJECT)).status_code == 422
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
        j.auth(str(USER), alg="ES256", key=ec.generate_private_key(ec.SECP256R1())),
        {"Authorization": f"Bearer {'x' * (MAX_TOKEN_CHARS + 1)}"},
    ],
    ids=range(10),
)
def test_unauthenticated_is_401(client: TestClient, headers: dict[str, str]) -> None:
    res = client.get("/v1/stores", headers=headers)
    assert res.status_code == 401
    assert res.headers["www-authenticate"] == "Bearer"
    assert res.json()["detail"] == "authentication failed"


def test_non_json_jwks_is_401(pool: Pool) -> None:
    class NotJson(j.StaticJwks):
        def fetch_data(self) -> object:
            raise json.JSONDecodeError("Expecting value", "<html>", 0)

    issuers = {j.ISSUER_A: IssuerConfig(tenant_id=TENANT, jwks_url="https://unused.test/a")}
    verifier = TokenVerifier(OidcSettings(issuers=issuers), {j.ISSUER_A: NotJson()})
    res = TestClient(create_app(pool, verifier), raise_server_exceptions=False).get(
        "/v1/stores", headers=j.auth(str(USER))
    )
    assert (res.status_code, res.json()["detail"]) == (401, "authentication failed")


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


def test_http_exception_and_validation_shapes(client: TestClient) -> None:
    missing = client.get("/nope")
    assert (missing.status_code, missing.headers["content-type"]) == (
        404,
        "application/problem+json",
    )
    bad = client.get("/v1/memories/not-a-uuid", headers=as_user(USER))
    assert bad.status_code == 422
    assert bad.json()["detail"].startswith("path.memory_id")
