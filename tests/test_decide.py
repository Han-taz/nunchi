import uuid

import psycopg
import pytest
from fastapi.testclient import TestClient
from httpx2 import Response

from nunchi.api.problems import ApiError
from nunchi.api.routes import DecisionBody, _decision_body
from nunchi.db import Pool
from tests.conftest import AGENT, API_SUBJECT, OTHER, STORE, TENANT, USER
from tests.test_api import as_user, propose
from tests.test_api import client as client  # noqa: PLC0414 - fixture re-export

pytestmark = pytest.mark.db

NONCE = uuid.UUID("00000000-0000-0000-0000-0000000000f9")
OLD = uuid.UUID("00000000-0000-0000-0000-0000000000f1")


@pytest.fixture
def curated(fresh_db: str, pool: Pool) -> str:
    """OTHER is a curator of STORE; OLD is the live row for (API_SUBJECT, 'owner')."""
    with psycopg.connect(fresh_db) as conn:
        conn.execute(
            "INSERT INTO store_grant (store_id, principal_id, role, tenant_id)"
            " VALUES (%s, %s, 'curator', %s)",
            (STORE, OTHER, TENANT),
        )
        conn.execute(
            "INSERT INTO memory (id, tenant_id, store_id, kind, status, title, subject_id,"
            " attribute, source_refs, created_by)"
            " VALUES (%s, %s, %s, 'fact', 'active', 'owner is A', %s, 'owner',"
            ' \'[{"uri": "https://x.test/1"}]\', %s)',
            (OLD, TENANT, STORE, API_SUBJECT, USER),
        )
    return fresh_db


def propose_replacement(client: TestClient, db: str) -> str:
    res = propose(
        client,
        as_user(USER),
        kind="fact",
        title="owner is B",
        subject_id=str(API_SUBJECT),
        attribute="owner",
        supersedes_id=str(OLD),
        source_refs=[{"uri": "https://x.test/2"}],
    )
    assert res.status_code == 201
    new_id = res.json()["id"]
    with psycopg.connect(db) as conn:
        assert conn.execute("SELECT status FROM memory WHERE id = %s", (new_id,)).fetchone() == (
            "proposed",
        )
    return str(new_id)


def decide(client: TestClient, mid: str, who: dict[str, str], **over: object) -> Response:
    body = {"decision": "approve", "expected_version": 1} | over
    return client.post(f"/v1/memories/{mid}/decide", json=body, headers=who)


def statuses(db: str) -> dict[str, str]:
    with psycopg.connect(db) as conn:
        return dict(
            conn.execute("SELECT title, status::text FROM memory ORDER BY title").fetchall()
        )


def test_curator_approval_supersedes_the_old_version(client: TestClient, curated: str) -> None:
    mid = propose_replacement(client, curated)
    res = decide(client, mid, as_user(OTHER))
    assert (res.status_code, res.json()) == (
        200,
        {"outcome": "active", "have": None, "needed": None},
    )
    assert statuses(curated) == {
        "hello": "active",
        "owner is A": "superseded",
        "owner is B": "active",
    }
    again = decide(client, mid, as_user(OTHER))
    assert (again.status_code, again.json()["detail"]) == (409, "stale")


def test_agent_identity_cannot_decide(client: TestClient, curated: str) -> None:
    mid = propose_replacement(client, curated)
    res = decide(client, mid, as_user(OTHER, AGENT))
    assert (res.status_code, res.json()["detail"]) == (403, "agents cannot decide")
    assert statuses(curated)["owner is B"] == "proposed"


def test_stale_version_conflicts_and_a_non_curator_is_refused(
    client: TestClient, curated: str
) -> None:
    mid = propose_replacement(client, curated)
    with psycopg.connect(curated) as conn:
        conn.execute(
            "INSERT INTO approval_card (nonce, memory_id, version_at_issue, issued_to, platform)"
            " VALUES (%s, %s, 1, %s, 'slack')",
            (NONCE, mid, OTHER),
        )
    stale = decide(client, mid, as_user(OTHER), expected_version=7, nonce=str(NONCE))
    assert (stale.status_code, stale.json()["detail"]) == (409, "stale")
    own = decide(client, mid, as_user(USER))
    assert (own.status_code, own.json()["detail"]) == (403, "not a curator of this memory")
    assert statuses(curated)["owner is B"] == "proposed"


def test_client_cannot_set_gate_flags_or_gate_result(client: TestClient, curated: str) -> None:
    res = propose(
        client,
        as_user(USER),
        gate_flags=["inject-ignore-previous"],
        gate_result={"flags": ["x"], "containment": "ok"},
    )
    assert res.status_code == 201
    with psycopg.connect(curated) as conn:
        row = conn.execute(
            "SELECT gate_result FROM memory WHERE id = %s", (res.json()["id"],)
        ).fetchone()
    assert row is not None
    assert row[0].get("flags") == []


@pytest.mark.parametrize(
    ("answer", "expected"),
    [
        ("pending_quorum:1/2", DecisionBody(outcome="pending_quorum", have=1, needed=2)),
        ("rejected", DecisionBody(outcome="rejected")),
    ],
)
def test_decision_body_maps_outcomes(answer: str, expected: DecisionBody) -> None:
    assert _decision_body(answer) == expected


@pytest.mark.parametrize(
    ("answer", "status"),
    [("self_review", 403), ("duplicate:active", 409), ("unknown_nonce", 404), ("brand_new", 409)],
)
def test_decision_body_maps_refusals(answer: str, status: int) -> None:
    with pytest.raises(ApiError) as caught:
        _decision_body(answer)
    assert (caught.value.status, caught.value.detail) == (status, answer)
