import base64
import http.server
import json
import threading
import uuid
from collections.abc import Callable, Iterator
from http.client import BadStatusLine
from typing import Any

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec

from nunchi.auth.tokens import (
    MAX_TOKEN_CHARS,
    AuthError,
    IssuerConfig,
    OidcSettings,
    TokenVerifier,
)
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
    "es256 token naming an rsa kid": lambda: j.mint(
        "a", alg="ES256", key=ec.generate_private_key(ec.SECP256R1())
    ),
    "oversized": lambda: j.mint("a" * MAX_TOKEN_CHARS),
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


class _Broken(j.StaticJwks):
    def __init__(self, exc: Exception) -> None:
        super().__init__()
        self._exc = exc

    def fetch_data(self) -> Any:  # noqa: ANN401
        raise self._exc


@pytest.mark.parametrize(
    "exc",
    [
        json.JSONDecodeError("Expecting value", "<html>", 0),
        TimeoutError("read timed out"),
        BadStatusLine("garbage"),
        UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid start byte"),
    ],
    ids=lambda e: type(e).__name__,
)
def test_jwks_fetch_failure_is_an_auth_error(exc: Exception) -> None:
    settings = OidcSettings(
        issuers={j.ISSUER_A: IssuerConfig(tenant_id=TENANT, jwks_url="https://unused.test/a")}
    )
    verifier = TokenVerifier(settings, {j.ISSUER_A: _Broken(exc)})
    with pytest.raises(AuthError):
        verifier.verify(j.mint("alice"))


def test_oversized_token_is_rejected_before_any_jwks_fetch() -> None:
    settings = OidcSettings(
        issuers={j.ISSUER_A: IssuerConfig(tenant_id=TENANT, jwks_url="https://unused.test/a")}
    )
    verifier = TokenVerifier(settings, {j.ISSUER_A: _Broken(AssertionError("fetched"))})
    with pytest.raises(AuthError, match="too large"):
        verifier.verify("x" * (MAX_TOKEN_CHARS + 1))


def test_token_at_the_size_limit_is_still_parsed() -> None:
    with pytest.raises(AuthError, match="not verified"):
        j.verifier(TENANT).verify("x" * MAX_TOKEN_CHARS)


@pytest.fixture
def jwks_server() -> Iterator[Callable[[bytes], str]]:
    servers: list[http.server.HTTPServer] = []

    def serve(body: bytes) -> str:
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args: object) -> None:
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        servers.append(server)
        return f"http://127.0.0.1:{server.server_port}/jwks"

    yield serve
    for server in servers:
        server.shutdown()
        server.server_close()


def test_non_json_jwks_over_http_is_an_auth_error(jwks_server: Callable[[bytes], str]) -> None:
    url = jwks_server(b"<html>502 bad gateway</html>")
    settings = OidcSettings(issuers={j.ISSUER_A: IssuerConfig(tenant_id=TENANT, jwks_url=url)})
    with pytest.raises(AuthError):
        TokenVerifier(settings).verify(j.mint("alice"))


def test_jwks_timeout_comes_from_settings_and_defaults_to_three_seconds() -> None:
    issuers = {j.ISSUER_A: IssuerConfig(tenant_id=TENANT, jwks_url="https://i/jwks")}
    assert OidcSettings(issuers=issuers).jwks_timeout_seconds == 3.0
    custom = TokenVerifier(OidcSettings(issuers=issuers, jwks_timeout_seconds=1.5))
    client = custom._jwks[j.ISSUER_A]
    assert isinstance(client, jwt.PyJWKClient)
    assert client.timeout == 1.5
