"""Bearer JWT verification. The signing key comes from the issuer's JWKS, never from the token."""

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Annotated
from uuid import UUID

import jwt
from jwt import PyJWKClient
from pydantic import BaseModel, ConfigDict, Field
from pydantic_settings import BaseSettings, SettingsConfigDict

ALGORITHMS = ("RS256", "ES256")


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
            iss: PyJWKClient(cfg.jwks_url, cache_keys=True, lifespan=settings.jwks_lifespan_seconds)
            for iss, cfg in settings.issuers.items()
        }

    def verify(self, token: str) -> Subject:
        """Check signature, algorithm, iss, aud, exp and nbf. Raise AuthError on any failure."""
        try:
            # the unverified iss only selects which JWKS to use; decode() then enforces it
            iss = jwt.decode(token, options={"verify_signature": False}).get("iss")
            if not isinstance(iss, str) or iss not in self._settings.issuers:
                msg = "unknown issuer"
                raise AuthError(msg)
            key = self._jwks[iss].get_signing_key_from_jwt(token).key
            claims = jwt.decode(
                token,
                key,
                algorithms=list(ALGORITHMS),
                audience=self._settings.audience,
                issuer=iss,
                options={"require": ["exp", "iss", "aud", "sub"]},
            )
        except jwt.PyJWTError as exc:
            raise AuthError(type(exc).__name__) from exc
        sub = claims["sub"]
        if not isinstance(sub, str) or not sub:
            msg = "sub must be a non-empty string"
            raise AuthError(msg)
        return Subject(sub=sub, tenant_id=self._settings.issuers[iss].tenant_id)
