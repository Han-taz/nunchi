"""Memory-quality harness: python -m eval.run --db postgresql://postgres:postgres@host/postgres

Replays eval/corpus through the real capture() on a throwaway database and scores the result.
--extractor claude (default) needs ANTHROPIC_API_KEY; --extractor fake uses the gold oracle."""

import argparse
import json
import os
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from uuid import UUID

from eval import score
from eval.corpus import Message, Query, load_messages, load_queries
from eval.db import CONTRIBUTOR, CURATORS, STORE, fresh_database
from eval.oracle import OracleExtractor
from eval.score import Outcome
from nunchi.capture import (
    CaptureContext,
    Created,
    Reconfirmed,
    Rejected,
    capture,
)
from nunchi.config import Settings
from nunchi.db import Conn, Pool, open_pool, request_tx
from nunchi.domain import repo
from nunchi.domain.models import MemoryOrigin, MemoryStatus, SourceRef
from nunchi.extract import ExtractionError, Extractor, NullExtractor, build_extractor

RESULTS = Path(__file__).parent / "results"
LIVE = (MemoryStatus.ACTIVE, MemoryStatus.PROVISIONAL)
SEARCH_DEPTH = 5


def _describe(conn: Conn, outcome_id: UUID) -> tuple[str, UUID | None, UUID | None]:
    row = conn.execute(
        "SELECT kind, subject_id, conflict_with FROM memory WHERE id = %s", (outcome_id,)
    ).fetchone()
    assert row is not None  # noqa: S101 - the row was just written in this transaction
    return str(row[0]), row[1], row[2]  # type: ignore[return-value]


def replay_one(pool: Pool, extractor: Extractor, msg: Message) -> Outcome:
    context = CaptureContext(
        store_id=STORE,
        origin=MemoryOrigin.EXTERNAL,
        source_refs=(SourceRef(uri=f"https://eval.invalid/{msg.id}", system="slack"),),
        today=msg.today,
    )
    try:
        with request_tx(pool, CONTRIBUTOR, None) as conn:
            result = capture(conn, extractor, msg.filled, context)
            if isinstance(result, Created | Reconfirmed):
                db_kind, subject_id, conflict = _describe(conn, result.memory_id)
    except ExtractionError:
        return Outcome(message=msg, result="error")
    if isinstance(result, Created):
        verdict = _approve(pool, result) if result.status is MemoryStatus.PROPOSED else "active"
        return Outcome(
            message=msg,
            result="created",
            memory_id=result.memory_id,
            db_kind=db_kind,
            subject_id=subject_id,
            conflicted=conflict is not None,
            verdict=verdict,
        )
    if isinstance(result, Reconfirmed):
        return Outcome(
            message=msg,
            result="reconfirmed",
            memory_id=result.memory_id,
            db_kind=db_kind,
            subject_id=subject_id,
        )
    return Outcome(message=msg, result="rejected" if isinstance(result, Rejected) else "skipped")


def _approve(pool: Pool, created: Created) -> str:
    """Curators accept the proposal in turn, as curators who agree with every update would.
    Returns the last answer of app_sec.decide; 'active' means the memory went live."""
    verdict = "pending"
    for curator in CURATORS:
        with request_tx(pool, curator, None) as conn:
            memory = repo.get(conn, created.memory_id)
            assert memory is not None  # noqa: S101 - a curator of the store can read its proposals
            verdict = repo.decide(conn, created.memory_id, None, "approve", memory.version)
        if verdict == "active":
            break
    return verdict


def run_search(pool: Pool, queries: list[Query], outcomes: list[Outcome]) -> list[dict[str, Any]]:
    mapping = score.gold_by_db_id(outcomes)
    rows = []
    for q in queries:
        with request_tx(pool, CONTRIBUTOR, None) as conn:
            hits = repo.search(conn, q.query, [STORE], None, LIVE)[:SEARCH_DEPTH]
        rank = score.search_ranks(q, [h.id for h in hits], mapping)
        rows.append({"id": q.id, "query": q.query, "gold": list(q.gold), "rank": rank})
    return rows


def run_eval(
    admin_url: str, extractor: Extractor, messages: list[Message], queries: list[Query]
) -> dict[str, Any]:
    with fresh_database(admin_url) as app_url:
        pool = open_pool(Settings(database_url=app_url, pool_max_size=2))
        try:
            outcomes = [replay_one(pool, extractor, m) for m in messages]
            searched = run_search(pool, queries, outcomes)
            with request_tx(pool, CURATORS[0], None) as conn:
                row = conn.execute("SELECT count(*) FROM entity").fetchone()
            assert row is not None  # noqa: S101 - count(*) always returns one row
            entity_rows = int(row[0])  # type: ignore[call-overload]
        finally:
            pool.close()
    return {
        "messages": len(messages),
        "queries": len(queries),
        "extraction": score.extraction(outcomes),
        "kind_accuracy": score.kind_accuracy(outcomes),
        "relation_accuracy": score.relation_accuracy(outcomes),
        "fragmentation": score.fragmentation(outcomes, entity_rows),
        "search": score.search_recall([r["rank"] for r in searched]),
        "search_misses": [r for r in searched if r["rank"] is None],
        "outcomes": [
            {"id": o.message.id, "gold": o.message.relation, "result": o.result, "pred": o.relation}
            for o in outcomes
        ],
    }


def table(report: dict[str, Any]) -> str:
    ex, rel, frag, srch = (
        report["extraction"],
        report["relation_accuracy"],
        report["fragmentation"],
        report["search"],
    )
    rows = [
        ("extraction precision", ex["precision"]),
        ("extraction recall", ex["recall"]),
        ("kind accuracy", report["kind_accuracy"]),
        ("same detection", rel["same"]),
        ("update detection", rel["update"]),
        ("new not mistaken", rel["new"]),
        ("entity rows / gold entity", frag["mean_rows_per_gold_entity"]),
        ("worst entity fragmentation", frag["worst"]),
        ("secret leaks", f"{ex['secret_leaks']}/{ex['secrets']}"),
        ("extractor errors", ex["errors"]),
        ("proposals left unapproved", ex["unapproved"]),
        ("search recall@1", srch["recall@1"]),
        ("search recall@5", srch["recall@5"]),
    ]
    head = f"{report['messages']} messages, {report['queries']} queries"
    return "\n".join([head, *(f"{name:<28}{value}" for name, value in rows)])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m eval.run")
    parser.add_argument("--db", required=True, help="superuser URL of a Postgres server")
    parser.add_argument("--extractor", choices=("claude", "fake"), default="claude")
    parser.add_argument("--limit", type=int, help="replay only the first N messages")
    parser.add_argument("--out-dir", type=Path, default=RESULTS)
    args = parser.parse_args(argv)
    messages = load_messages(args.limit)
    extractor: Extractor
    if args.extractor == "fake":
        extractor = OracleExtractor(load_messages())
    else:
        extractor = build_extractor(os.environ)
        if isinstance(extractor, NullExtractor):
            sys.stderr.write("eval: ANTHROPIC_API_KEY is not set; use --extractor fake\n")
            return 2
    report = run_eval(args.db, extractor, messages, load_queries())
    report["config"] = {
        "extractor": args.extractor,
        "model": os.environ.get("NUNCHI_EXTRACT_MODEL", "default"),
        "base_url": os.environ.get("ANTHROPIC_BASE_URL", "default"),
    }
    args.out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    (args.out_dir / f"{stamp}.json").write_text(json.dumps(report, ensure_ascii=False, indent=1))
    sys.stdout.write(table(report) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
