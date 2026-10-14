"""Memory-quality harness: python -m eval.run --db postgresql://postgres:postgres@host/postgres

Replays eval/corpus through the real capture() on a throwaway database and scores the result.
--extractor claude (default) needs ANTHROPIC_API_KEY; --extractor fake uses the gold oracle."""

import argparse
import json
import os
import sys
from collections import Counter
from collections.abc import Callable
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any
from uuid import UUID

import psycopg

from eval import score
from eval.corpus import START, Message, Query, load_messages, load_queries, window_groups
from eval.db import CONTRIBUTOR, CURATORS, STORE, fresh_database, superuser_url
from eval.embedding import embed_documents
from eval.oracle import ConceptEmbedder, OracleExtractor, OracleJudge
from eval.score import Outcome
from eval.windows import (
    Check,
    CheckedExtractor,
    Window,
    consensus_metrics,
    load_windows,
    replay_windows,
    window_messages,
    window_metrics,
)
from nunchi.capture import (
    CaptureContext,
    CaptureResult,
    Created,
    Reconfirmed,
    Rejected,
    capture_all,
)
from nunchi.config import SEARCH_RRF_K, SEARCH_VECTOR_FLOOR, Settings
from nunchi.db import Conn, Pool, open_pool, request_tx
from nunchi.domain import repo
from nunchi.domain.models import MemoryOrigin, MemoryStatus, SourceRef
from nunchi.embed import Embedder, embedder_from_settings
from nunchi.extract import (
    ExtractionError,
    Extractor,
    NullExtractor,
    ValueJudge,
    build_extractor,
    build_judge,
)
from nunchi.worker.freshness import run_once

RESULTS = Path(__file__).parent / "results"
LIVE = (MemoryStatus.ACTIVE, MemoryStatus.PROVISIONAL)
SEARCH_DEPTH = 5


def _describe(conn: Conn, outcome_id: UUID) -> tuple[str, UUID | None, UUID | None]:
    row = conn.execute(
        "SELECT kind, subject_id, conflict_with FROM memory WHERE id = %s", (outcome_id,)
    ).fetchone()
    assert row is not None  # noqa: S101 - the row was just written in this transaction
    return str(row[0]), row[1], row[2]  # type: ignore[return-value]


def replay_group(
    pool: Pool,
    extractor: Extractor,
    group: list[Message],
    embedder: Embedder | None = None,
    judge: ValueJudge | None = None,
) -> list[Outcome]:
    """One capture of the window's text; its results line up with the gold items in order. A gold
    item with no result is skipped, and a result with no gold item is a false positive."""
    msg = group[0]
    context = CaptureContext(
        store_id=STORE,
        origin=MemoryOrigin.EXTERNAL,
        source_refs=(SourceRef(uri=f"https://eval.invalid/{msg.id}", system="slack"),),
        today=msg.today,
        window=msg.group is not None,
    )
    try:
        with request_tx(pool, CONTRIBUTOR, None) as conn:
            results = capture_all(conn, extractor, msg.filled, context, embedder, judge=judge)
            described = {
                i: _describe(conn, r.memory_id)
                for i, r in enumerate(results)
                if isinstance(r, Created | Reconfirmed)
            }
    except ExtractionError:
        return [Outcome(message=m, result="error") for m in group]
    surplus = [
        msg.model_copy(update={"remember": False, "memory": None}) for _ in results[len(group) :]
    ]
    paired = zip([*group, *surplus], results, strict=False)
    outcomes = [_outcome(pool, m, r, described.get(i)) for i, (m, r) in enumerate(paired)]
    outcomes += [Outcome(message=m, result="skipped") for m in group[len(results) :]]
    return outcomes


def replay(
    pool: Pool,
    extractor: Extractor,
    messages: list[Message],
    embedder: Embedder | None = None,
    judge: ValueJudge | None = None,
) -> list[Outcome]:
    return [
        o
        for group in window_groups(messages)
        for o in replay_group(pool, extractor, group, embedder, judge)
    ]


def _outcome(
    pool: Pool,
    msg: Message,
    result: CaptureResult,
    described: tuple[str, UUID | None, UUID | None] | None,
) -> Outcome:
    if isinstance(result, Created) and described is not None:
        verdict = result.status.value
        return Outcome(
            message=msg,
            result="created",
            memory_id=result.memory_id,
            db_kind=described[0],
            subject_id=described[1],
            conflicted=described[2] is not None,
            verdict=verdict,
        )
    if isinstance(result, Reconfirmed) and described is not None:
        return Outcome(
            message=msg,
            result="reconfirmed",
            memory_id=result.memory_id,
            db_kind=described[0],
            subject_id=described[1],
        )
    return Outcome(message=msg, result="rejected" if isinstance(result, Rejected) else "skipped")


