import uuid

import psycopg
import pytest

from nunchi.auth.identity import Identity, authenticate, resolve_principal
from nunchi.auth.tokens import AuthError
from nunchi.db import Pool
from tests import jwt_support as j
from tests.conftest import AGENT, OTHER, TENANT, USER

pytestmark = pytest.mark.db

TENANT_B = uuid.UUID("00000000-0000-0000-0000-0000000000c2")


def test_user_and_agent_resolve_to_their_ids(pool: Pool) -> None:
    who = authenticate(pool, j.verifier(TENANT), j.mint(str(USER)), j.mint(str(AGENT)))
    assert who == Identity(USER, AGENT)
    assert authenticate(pool, j.verifier(TENANT), j.mint(str(OTHER)), None) == Identity(OTHER, None)


def test_resolve_principal_goes_through_the_database_function(pool: Pool) -> None:
    assert resolve_principal(pool, TENANT, "user", str(USER)) == USER
    with pytest.raises(AuthError):
        resolve_principal(pool, TENANT, "agent", str(USER))
    with pytest.raises(AuthError):
        resolve_principal(pool, TENANT_B, "user", str(USER))
    with pytest.raises(AuthError):
        resolve_principal(pool, TENANT, "user", "nobody")


def test_inactive_principal_is_rejected(pool: Pool, fresh_db: str) -> None:
    with psycopg.connect(fresh_db) as admin:
        admin.execute("UPDATE principal SET active = false WHERE id = %s", (USER,))
    with pytest.raises(AuthError):
        authenticate(pool, j.verifier(TENANT), j.mint(str(USER)), None)


@pytest.mark.parametrize(
    ("bearer", "agent"),
    [
        (None, None),
        ("junk", None),
        (j.mint(str(USER)), "junk"),
        (j.mint(str(USER)), j.mint(str(OTHER))),
        (j.mint(str(AGENT)), None),
        (j.mint(str(USER), iss=j.ISSUER_B), None),
        (j.mint(str(USER)), j.mint(str(AGENT), iss=j.ISSUER_B)),
    ],
)
def test_authentication_failures(pool: Pool, bearer: str | None, agent: str | None) -> None:
    with pytest.raises(AuthError):
        authenticate(pool, j.verifier(TENANT, TENANT_B), bearer, agent)


def test_the_issuer_alone_picks_the_tenant(pool: Pool) -> None:
    # same sub, two issuers: only the issuer mapped to the sub's tenant resolves it
    verifier = j.verifier(TENANT, TENANT_B)
    assert authenticate(pool, verifier, j.mint(str(USER)), None).user_id == USER
    with pytest.raises(AuthError):
        authenticate(pool, verifier, j.mint(str(USER), iss=j.ISSUER_B), None)
