"""Document embedding for the harness: what the worker does, with the text chosen per variant."""

from collections.abc import Sequence
from typing import Any, Literal

import psycopg

from nunchi.embed import Embedder, PromptName

Variant = Literal["title", "title+body"]
VARIANTS: tuple[Variant, ...] = ("title", "title+body")
_MAX_CHARS = 2000  # the worker's cut


def embed_documents(conn: psycopg.Connection[Any], embedder: Embedder, variant: Variant) -> int:
    """(Re)embed every live memory as a document, replacing any earlier vector. `conn` must be the
    admin role: put_embedding is a worker function. Returns how many rows were stored."""
    rows = conn.execute(
        "SELECT id, title, body, updated_at FROM memory WHERE status IN ('active', 'provisional')"
        " ORDER BY id"
    ).fetchall()
    if not rows:
        return 0
    texts = [
        (title if variant == "title" else f"{title}\n{body or ''}")[:_MAX_CHARS]
        for _, title, body, _ in rows
    ]
    vectors = embedder.embed(texts, "document")
    for (memory_id, _, _, updated_at), vector in zip(rows, vectors, strict=True):
        conn.execute(
            "SELECT app_sec.put_embedding(%s, %s, %s::real[], %s)",
            (memory_id, embedder.model, vector, updated_at),
        )
    conn.commit()
    return len(rows)


class CachingEmbedder:
    """Remembers every answer, so a sweep that re-embeds the same text pays once."""

    def __init__(self, inner: Embedder) -> None:
        self.model = inner.model
        self._inner = inner
        self._seen: dict[tuple[str, PromptName], list[float]] = {}

    def embed(self, texts: Sequence[str], prompt_name: PromptName) -> list[list[float]]:
        missing = list(dict.fromkeys(t for t in texts if (t, prompt_name) not in self._seen))
        if missing:
            for text, vector in zip(missing, self._inner.embed(missing, prompt_name), strict=True):
                self._seen[text, prompt_name] = vector
        return [self._seen[t, prompt_name] for t in texts]
