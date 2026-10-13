from collections.abc import Callable
from dataclasses import dataclass
from typing import Annotated

import psycopg
from fastapi import Depends, Header, Request

from nunchi.auth.identity import Identity, authenticate
from nunchi.auth.tokens import AuthError, TokenVerifier
from nunchi.db import Conn, Pool, request_tx

SERIALIZATION_ATTEMPTS = 3


def _bearer(authorization: str) -> str:
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        msg = "malformed Authorization header"
        raise AuthError(msg)
    return token.strip()


def identity(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
    x_agent_token: Annotated[str | None, Header()] = None,
) -> Identity:
    pool: Pool = request.app.state.pool
    verifier: TokenVerifier = request.app.state.verifier
    bearer = None if authorization is None else _bearer(authorization)
    return authenticate(pool, verifier, bearer, x_agent_token)


@dataclass(frozen=True)
class Runner:
    """Runs one unit of work as the caller, retrying a transaction the server aborted with 40001."""

    pool: Pool
    who: Identity

    def __call__[T](self, work: Callable[[Conn], T]) -> T:
        for _ in range(SERIALIZATION_ATTEMPTS - 1):
            try:
                return self._once(work)
            except psycopg.errors.SerializationFailure:
                continue
        return self._once(work)

    def _once[T](self, work: Callable[[Conn], T]) -> T:
        with request_tx(self.pool, self.who.user_id, self.who.agent_id) as conn:
            return work(conn)


def runner(request: Request, who: Annotated[Identity, Depends(identity)]) -> Runner:
    return Runner(request.app.state.pool, who)
