import uuid
from datetime import UTC, datetime
from typing import Any

import psycopg
import pytest

from nunchi.db import Pool, request_tx
from nunchi.domain import repo
from nunchi.domain.models import (
    Evidence,
    MemoryKind,
    MemoryOp,
    MemoryOrigin,
    MemoryStatus,
    ProposeOutcome,
    ProposeRequest,
    Role,
    SourceRef,
    StoreKind,
)
from tests.conftest import AGENT, AGENT_NO_GRANT, OTHER, STORE, TENANT, USER

HIDDEN_STORE = uuid.UUID("00000000-0000-0000-0000-0000000000d2")
ACTIVE = uuid.UUID("00000000-0000-0000-0000-0000000000e1")
PROPOSED_BY_OTHER = uuid.UUID("00000000-0000-0000-0000-0000000000e2")
HIDDEN = uuid.UUID("00000000-0000-0000-0000-0000000000e3")
SUBJECT = uuid.UUID("00000000-0000-0000-0000-0000000000e4")


@pytest.fixture
def world(fresh_db: str, pool: Pool) -> Pool:
    """STORE: USER contributor, AGENT reader. HIDDEN_STORE: nobody. Plus three extra memories."""
    with psycopg.connect(fresh_db) as conn:
        conn.execute(
            "INSERT INTO store (id, tenant_id, kind, slug, description)"
            " VALUES (%s, %s, 'project', 'hidden', 'nobody here')",
            (HIDDEN_STORE, TENANT),
        )
        conn.execute(
            "INSERT INTO store_grant (store_id, principal_id, role, tenant_id)"
            " VALUES (%s, %s, 'reader', %s)",
            (STORE, OTHER, TENANT),
        )
        conn.execute(
            "INSERT INTO entity (id, tenant_id, kind, canonical_name)"
            " VALUES (%s, %s, 'team', 'Infra')",
            (SUBJECT, TENANT),
        )
        rows = (
            (ACTIVE, STORE, "active", "Deploy runbook", "restart the pods", USER),
            (PROPOSED_BY_OTHER, STORE, "proposed", "Draft idea", "unreviewed pods", OTHER),
            (HIDDEN, HIDDEN_STORE, "active", "Secret plan", "pods of gold", USER),
        )
        for mid, store, status, title, body, author in rows:
            conn.execute(
                "INSERT INTO memory"
                " (id, tenant_id, store_id, kind, status, title, body, created_by)"
                " VALUES (%s, %s, %s, 'note', %s, %s, %s, %s)",
                (mid, TENANT, store, status, title, body, author),
            )
    return pool


@pytest.mark.db
def test_list_stores_shows_the_role_the_caller_holds(world: Pool) -> None:
    with request_tx(world, USER, None) as conn:
        user_view = repo.list_stores(conn)
    with request_tx(world, USER, AGENT) as conn:
        agent_view = repo.list_stores(conn)
    with request_tx(world, USER, AGENT_NO_GRANT) as conn:
        no_grant_view = repo.list_stores(conn)
    assert [(s.slug, s.kind, s.role) for s in user_view] == [
        ("s", StoreKind.TEAM, Role.CONTRIBUTOR)
    ]
    assert [s.role for s in agent_view] == [Role.READER]
    assert no_grant_view == []


@pytest.mark.db
def test_index_lists_only_active_titles(world: Pool) -> None:
    with request_tx(world, USER, None) as conn:
        titles = [m.title for m in repo.index(conn, STORE)]
        hidden = repo.index(conn, HIDDEN_STORE)
    assert titles == ["Deploy runbook", "hello"]
    assert hidden == []


