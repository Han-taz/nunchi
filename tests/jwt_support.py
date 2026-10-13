import base64
import hashlib
import hmac
import json
import time
import uuid
from typing import Any

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from jwt import PyJWKClient
from jwt.algorithms import RSAAlgorithm

from nunchi.auth.tokens import IssuerConfig, OidcSettings, TokenVerifier

ISSUER_A = "https://idp-a.test"
ISSUER_B = "https://idp-b.test"
KID = "key-1"
AUDIENCE = "memory-core"

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
PUBLIC_PEM = KEY.public_key().public_bytes(
    serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
)
PRIVATE_PEM = KEY.private_bytes(
    serialization.Encoding.PEM,
    serialization.PrivateFormat.PKCS8,
    serialization.NoEncryption(),
)


def _jwks() -> dict[str, Any]:
    jwk = json.loads(RSAAlgorithm.to_jwk(KEY.public_key()))
    return {"keys": [{**jwk, "kid": KID, "use": "sig", "alg": "RS256"}]}


class StaticJwks(PyJWKClient):
    """A JWKS client that never touches the network."""

    def __init__(self) -> None:
        super().__init__("https://unused.test/jwks")

    def fetch_data(self) -> Any:  # noqa: ANN401
        return _jwks()


def verifier(tenant_a: uuid.UUID, tenant_b: uuid.UUID | None = None) -> TokenVerifier:
    issuers = {ISSUER_A: IssuerConfig(tenant_id=tenant_a, jwks_url="https://unused.test/a")}
    if tenant_b is not None:
        issuers[ISSUER_B] = IssuerConfig(tenant_id=tenant_b, jwks_url="https://unused.test/b")
    settings = OidcSettings(issuers=issuers)
    return TokenVerifier(settings, {iss: StaticJwks() for iss in issuers})


def mint(  # noqa: PLR0913
    sub: str,
    *,
    iss: str = ISSUER_A,
    aud: str = AUDIENCE,
    exp_in: int = 300,
    nbf_in: int | None = None,
    kid: str | None = KID,
    alg: str = "RS256",
    key: Any = PRIVATE_PEM,  # noqa: ANN401
    drop: tuple[str, ...] = (),
) -> str:
    now = int(time.time())
    claims: dict[str, Any] = {"iss": iss, "aud": aud, "sub": sub, "iat": now, "exp": now + exp_in}
    if nbf_in is not None:
        claims["nbf"] = now + nbf_in
    for name in drop:
        claims.pop(name)
    headers = {"kid": kid} if kid is not None else {}
    return jwt.encode(claims, key, algorithm=alg, headers=headers)


def auth(sub: str, **kw: Any) -> dict[str, str]:  # noqa: ANN401
    return {"Authorization": f"Bearer {mint(sub, **kw)}"}


def hs256_with_public_key(sub: str) -> str:
    """The classic confusion attack: HS256 keyed with the RSA public key PEM. PyJWT refuses to
    sign this, so the token is assembled by hand."""

    def b64(raw: bytes) -> str:
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

    now = int(time.time())
    header = b64(json.dumps({"alg": "HS256", "typ": "JWT", "kid": KID}).encode())
    body = b64(
        json.dumps(
            {"iss": ISSUER_A, "aud": AUDIENCE, "sub": sub, "iat": now, "exp": now + 300}
        ).encode()
    )
    sig = hmac.new(PUBLIC_PEM, f"{header}.{body}".encode(), hashlib.sha256).digest()
    return f"{header}.{body}.{b64(sig)}"
