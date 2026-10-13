"""Hypothesis tests that drive the HTTP API against random worlds and compare it with a Python
oracle of the visibility rules, then check the metamorphic laws."""

import os
import uuid
from collections.abc import Iterator
from dataclasses import dataclass, replace

import psycopg
import pytest
from fastapi.testclient import TestClient
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from nunchi.api.app import create_app
from nunchi.db import Pool
from tests import jwt_support as j
from tests.conftest import TENANT

pytestmark = pytest.mark.db

settings.register_profile("ci", max_examples=200, deadline=None)
settings.register_profile("nightly", max_examples=3000, deadline=None)
PROFILE = settings(
    settings.get_profile(os.environ.get("NUNCHI_HYPOTHESIS_PROFILE", "ci")),
    suppress_health_check=[HealthCheck.function_scoped_fixture, HealthCheck.too_slow],
)

TENANT_B = uuid.UUID("00000000-0000-0000-0000-0000000000c2")
ROLES = ("reader", "contributor", "curator")
STATUSES = ("proposed", "provisional", "active", "superseded", "rejected", "expired", "deleted")
READABLE = ("active", "provisional", "superseded", "expired")


@dataclass(frozen=True)
class World:
    """Principals are indexed: users 0..U-1, agents U..U+A-1, groups after that."""

    users: int
    agents: int
    groups: int
    stores: int
    active: tuple[bool, ...]
    members: frozenset[tuple[int, int]]  # (group, member)
    grants: frozenset[tuple[int, int, int]]  # (store, principal, role index)
    memories: tuple[tuple[int, str, int, int | None], ...]  # (store, status, creator, delegate)

    def agent(self, i: int) -> int:
        return self.users + i

    def group(self, i: int) -> int:
        return self.users + self.agents + i


@st.composite
def worlds(draw: st.DrawFn) -> World:
    users = draw(st.integers(1, 3))
    agents = draw(st.integers(0, 2))
    groups = draw(st.integers(0, 2))
    stores = draw(st.integers(1, 3))
    total = users + agents + groups
    base = World(users, agents, groups, stores, (), frozenset(), frozenset(), ())
    active = tuple(draw(st.lists(st.booleans(), min_size=total, max_size=total)))
    members = frozenset(
        draw(
            st.lists(
                st.tuples(
                    st.integers(0, groups - 1) if groups else st.nothing(),
                    st.integers(0, users + agents - 1),
                ).map(lambda gm: (base.group(gm[0]), gm[1])),
                max_size=4,
            )
        )
        if groups
        else []
    )
    # one role per (store, principal): the table's primary key
    pairs = st.tuples(st.integers(0, stores - 1), st.integers(0, total - 1))
    chosen = draw(st.dictionaries(pairs, st.integers(0, 2), max_size=8))
    grants = frozenset((s, p, r) for (s, p), r in chosen.items())
    mems = []
    for _ in range(draw(st.integers(0, 6))):
        store = draw(st.integers(0, stores - 1))
        status = draw(st.sampled_from(STATUSES))
        creator = draw(st.integers(0, users + agents - 1))
        delegate = draw(st.integers(0, users - 1)) if creator >= users else None
        mems.append((store, status, creator, delegate))
    return replace(base, active=active, members=members, grants=grants, memories=tuple(mems))


def closure(w: World, p: int) -> set[int]:
    if not w.active[p]:
        return set()
    return {p} | {g for g, m in w.members if m == p and w.active[g]}


def role_of(w: World, p: int, store: int) -> int | None:
    held = [r for s, q, r in w.grants if s == store and q in closure(w, p)]
    return max(held) if held else None


def effective(w: World, user: int, agent: int | None, store: int) -> int | None:
    ur = role_of(w, user, store)
    if agent is None or ur is None:
        return ur
    ar = role_of(w, agent, store)
    return None if ar is None else min(ur, ar)


def visible(w: World, user: int, agent: int | None) -> set[int]:
    out = set()
    for i, (store, status, creator, delegate) in enumerate(w.memories):
        role = effective(w, user, agent, store)
        if role is None:
            continue
        owner = delegate if delegate is not None else creator
        if (
            status in READABLE
            or role == ROLES.index("curator")
            or (status == "proposed" and owner == user)
        ):
            out.add(i)
    return out


@dataclass
class Seeded:
    ids: list[uuid.UUID]
    ext: list[str]
    memory_ids: list[uuid.UUID]
    store_ids: list[uuid.UUID]
    other_user: str


