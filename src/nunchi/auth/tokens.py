"""Bearer JWT verification. The signing key comes from the issuer's JWKS, never from the token."""

from collections.abc import Mapping
from dataclasses import dataclass
from http.client import HTTPException
from typing import Annotated, Any
from uuid import UUID

import jwt
from jwt import PyJWKClient
from pydantic import BaseModel, ConfigDict, Field
from pydantic_settings import BaseSettings, SettingsConfigDict

ALGORITHMS = ("RS256", "ES256")
MAX_TOKEN_CHARS = 8192

# What the verifier can raise on attacker-controlled input or a hostile JWKS: PyJWT's own errors
# (which include the JWKS client's), TypeError for a key of the wrong type for the token's alg
# (ES256 token naming an RSA kid), ValueError for undecodable or non-JSON bodies, and the socket
# and HTTP errors a JWKS fetch can hit that PyJWKClient does not wrap (read timeout, bad status
# line).
_VERIFY_ERRORS = (jwt.PyJWTError, TypeError, ValueError, OSError, HTTPException)


class AuthError(Exception):
    """The caller could not be authenticated. The message is for logs, not for the response."""


class IssuerConfig(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    tenant_id: UUID
    jwks_url: str


class OidcSettings(BaseSettings):
    """NUNCHI_OIDC_ISSUERS is JSON: {"<iss>": {"tenant_id": "<uuid>", "jwks_url": "<url>"}}.

    The issuer decides the tenant. No claim in the token can choose one.
    """

    model_config = SettingsConfigDict(env_prefix="NUNCHI_OIDC_", frozen=True, extra="forbid")

    issuers: Annotated[dict[str, IssuerConfig], Field(min_length=1)]
    audience: str = "memory-core"
    jwks_lifespan_seconds: Annotated[int, Field(ge=1)] = 300
    jwks_timeout_seconds: Annotated[float, Field(gt=0)] = 3.0


@dataclass(frozen=True)
class Subject:
    """A verified token's identity: who it names and in which tenant."""

    sub: str
    tenant_id: UUID


class TokenVerifier:
    def __init__(
        self, settings: OidcSettings, jwks: Mapping[str, PyJWKClient] | None = None
    ) -> None:
        self._settings = settings
        self._jwks = jwks or {
            iss: PyJWKClient(
                cfg.jwks_url,
                cache_keys=True,
                lifespan=settings.jwks_lifespan_seconds,
                timeout=settings.jwks_timeout_seconds,
            )
            for iss, cfg in settings.issuers.items()
        }

    def _verify_against_issuers(self, token: str) -> tuple[dict[str, Any], str]:
        """Accept the token only if some configured issuer's JWKS verifies it and `iss` equals that
        issuer. The token's own claims are never read before a signature has been checked."""
        for iss, client in self._jwks.items():
            try:
                key = client.get_signing_key_from_jwt(token).key
                claims = jwt.decode(
                    token,
                    key,
                    algorithms=list(ALGORITHMS),
                    audience=self._settings.audience,
                    issuer=iss,
                    options={"require": ["exp", "iss", "aud", "sub"]},
                )
            except _VERIFY_ERRORS:
                continue
            return claims, iss
        msg = "token not verified by any configured issuer"
        raise AuthError(msg)

    def verify(self, token: str) -> Subject:
        """Check signature, algorithm, iss, aud, exp and nbf. Raise AuthError on any failure."""
        if len(token) > MAX_TOKEN_CHARS:
            msg = "token too large"
            raise AuthError(msg)
        claims, iss = self._verify_against_issuers(token)
        sub = claims["sub"]
        if not isinstance(sub, str) or not sub:
            msg = "sub must be a non-empty string"
            raise AuthError(msg)
        return Subject(sub=sub, tenant_id=self._settings.issuers[iss].tenant_id)