@pytest.mark.db
def test_search_applies_visibility_and_filters(world: Pool) -> None:
    active = (MemoryStatus.ACTIVE,)
    with request_tx(world, USER, None) as conn:
        found = repo.search(conn, "pods", None, None, active)
        wrong_kind = repo.search(conn, "pods", None, [MemoryKind.FACT], active)
        scoped = repo.search(conn, "pods", [HIDDEN_STORE], [MemoryKind.NOTE], active)
        proposed = repo.search(conn, "pods", None, None, (MemoryStatus.PROPOSED,))
    with request_tx(world, OTHER, None) as conn:
        others = repo.search(conn, "pods", None, None, (MemoryStatus.PROPOSED,))
    assert [h.id for h in found] == [ACTIVE]
    assert found[0].score > 0
    assert wrong_kind == []
    assert scoped == []
    assert proposed == []
    assert others == [] or others[0].id == PROPOSED_BY_OTHER


@pytest.mark.db
def test_get_returns_none_for_unreadable_and_unknown(world: Pool) -> None:
    with request_tx(world, USER, None) as conn:
        mem = repo.get(conn, ACTIVE)
        hidden = repo.get(conn, HIDDEN)
        proposed = repo.get(conn, PROPOSED_BY_OTHER)
        unknown = repo.get(conn, uuid.uuid4())
    assert mem is not None
    assert (mem.title, mem.body, mem.status, mem.version) == (
        "Deploy runbook",
        "restart the pods",
        MemoryStatus.ACTIVE,
        1,
    )
    assert hidden is None
    assert proposed is None
    assert unknown is None


@pytest.mark.db
def test_propose_binds_the_author_and_ignores_the_client(fresh_db: str, world: Pool) -> None:
    req = ProposeRequest(store_id=STORE, kind=MemoryKind.NOTE, title="new", body="b")
    with request_tx(world, USER, AGENT_NO_GRANT) as conn, pytest.raises(psycopg.Error):
        repo.remember(conn, req)
    with request_tx(world, USER, None) as conn:
        direct = repo.get(conn, repo.remember(conn, req).memory_id)
    assert direct is not None
    assert (direct.status, direct.origin, direct.created_by, direct.on_behalf_of) == (
        MemoryStatus.PROVISIONAL,
        MemoryOrigin.INTERNAL,
        USER,
        None,
    )
    assert direct.version == 1


@pytest.mark.db
def test_propose_as_agent_records_the_delegate(fresh_db: str, world: Pool) -> None:
    with psycopg.connect(fresh_db) as conn:
        conn.execute(
            "UPDATE store_grant SET role = 'contributor' WHERE principal_id = %s", (AGENT,)
        )
    req = ProposeRequest(store_id=STORE, kind=MemoryKind.NOTE, title="by agent")
    with request_tx(world, USER, AGENT) as conn:
        mem = repo.get(conn, repo.remember(conn, req).memory_id)
    assert mem is not None
    assert (mem.created_by, mem.on_behalf_of) == (AGENT, USER)
    assert mem.status == MemoryStatus.PROVISIONAL


@pytest.mark.db
def test_propose_into_a_store_without_contributor_is_denied(world: Pool) -> None:
    req = ProposeRequest(store_id=HIDDEN_STORE, kind=MemoryKind.NOTE, title="x")
    with (
        request_tx(world, USER, None) as conn,
        pytest.raises(psycopg.errors.InsufficientPrivilege),
    ):
        repo.remember(conn, req)


@pytest.mark.db
def test_history_and_dependents(world: Pool) -> None:
    ref = SourceRef(uri=f"memory://{ACTIVE}")
    derived = ProposeRequest(
        store_id=STORE,
        kind=MemoryKind.FACT,
        title="derived",
        source_refs=(ref,),
        subject_id=SUBJECT,
        attribute="runbook",
    )
    with request_tx(world, USER, None) as conn:
        child = repo.get(conn, repo.remember(conn, derived).memory_id)
    assert child is not None
    with request_tx(world, USER, None) as conn:
        versions = repo.history(conn, child.id)
        deps = repo.dependents(conn, ACTIVE)
        none_for_child = repo.dependents(conn, child.id)
    with request_tx(world, OTHER, None) as conn:
        reader_hist = repo.history(conn, child.id)
    with request_tx(world, USER, None) as conn:
        unreviewed_hist = repo.history(conn, PROPOSED_BY_OTHER)
    expected = [(1, MemoryOp.PROPOSE, USER)]
    assert [(v.version, v.op, v.actor_id) for v in versions] == expected
    assert [d.id for d in deps] == [child.id]
    assert none_for_child == []
    assert [(v.version, v.op, v.actor_id) for v in reader_hist] == expected
    assert unreviewed_hist == []