def run_search(  # noqa: PLR0913, PLR0917 - the knobs a sweep varies
    pool: Pool,
    queries: list[Query],
    outcomes: list[Outcome],
    embedder: Embedder | None = None,
    vector_floor: float = SEARCH_VECTOR_FLOOR,
    rrf_k: int = SEARCH_RRF_K,
) -> list[dict[str, Any]]:
    mapping = score.gold_by_db_id(outcomes)
    rows = []
    for q in queries:
        with request_tx(pool, CONTRIBUTOR, None) as conn:
            hits = repo.search(
                conn,
                q.query,
                [STORE],
                None,
                LIVE,
                embedder=embedder,
                vector_floor=vector_floor,
                rrf_k=rrf_k,
            )[:SEARCH_DEPTH]
        rank = score.search_ranks(q, [h.id for h in hits], mapping)
        rows.append({"id": q.id, "query": q.query, "gold": list(q.gold), "rank": rank})
    return rows


def run_eval(  # noqa: PLR0913, PLR0917 - one run's inputs
    admin_url: str,
    extractor: Extractor,
    messages: list[Message],
    queries: list[Query],
    embedder: Embedder | None = None,
    judge: ValueJudge | None = None,
) -> dict[str, Any]:
    with fresh_database(admin_url) as app_url:
        pool = open_pool(Settings(database_url=app_url, pool_max_size=2))
        try:
            outcomes = replay(pool, extractor, messages, embedder, judge)
            if embedder is not None:
                with psycopg.connect(superuser_url(admin_url, app_url)) as admin:
                    embed_documents(admin, embedder, "title+body")
            searched = run_search(pool, queries, outcomes, embedder)
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
        "item_recall": score.item_recall(outcomes),
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


def worker_clock(url: str, first_day: date) -> Callable[[Pool, date], None]:
    """The `tick` of replay_windows: the worker runs once at each day boundary. Timers are stamped
    with the real clock, so the tick moves them instead: every timer that already existed at the
    previous tick gets the days that passed taken off, and the worker then runs at the real now.
    A row written during a day is a day old at the second boundary after it, not the first."""
    previous = first_day - timedelta(days=1)
    seen: list[UUID] = []

    def tick(_pool: Pool, day: date) -> None:
        nonlocal previous, seen
        elapsed, previous = day - previous, day
        with psycopg.connect(url) as conn:
            conn.execute(
                "UPDATE memory SET promote_at = promote_at - %s WHERE id = ANY(%s)", (elapsed, seen)
            )
            run_once(conn)
            seen = [
                r[0] for r in conn.execute("SELECT id FROM memory WHERE promote_at IS NOT NULL")
            ]

    return tick


def run_window_eval(
    admin_url: str,
    extractor: Extractor,
    windows: list[Window],
    embedder: Embedder | None = None,
    judge: ValueJudge | None = None,
) -> dict[str, Any]:
    """Replay the window corpus in day order and score where each gold memory ended up, and how
    the server's consensus check treated what the extractor claimed."""
    by_id = {w.id: w for w in windows}
    checks: dict[str, list[Check]] = {}

    def replay_checked(p: Pool, group: list[Message]) -> list[Outcome]:
        wid = group[0].group or group[0].id
        checked = CheckedExtractor(extractor, by_id[wid])
        outcomes = replay_group(p, checked, group, embedder, judge)
        checks[wid] = checked.checks
        return outcomes

    with fresh_database(admin_url) as app_url:
        pool = open_pool(Settings(database_url=app_url, pool_max_size=2))
        try:
            outcomes, statuses = replay_windows(
                pool,
                windows,
                replay_checked,
                worker_clock(superuser_url(admin_url, app_url), START),
            )
        finally:
            pool.close()
    return {
        "windows": len(windows),
        **window_metrics(windows, outcomes, statuses),
        "consensus_check": consensus_metrics(windows, checks),
        "final_statuses": dict(Counter(statuses.values())),
    }


def window_table(report: dict[str, Any]) -> str:
    wrong, dup, ret, con = (
        report["wrongly_active"],
        report["duplicate_per_key"],
        report["retraction_recall"],
        report["consensus_check"],
    )
    rows = [
        ("wrongly active", f"{wrong['rate']} ({wrong['wrong']}/{wrong['active']})"),
        ("duplicate per key", f"{dup['rate']} ({dup['duplicated']}/{dup['memories']})"),
        ("live style rows (wm01)", dup["rows_per_memory"].get("wm01")),
        ("retraction recall", f"{ret['recall']} ({ret['retracted']}/{ret['retractions']})"),
        ("agreed claimed / lowered", f"{con['claimed_agreed']} / {con['lowered']}"),
        (
            "agreed wrongly (verified)",
            f"{con['wrongly_agreed']['rate']} ({con['wrongly_agreed']['count']})",
        ),
        ("agreed missed", f"{con['missed_agreed']['count']}/{con['missed_agreed']['gold_agreed']}"),
    ]
    return "\n".join([f"{report['windows']} windows", *(f"{n:<26}{v}" for n, v in rows)])


