import base64
import json
import uuid
from collections.abc import Callable

import pytest

from nunchi.auth.tokens import AuthError, IssuerConfig, OidcSettings, TokenVerifier
from tests import jwt_support as j

TENANT = uuid.UUID("00000000-0000-0000-0000-0000000000c1")


def _none_alg_token() -> str:
    def enc(obj: dict[str, object]) -> str:
        return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b"=").decode()

    header = enc({"alg": "none", "typ": "JWT", "kid": j.KID})
    body = enc({"iss": j.ISSUER_A, "aud": j.AUDIENCE, "sub": "x", "exp": 4_000_000_000})
    return f"{header}.{body}."


def test_valid_token_yields_subject_and_the_issuers_tenant() -> None:
    subject = j.verifier(TENANT).verify(j.mint("alice"))
    assert (subject.sub, subject.tenant_id) == ("alice", TENANT)


FAILURES: dict[str, Callable[[], str]] = {
    "expired": lambda: j.mint("a", exp_in=-10),
    "wrong audience": lambda: j.mint("a", aud="other"),
    "unknown issuer": lambda: j.mint("a", iss="https://evil.test"),
    "not yet valid": lambda: j.mint("a", nbf_in=600),
    "unknown kid": lambda: j.mint("a", kid="nope"),
    "no kid": lambda: j.mint("a", kid=None),
    "alg none": _none_alg_token,
    "hs256 signed with the public key": lambda: j.hs256_with_public_key("a"),
    "signed by another key": lambda: j.mint("a", key=j.OTHER_KEY),
    "no sub": lambda: j.mint("a", drop=("sub",)),
    "no exp": lambda: j.mint("a", drop=("exp",)),
    "empty sub": lambda: j.mint(""),
    "garbage": lambda: "not-a-jwt",
}


@pytest.mark.parametrize("name", sorted(FAILURES))
def test_bad_token_is_rejected(name: str) -> None:
    with pytest.raises(AuthError):
        j.verifier(TENANT).verify(FAILURES[name]())


def test_oidc_settings_read_the_issuer_map_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(
        "NUNCHI_OIDC_ISSUERS",
        json.dumps({"https://i": {"tenant_id": str(TENANT), "jwks_url": "https://i/jwks"}}),
    )
    settings = OidcSettings()
    assert settings.issuers["https://i"].tenant_id == TENANT
    assert settings.audience == "memory-core"


def test_default_verifier_builds_one_jwks_client_per_issuer() -> None:
    settings = OidcSettings(
        issuers={"https://i": IssuerConfig(tenant_id=TENANT, jwks_url="https://i/j")}
    )
    with pytest.raises(AuthError):
        TokenVerifier(settings).verify("not-a-jwt")
