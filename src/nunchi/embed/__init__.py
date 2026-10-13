"""Client for an OpenAI-compatible embedding endpoint (LiteLLM serving embeddinggemma).

embeddinggemma uses different task prompts for queries and documents, so every call names one:
"document" when embedding memories, "query" when embedding a search or capture text. Any failure
is an EmbedError; callers that serve a user fall back to trigram search instead of failing."""

import logging
from collections.abc import Sequence
from typing import Literal, Protocol

import httpx

from nunchi.config import Settings

log = logging.getLogger(__name__)

PromptName = Literal["query", "document"]


class EmbedError(Exception):
    pass


class EmbedUnavailable(EmbedError):
    """Timeout, connection failure or a non-2xx answer."""


class EmbedBadResponse(EmbedError):
    """A 2xx answer that is not the expected list of vectors of the configured size."""


class Embedder(Protocol):
    model: str

    def embed(self, texts: Sequence[str], prompt_name: PromptName) -> list[list[float]]: ...


class HttpEmbedder:
    def __init__(  # noqa: PLR0913 - one value per setting
        self,
        *,
        base_url: str,
        api_key: str | None,
        model: str,
        dim: int,
        timeout: float,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self.model = model
        self._dim = dim
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        self._client = httpx.Client(
            base_url=base_url.rstrip("/") + "/",
            headers=headers,
            timeout=timeout,
            transport=transport,
        )

    def embed(self, texts: Sequence[str], prompt_name: PromptName) -> list[list[float]]:
        body = {
            "model": self.model,
            "input": list(texts),
            "dimensions": self._dim,
            "prompt_name": prompt_name,
        }
        try:
            response = self._client.post("embeddings", json=body)
            response.raise_for_status()
        except httpx.HTTPError as exc:
            msg = f"embedding request failed: {type(exc).__name__}"
            raise EmbedUnavailable(msg) from exc
        try:
            rows = sorted(response.json()["data"], key=lambda row: row["index"])
            vectors = [[float(x) for x in row["embedding"]] for row in rows]
        except (ValueError, KeyError, TypeError) as exc:
            msg = "embedding response is not an OpenAI-style data list"
            raise EmbedBadResponse(msg) from exc
        if len(vectors) != len(texts) or any(len(v) != self._dim for v in vectors):
            msg = f"expected {len(texts)} vectors of {self._dim} numbers"
            raise EmbedBadResponse(msg)
        return vectors


def embedder_from_settings(settings: Settings) -> HttpEmbedder | None:
    if settings.embedding_base_url is None:
        return None
    key = settings.embedding_api_key
    return HttpEmbedder(
        base_url=settings.embedding_base_url,
        api_key=key.get_secret_value() if key else None,
        model=settings.embedding_model,
        dim=settings.embedding_dim,
        timeout=settings.embedding_timeout,
    )


def embed_query(embedder: Embedder | None, text: str) -> list[float] | None:
    """The query vector, or None when embeddings are off or the service failed."""
    if embedder is None:
        return None
    try:
        return embedder.embed([text], "query")[0]
    except EmbedError as exc:
        log.warning("embedding unavailable, searching by trigram only: %s", exc)
        return None