def table(report: dict[str, Any]) -> str:
    ex, rel, frag, srch = (
        report["extraction"],
        report["relation_accuracy"],
        report["fragmentation"],
        report["search"],
    )
    rows = [
        ("extraction precision", ex["precision"]),
        ("extraction recall (per item)", ex["recall"]),
        ("multi-item window recall", report["item_recall"]["multi"]),
        ("single-item recall", report["item_recall"]["single"]),
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
    head = f"{report['messages']} gold items, {report['queries']} queries"
    return "\n".join([head, *(f"{name:<28}{value}" for name, value in rows)])


def _resolve_sweep(args: argparse.Namespace) -> int:
    if args.embedder == "none":
        sys.stderr.write("eval: --resolve-sweep needs --embedder concept or env\n")
        return 2
    from eval.resolve_sweep import resolve_sweep_table, run_resolve_sweep  # noqa: PLC0415

    embedder: Embedder = (
        ConceptEmbedder()
        if args.embedder == "concept"
        else embedder_from_settings(Settings(database_url="unused"))  # type: ignore[assignment]
    )
    judge = build_judge(os.environ)
    if judge is None:
        sys.stderr.write("eval: ANTHROPIC_API_KEY is not set; the judge rows are skipped\n")
    rows = run_resolve_sweep(embedder, judge)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    (args.out_dir / f"resolve-sweep-{stamp}.json").write_text(json.dumps(rows, indent=1))
    sys.stdout.write(resolve_sweep_table(rows) + "\n")
    return 0


def _save_windows(
    args: argparse.Namespace,
    extractor: Extractor,
    windows: list[Window],
    embedder: Embedder | None,
    judge: ValueJudge | None,
) -> int:
    report = run_window_eval(args.db, extractor, windows, embedder, judge)
    report["config"] = {"extractor": args.extractor, "embedder": args.embedder}
    args.out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    (args.out_dir / f"windows-{stamp}.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=1)
    )
    sys.stdout.write(window_table(report) + "\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m eval.run")
    parser.add_argument("--db", help="superuser URL of a Postgres server (not needed for sweeps)")
    parser.add_argument("--extractor", choices=("claude", "fake", "noisy"), default="claude")
    parser.add_argument(
        "--embedder",
        choices=("none", "concept", "env"),
        default="none",
        help="concept: oracle-grade wiring check; env: the NUNCHI_EMBEDDING_* endpoint",
    )
    parser.add_argument(
        "--sweep",
        action="store_true",
        help="ingest once, then print search recall over vector floor x RRF k x embed text",
    )
    parser.add_argument(
        "--resolve-sweep",
        action="store_true",
        help="attribute cosine floors, and the value judge when an API key is set, on gold pairs",
    )
    parser.add_argument(
        "--windows",
        action="store_true",
        help="replay eval/corpus/windows.jsonl and print the v1.3 window metrics",
    )
    parser.add_argument("--limit", type=int, help="replay only the first N messages")
    parser.add_argument("--out-dir", type=Path, default=RESULTS)
    args = parser.parse_args(argv)
    if args.resolve_sweep:
        return _resolve_sweep(args)
    if args.db is None:
        parser.error("--db is required")
    windows = load_windows()
    messages = window_messages(windows) if args.windows else load_messages(args.limit)
    extractor: Extractor
    judge: ValueJudge | None = None
    if args.extractor in ("fake", "noisy"):
        extractor = OracleExtractor(
            messages if args.windows else load_messages(), noisy=args.extractor == "noisy"
        )
        judge = OracleJudge()
    else:
        judge = build_judge(os.environ)
        extractor = build_extractor(os.environ)
        if isinstance(extractor, NullExtractor):
            sys.stderr.write("eval: ANTHROPIC_API_KEY is not set; use --extractor fake\n")
            return 2
    embedder: Embedder | None = None
    if args.embedder == "concept":
        embedder = ConceptEmbedder()
    elif args.embedder == "env":
        embedder = embedder_from_settings(Settings(database_url="unused"))
    if args.sweep:
        if embedder is None:
            sys.stderr.write("eval: --sweep needs --embedder concept or env\n")
            return 2
        from eval.sweep import run_sweep, sweep_table  # noqa: PLC0415 - sweep imports this module

        rows = run_sweep(args.db, extractor, messages, load_queries(), embedder)
        args.out_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
        (args.out_dir / f"sweep-{stamp}.json").write_text(json.dumps(rows, indent=1))
        sys.stdout.write(sweep_table(rows) + "\n")
        return 0
    if args.windows:
        return _save_windows(args, extractor, windows, embedder, judge)
    report = run_eval(args.db, extractor, messages, load_queries(), embedder, judge)
    report["config"] = {
        "extractor": args.extractor,
        "embedder": args.embedder,
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
