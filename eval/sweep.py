"""Search sweep: ingest once, then score the queries over a grid of search settings.

The vector floor and the RRF k are arguments of app_sec.search; the embed text is what the
worker stores per memory. The grid shows which defaults in nunchi.config to keep."""

import itertools
from typing import Any

import psycopg

from eval import score
from eval.corpus import Message, Query
from eval.db import fresh_database, superuser_url
from eval.embedding import VARIANTS, CachingEmbedder, embed_documents
from eval.run import replay, run_search
from eval.score import Outcome
from nunchi.config import Settings
from nunchi.db import open_pool
from nunchi.embed import Embedder
from nunchi.extract import Extractor, ValueJudge

FLOORS = (0.2, 0.3, 0.4, 0.5)
RRF_KS = (20, 60)


def run_sweep(  # noqa: PLR0913, PLR0917 - one run's inputs
    admin_url: str,
    extractor: Extractor,
    messages: list[Message],
    queries: list[Query],
    embedder: Embedder,
    judge: ValueJudge | None = None,
) -> list[dict[str, Any]]:
    cached = CachingEmbedder(embedder)
    rows: list[dict[str, Any]] = []
    with fresh_database(admin_url) as app_url:
        pool = open_pool(Settings(database_url=app_url, pool_max_size=2))
        try:
            outcomes: list[Outcome] = replay(pool, extractor, messages, cached, judge)
            rows.append(_row(pool, queries, outcomes, None, "trigram", None, None))
            with psycopg.connect(superuser_url(admin_url, app_url)) as admin:
                for variant in VARIANTS:
                    embed_documents(admin, cached, variant)
                    for floor, k in itertools.product(FLOORS, RRF_KS):
                        rows.append(_row(pool, queries, outcomes, cached, variant, floor, k))
        finally:
            pool.close()
    return rows


def _row(  # noqa: PLR0913, PLR0917 - one grid cell
    pool: Any,  # noqa: ANN401
    queries: list[Query],
    outcomes: list[Outcome],
    embedder: Embedder | None,
    embed_text: str,
    floor: float | None,
    k: int | None,
) -> dict[str, Any]:
    kwargs: dict[str, Any] = (
        {} if floor is None or k is None else {"vector_floor": floor, "rrf_k": k}
    )
    searched = run_search(pool, queries, outcomes, embedder, **kwargs)
    recall = score.search_recall([r["rank"] for r in searched])
    return {"embed_text": embed_text, "floor": floor, "k": k, **recall}


def sweep_table(rows: list[dict[str, Any]]) -> str:
    head = f"{'embed text':<12}{'floor':>6}{'k':>5}{'recall@1':>10}{'recall@5':>10}"
    body = [
        f"{r['embed_text']:<12}{r['floor'] if r['floor'] is not None else '-':>6}"
        f"{r['k'] if r['k'] is not None else '-':>5}{r['recall@1']:>10}{r['recall@5']:>10}"
        for r in rows
    ]
    return "\n".join([head, *body])