def seed(admin: psycopg.Connection[tuple[object, ...]], w: World) -> Seeded:
    kinds = ["user"] * w.users + ["agent"] * w.agents + ["group"] * w.groups
    ids = [uuid.uuid4() for _ in kinds]
    ext = [f"p-{uuid.uuid4().hex}" for _ in kinds]
    stores = [uuid.uuid4() for _ in range(w.stores)]
    other = f"b-{uuid.uuid4().hex}"
    for pid, kind, e, act in zip(ids, kinds, ext, w.active, strict=True):
        admin.execute(
            "INSERT INTO principal (id, tenant_id, kind, external_id, display_name, active)"
            " VALUES (%s, %s, %s, %s, 'x', %s)",
            (pid, TENANT, kind, e, act),
        )
    admin.execute(
        "INSERT INTO principal (tenant_id, kind, external_id, display_name)"
        " VALUES (%s, 'user', %s, 'b')",
        (TENANT_B, other),
    )
    for i, sid in enumerate(stores):
        admin.execute(
            "INSERT INTO store (id, tenant_id, kind, slug, description)"
            " VALUES (%s, %s, 'team', %s, 'd')",
            (sid, TENANT, f"s{i}-{sid.hex}"),
        )
    for g, m in w.members:
        admin.execute("INSERT INTO group_member VALUES (%s, %s)", (ids[g], ids[m]))
    for s, p, r in w.grants:
        admin.execute(
            "INSERT INTO store_grant (store_id, principal_id, role, tenant_id)"
            " VALUES (%s, %s, %s, %s)",
            (stores[s], ids[p], ROLES[r], TENANT),
        )
    mids = []
    for store, status, creator, delegate in w.memories:
        mid = uuid.uuid4()
        mids.append(mid)
        admin.execute(
            "INSERT INTO memory (id, tenant_id, store_id, kind, status, title, body, created_by,"
            " on_behalf_of) VALUES (%s, %s, %s, 'note', %s, 'zebra', %s, %s, %s)",
            (
                mid,
                TENANT,
                stores[store],
                status,
                None if status == "deleted" else "zebra",
                ids[creator],
                None if delegate is None else ids[delegate],
            ),
        )
    return Seeded(ids, ext, mids, stores, other)


class Api:
    def __init__(self, client: TestClient, s: Seeded, w: World) -> None:
        self.client, self.s, self.w = client, s, w

    def headers(self, user: int, agent: int | None) -> dict[str, str]:
        h = j.auth(self.s.ext[user])
        if agent is not None:
            h["X-Agent-Token"] = j.mint(self.s.ext[agent])
        return h

    def get_visible(self, user: int, agent: int | None) -> set[int]:
        h = self.headers(user, agent)
        out = set()
        for i, mid in enumerate(self.s.memory_ids):
            status = self.client.get(f"/v1/memories/{mid}", headers=h).status_code
            assert status in (200, 404)
            if status == 200:
                out.add(i)
        return out

    def search_visible(self, user: int, agent: int | None) -> set[int]:
        res = self.client.get(
            "/v1/search",
            params={
                "q": "zebra",
                "status": list(STATUSES),
                "store": [str(s) for s in self.s.store_ids],
            },
            headers=self.headers(user, agent),
        )
        assert res.status_code == 200
        index = {mid: i for i, mid in enumerate(self.s.memory_ids)}
        return {index[uuid.UUID(hit["id"])] for hit in res.json()}


@pytest.fixture
def api_env(
    seeded: str, fresh_db: str, pool: Pool
) -> Iterator[tuple[TestClient, psycopg.Connection[tuple[object, ...]]]]:
    admin = psycopg.connect(fresh_db, autocommit=True)
    admin.execute("INSERT INTO tenant (id, name) VALUES (%s, 'tenant-b')", (TENANT_B,))
    client = TestClient(create_app(pool, j.verifier(TENANT, TENANT_B)))
    yield client, admin
    admin.close()


@settings(PROFILE)
@given(w=worlds(), data=st.data())
def test_api_matches_the_oracle_and_the_laws(
    api_env: tuple[TestClient, psycopg.Connection[tuple[object, ...]]],
    w: World,
    data: st.DataObject,
) -> None:
    client, admin = api_env
    s = seed(admin, w)
    api = Api(client, s, w)
    agents = [None, *[w.agent(i) for i in range(w.agents)]]
    for u in range(w.users):
        if not w.active[u]:
            for a in agents:
                assert client.get("/v1/stores", headers=api.headers(u, a)).status_code == 401
            continue
        base = api.get_visible(u, None)
        assert base == visible(w, u, None)
        assert api.search_visible(u, None) == base
        for a in agents[1:]:
            assert a is not None
            if not w.active[a]:
                assert client.get("/v1/stores", headers=api.headers(u, a)).status_code == 401
                continue
            with_agent = api.get_visible(u, a)
            assert with_agent == visible(w, u, a)
            assert api.search_visible(u, a) == with_agent
            assert with_agent <= base  # adding an agent never increases visibility
    # another tenant sees nothing
    h_b = {"Authorization": f"Bearer {j.mint(s.other_user, iss=j.ISSUER_B)}"}
    for mid in s.memory_ids:
        assert client.get(f"/v1/memories/{mid}", headers=h_b).status_code == 404
    found = client.get("/v1/search", params={"q": "zebra", "status": list(STATUSES)}, headers=h_b)
    assert found.json() == []
    # revoking a grant never increases visibility, and the oracle still agrees
    if w.grants:
        victim = data.draw(st.sampled_from(sorted(w.grants)))
        for u in range(w.users):
            if w.active[u]:
                before = api.get_visible(u, None)
                break
        else:
            return
        admin.execute(
            "DELETE FROM store_grant WHERE store_id = %s AND principal_id = %s",
            (s.store_ids[victim[0]], s.ids[victim[1]]),
        )
        w2 = replace(w, grants=w.grants - {victim})
        after = api.get_visible(u, None)
        assert after <= before
        assert after == visible(w2, u, None)
