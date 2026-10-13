from nunchi.db import Conn
from nunchi.embed import Embedder

BATCH = 32
_MAX_CHARS = 2000


def embed_missing(conn: Conn, embedder: Embedder, batch: int = BATCH) -> int:
    """Embed up to `batch` live memories that have no vector, a vector from another model, or a
    vector older than the row. Returns how many were stored. EmbedError propagates and nothing
    is written, so the next pass retries the same rows."""
    with conn.transaction():
        rows = conn.execute(
            "SELECT id, title, body, updated_at FROM app_sec.memories_to_embed(%s, %s)",
            (embedder.model, batch),
        ).fetchall()
        if not rows:
            return 0
        texts = [f"{title}\n{body or ''}"[:_MAX_CHARS] for _, title, body, _ in rows]
        vectors = embedder.embed(texts, "document")
        for (memory_id, _, _, updated_at), vector in zip(rows, vectors, strict=True):
            conn.execute(
                "SELECT app_sec.put_embedding(%s, %s, %s::real[], %s)",
                (memory_id, embedder.model, vector, updated_at),
            )
    return len(rows)
