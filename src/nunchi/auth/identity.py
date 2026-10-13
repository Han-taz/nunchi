from dataclasses import dataclass
from uuid import UUID

from psycopg.rows import scalar_row

from nunchi.auth.tokens import AuthError, TokenVerifier
from nunchi.db import Pool


@dataclass(frozen=True)
class Identity:
    """The (user, agent) pair a request runs as. agent_id is None for a direct user call."""

    user_id: UUID
    agent_id: UUID | None


def resolve_principal(pool: Pool, tenant_id: UUID, kind: str, external_id: str) -> UUID:
    """Map a verified (issuer tenant, sub) to an active principal id, only through the DB function.
    It returns NULL for unknown, inactive, wrong-kind and other-tenant principals alike."""
    with pool.connection() as conn, conn.cursor(row_factory=scalar_row) as cur:
        principal_id: UUID | None = cur.execute(
            "SELECT app_sec.resolve_principal(%s::uuid, %s::principal_kind, %s)",
            (tenant_id, kind, external_id),
        ).fetchone()
    if principal_id is None:
        msg = "unknown or inactive principal"
        raise AuthError(msg)
    return principal_id


def authenticate(
    pool: Pool,
    verifier: TokenVerifier,
    bearer: str | None,
    agent_token: str | None,
) -> Identity:
    if bearer is None:
        msg = "missing bearer token"
        raise AuthError(msg)
    user = verifier.verify(bearer)
    user_id = resolve_principal(pool, user.tenant_id, "user", user.sub)
    if agent_token is None:
        return Identity(user_id, None)
    agent = verifier.verify(agent_token)
    if agent.tenant_id != user.tenant_id:
        msg = "agent and user belong to different tenants"
        raise AuthError(msg)
    return Identity(user_id, resolve_principal(pool, agent.tenant_id, "agent", agent.sub))