@pytest.mark.db
def test_kind_filter_applies_before_the_row_limit(world: Pool, fresh_db: str) -> None:
    with psycopg.connect(fresh_db) as conn:
        conn.execute(
            "INSERT INTO memory (tenant_id, store_id, kind, status, title, created_by)"
            " SELECT %s, %s, 'note', 'active', 'kiwi', %s FROM generate_series(1, 55)",
            (TENANT, STORE, USER),
        )
        conn.execute(
            "INSERT INTO memory"
            " (id, tenant_id, store_id, kind, status, title, source_refs, created_by,"
            " subject_id, attribute)"
            " VALUES ('ffffffff-ffff-ffff-ffff-ffffffffffff', %s, %s, 'fact', 'active', 'kiwi',"
            " '[{\"uri\": \"https://x\"}]', %s, %s, 'color')",
            (TENANT, STORE, USER, SUBJECT),
        )
    active = (MemoryStatus.ACTIVE,)
    with request_tx(world, USER, None) as conn:
        unfiltered = repo.search(conn, "kiwi", None, None, active)
        facts = repo.search(conn, "kiwi", None, [MemoryKind.FACT], active)
    assert len(unfiltered) == 50
    assert [h.id for h in facts] == [uuid.UUID("ffffffff-ffff-ffff-ffff-ffffffffffff")]


def _scalar(url: str, query: str, arg: object) -> Any:  # noqa: ANN401
    with psycopg.connect(url) as conn:
        row = conn.execute(query, (arg,)).fetchone()
    assert row is not None
    return row[0]


def _fact(body: str) -> ProposeRequest:
    return ProposeRequest(
        store_id=STORE,
        kind=MemoryKind.FACT,
        title="Infra owner",
        body=body,
        source_refs=(SourceRef(uri="https://example.com/org"),),
        subject_id=SUBJECT,
        attribute="Owner",
    )


@pytest.mark.db
def test_propose_same_key_same_value_reconfirms(fresh_db: str, world: Pool) -> None:
    with request_tx(world, USER, None) as conn:
        first = repo.remember(conn, _fact("Kim"))
    confirmed = "SELECT last_confirmed_at FROM memory WHERE id = %s"
    before = _scalar(fresh_db, confirmed, first.memory_id)
    with request_tx(world, USER, None) as conn:
        second = repo.remember(conn, _fact("Kim"))
    after = _scalar(fresh_db, confirmed, first.memory_id)
    count = _scalar(fresh_db, "SELECT count(*) FROM memory WHERE subject_id = %s", SUBJECT)
    assert (first.kind, first.status) == ("created", MemoryStatus.PROVISIONAL)
    assert second == ProposeOutcome(
        kind="reconfirmed", memory_id=first.memory_id, status=MemoryStatus.PROVISIONAL
    )
    assert after > before
    assert count == 1


def _post(n: int, author: str) -> Evidence:
    return Evidence(
        uri=f"https://mm.example/devshow/pl/{n}",
        post_id=f"post-{n}",
        author=author,
        author_name=f"name-{author}",
        said_at=datetime(2026, 10, 14, 9, n, tzinfo=UTC),
    )


