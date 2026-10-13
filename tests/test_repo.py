import uuid

import psycopg
import pytest

from nunchi.db import Pool, request_tx
from nunchi.domain import repo
from nunchi.domain.models import (
    MemoryKind,
    MemoryOp,
    MemoryOrigin,
    MemoryStatus,
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
        repo.propose(conn, req)
    with request_tx(world, USER, None) as conn:
        direct = repo.propose(conn, req)
    assert (direct.status, direct.origin, direct.created_by, direct.on_behalf_of) == (
        MemoryStatus.PROVISIONAL,
        MemoryOrigin.INTERNAL,
        USER,
        None,
    )
    assert direct.version == 1
    with psycopg.connect(fresh_db) as conn:
        tier = conn.execute("SELECT tier::text FROM memory WHERE id = %s", (direct.id,)).fetchone()
    assert tier == ("auto_labeled",)


@pytest.mark.db
def test_propose_as_agent_records_the_delegate(fresh_db: str, world: Pool) -> None:
    with psycopg.connect(fresh_db) as conn:
        conn.execute(
            "UPDATE store_grant SET role = 'contributor' WHERE principal_id = %s", (AGENT,)
        )
    req = ProposeRequest(store_id=STORE, kind=MemoryKind.NOTE, title="by agent")
    with request_tx(world, USER, AGENT) as conn:
        mem = repo.propose(conn, req)
    assert (mem.created_by, mem.on_behalf_of) == (AGENT, USER)
    assert mem.status == MemoryStatus.PROPOSED


@pytest.mark.db
def test_propose_into_a_store_without_contributor_is_denied(world: Pool) -> None:
    req = ProposeRequest(store_id=HIDDEN_STORE, kind=MemoryKind.NOTE, title="x")
    with (
        request_tx(world, USER, None) as conn,
        pytest.raises(psycopg.errors.InsufficientPrivilege),
    ):
        repo.propose(conn, req)


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
        child = repo.propose(conn, derived)
    with request_tx(world, USER, None) as conn:
        versions = repo.history(conn, child.id)
        deps = repo.dependents(conn, ACTIVE)
        none_for_child = repo.dependents(conn, child.id)
    with request_tx(world, OTHER, None) as conn:
        reader_hist = repo.history(conn, child.id)
    with request_tx(world, USER, None) as conn:
        unreviewed_hist = repo.history(conn, PROPOSED_BY_OTHER)
    expected = [(1, MemoryOp.PROPOSE, USER), (1, MemoryOp.AUTO_ACTIVATE, USER)]
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
            " (id, tenant_id, store_id, kind, status, title, source_refs, created_by)"
            " VALUES ('ffffffff-ffff-ffff-ffff-ffffffffffff', %s, %s, 'fact', 'active', 'kiwi',"
            ' \'[{"uri": "https://x"}]\', %s)',
            (TENANT, STORE, USER),
        )
    active = (MemoryStatus.ACTIVE,)
    with request_tx(world, USER, None) as conn:
        unfiltered = repo.search(conn, "kiwi", None, None, active)
        facts = repo.search(conn, "kiwi", None, [MemoryKind.FACT], active)
    assert len(unfiltered) == 50
    assert [h.id for h in facts] == [uuid.UUID("ffffffff-ffff-ffff-ffff-ffffffffffff")]
