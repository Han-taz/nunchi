import json

import httpx
import pytest
from pydantic import ValidationError

from nunchi.config import Settings
from nunchi.embed import (
    EmbedBadResponse,
    EmbedUnavailable,
    HttpEmbedder,
    embed_query,
    embedder_from_settings,
)
from tests.embed_fake import DIM, DownEmbedder


def embedder(handler: httpx.MockTransport, key: str | None = "k") -> HttpEmbedder:
    return HttpEmbedder(
        base_url="https://llm.example/v1",
        api_key=key,
        model="embeddinggemma-2",
        dim=DIM,
        timeout=1.0,
        transport=handler,
    )


def ok(vectors: list[list[float]]) -> httpx.MockTransport:
    def handle(request: httpx.Request) -> httpx.Response:
        data = [{"index": i, "embedding": v} for i, v in reversed(list(enumerate(vectors)))]
        return httpx.Response(200, json={"data": data})

    return httpx.MockTransport(handle)


def test_request_body_and_headers_match_the_litellm_contract() -> None:
    seen: list[httpx.Request] = []

    def handle(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"data": [{"index": 0, "embedding": [0.5] * DIM}]})

    out = embedder(httpx.MockTransport(handle)).embed(["배포 절차"], "document")
    assert out == [[0.5] * DIM]
    assert str(seen[0].url) == "https://llm.example/v1/embeddings"
    assert seen[0].headers["authorization"] == "Bearer k"
    assert json.loads(seen[0].content) == {
        "model": "embeddinggemma-2",
        "input": ["배포 절차"],
        "dimensions": 512,
        "prompt_name": "document",
    }


def test_vectors_come_back_in_input_order() -> None:
    first, second = [1.0] + [0.0] * (DIM - 1), [0.0, 1.0] + [0.0] * (DIM - 2)
    assert embedder(ok([first, second])).embed(["a", "b"], "query") == [first, second]


def test_no_key_means_no_authorization_header() -> None:
    seen: list[httpx.Request] = []

    def handle(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"data": [{"index": 0, "embedding": [0.0] * DIM}]})

    embedder(httpx.MockTransport(handle), key=None).embed(["a"], "query")
    assert "authorization" not in seen[0].headers


@pytest.mark.parametrize("status", [401, 500])
def test_http_errors_are_unavailable(status: int) -> None:
    transport = httpx.MockTransport(lambda request: httpx.Response(status))
    with pytest.raises(EmbedUnavailable):
        embedder(transport).embed(["a"], "query")


def test_timeout_is_unavailable() -> None:
    def handle(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("slow", request=request)

    with pytest.raises(EmbedUnavailable):
        embedder(httpx.MockTransport(handle)).embed(["a"], "query")


@pytest.mark.parametrize(
    "payload",
    [{"oops": 1}, {"data": [{"index": 0, "embedding": [0.1, 0.2]}]}, {"data": []}],
)
def test_malformed_or_wrong_size_answers_are_bad_responses(payload: dict[str, object]) -> None:
    transport = httpx.MockTransport(lambda request: httpx.Response(200, json=payload))
    with pytest.raises(EmbedBadResponse):
        embedder(transport).embed(["a"], "query")


def test_embed_query_swallows_failures() -> None:
    assert embed_query(DownEmbedder(), "x") is None
    assert embed_query(None, "x") is None


def test_unset_or_blank_base_url_disables_embeddings() -> None:
    assert embedder_from_settings(Settings(database_url="postgres://h/db")) is None
    blank = Settings(database_url="postgres://h/db", embedding_base_url="", embedding_api_key="")
    assert (blank.embedding_base_url, blank.embedding_api_key) == (None, None)
    assert embedder_from_settings(blank) is None


def test_settings_build_an_embedder_with_the_defaults() -> None:
    settings = Settings(
        database_url="postgres://h/db",
        embedding_base_url="https://llm.example/v1",
        embedding_api_key="secret-key",
    )
    built = embedder_from_settings(settings)
    assert built is not None
    assert built.model == "embeddinggemma-2"
    assert settings.embedding_dim == 512
    assert (
        Settings.model_validate({"database_url": "x", "embedding_dim": "512"}).embedding_dim == 512
    )
    assert "secret-key" not in repr(settings)


def test_a_dimension_the_column_cannot_hold_is_rejected() -> None:
    with pytest.raises(ValidationError, match="embedding_dim"):
        Settings.model_validate({"database_url": "x", "embedding_dim": 768})