@pytest.mark.db
def test_agreed_consensus_with_evidence_creates_an_active_row_and_retract_expires_it(
    fresh_db: str, world: Pool
) -> None:
    with request_tx(world, USER, None) as conn:
        made = repo.remember(conn, _fact("Kim"), "agreed", (_post(1, "u1"), _post(2, "u2")))
        gone = repo.retract(conn, STORE, made.memory_id, (_post(3, "u1"),))
    rows = _scalar(
        fresh_db,
        "SELECT jsonb_agg(jsonb_build_array(op, post_id, author, basis) ORDER BY id)"
        " FROM memory_evidence WHERE memory_id = %s",
        made.memory_id,
    )
    assert (made.kind, made.status) == ("created", MemoryStatus.ACTIVE)
    assert gone == ProposeOutcome(
        kind="retracted", memory_id=made.memory_id, status=MemoryStatus.EXPIRED
    )
    assert rows == [
        ["propose", "post-1", "u1", "agreed"],
        ["propose", "post-2", "u2", "agreed"],
        ["retract", "post-3", "u1", "stated"],
    ]


@pytest.mark.db
def test_retracting_a_provisional_row_rejects_it(world: Pool) -> None:
    with request_tx(world, USER, None) as conn:
        made = repo.remember(conn, _fact("Kim"), "stated", (_post(1, "u1"),))
        gone = repo.retract(conn, STORE, made.memory_id, (_post(2, "u1"),))
    assert (made.status, gone.status) == (MemoryStatus.PROVISIONAL, MemoryStatus.REJECTED)


def _valued(body: str, value: str | None) -> ProposeRequest:
    return _fact(body).model_copy(update={"value": value})


@pytest.mark.db
def test_propose_same_key_same_value_in_other_words_reconfirms(fresh_db: str, world: Pool) -> None:
    with request_tx(world, USER, None) as conn:
        first = repo.remember(conn, _valued("Owner is Kim.", " KIM "))
    with request_tx(world, USER, None) as conn:
        again = repo.remember(conn, _valued("Kim owns it these days", "kim"))
        other = repo.remember(conn, _valued("Owner is Lee.", "Lee"))
    stored = _scalar(fresh_db, "SELECT value FROM memory WHERE id = %s", first.memory_id)
    conflict = _scalar(fresh_db, "SELECT conflict_with FROM memory WHERE id = %s", other.memory_id)
    assert again == ProposeOutcome(
        kind="reconfirmed", memory_id=first.memory_id, status=MemoryStatus.PROVISIONAL
    )
    assert stored == "kim"
    assert other == ProposeOutcome(
        kind="challenged",
        memory_id=other.memory_id,
        status=MemoryStatus.CHALLENGER,
        conflict_with=first.memory_id,
    )
    assert conflict == first.memory_id


@pytest.mark.db
def test_a_row_without_a_value_falls_back_to_the_body_hash_and_gets_the_value(
    fresh_db: str, world: Pool
) -> None:
    with request_tx(world, USER, None) as conn:
        old = repo.remember(conn, _valued("Kim", None))
    with request_tx(world, USER, None) as conn:
        reworded = repo.remember(conn, _valued("Kim, as of today", "Kim"))
    with request_tx(world, USER, None) as conn:
        same = repo.remember(conn, _valued("Kim", "Kim"))
    stored = _scalar(fresh_db, "SELECT value FROM memory WHERE id = %s", old.memory_id)
    assert reworded.kind == "challenged"
    assert same == ProposeOutcome(
        kind="reconfirmed", memory_id=old.memory_id, status=MemoryStatus.PROVISIONAL
    )
    assert stored == "kim"


@pytest.mark.db
def test_propose_same_key_other_value_is_a_challenger_beside_the_live_row(
    fresh_db: str, world: Pool
) -> None:
    with request_tx(world, USER, None) as conn:
        first = repo.remember(conn, _fact("Kim"))
    with request_tx(world, USER, None) as conn:
        second = repo.remember(conn, _fact("Lee"))
    with psycopg.connect(fresh_db) as conn:
        row = conn.execute(
            "SELECT conflict_with, supersedes_id FROM memory WHERE id = %s", (second.memory_id,)
        ).fetchone()
    assert (second.kind, second.status) == ("challenged", MemoryStatus.CHALLENGER)
    assert second.memory_id != first.memory_id
    assert row == (first.memory_id, first.memory_id)
