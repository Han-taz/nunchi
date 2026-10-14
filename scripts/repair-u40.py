#!/usr/bin/env python3
"""One-shot, idempotent repair of decisions that attribute reuse pushed onto another topic's key.

usage: repair-u40.py [--dsn URL] [--days N] [--dry-run | --apply --as-user PRINCIPAL_UUID]

Before U40 a draft about one topic could land on the key of another (the extractor copied a
candidate's attribute) and then superseded or challenged that topic's live row. This finds, among
rows created in the last --days days (default 7), every live row R that superseded or challenges
a row O of its key, and asks the judge whether R answers the same question as O. When it does not:

  restore   R is active and O was superseded by it: R is expired, O is re-created as the key's
            active row (its title, body and evidence copied), and R is re-created under an
            attribute of its own with R's evidence. A superseded row cannot be reactivated (the
            state machine has no such transition), so the live row is a copy and O stays history.
  detach    R is an open challenger of O: R is rejected and re-created under an attribute of its
            own with R's evidence. O is untouched.
  manual    R has an open challenger of its own; nothing is written, a person decides.

Connects as the schema owner (default: NUNCHI_DATABASE_URL). --dry-run (the default) prints the
plan and writes nothing. --apply runs it in one transaction as --as-user, a contributor of every
store touched. A second run finds nothing, because R is no longer open on that key. Without a
judge (ANTHROPIC_API_KEY) the dry run lists the candidates unjudged and --apply refuses.
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from typing import Any, Protocol
from uuid import UUID

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from nunchi.capture.same import free_attribute
from nunchi.db import bind_identity
from nunchi.extract import build_judge


class ValueJudge(Protocol):
    def same_topic(
        self, first: str, second: str, first_title: str = "", second_title: str = ""
    ) -> bool: ...


PAIRS = (
    "SELECT r.id AS rid, r.store_id, r.subject_id, r.attribute, r.status::text AS rstatus,"
    " r.title AS rtitle, r.value AS rvalue, r.body AS rbody, r.basis::text AS rbasis,"
    " r.source_refs AS rrefs, r.kind::text AS kind,"
    " o.id AS oid, o.title AS otitle, o.value AS ovalue, o.body AS obody, o.source_refs AS orefs,"
    " EXISTS (SELECT 1 FROM memory AS c WHERE c.conflict_with = r.id AND c.status = 'challenger')"
    " AS blocked FROM memory AS r JOIN memory AS o ON o.id = r.supersedes_id"
    " WHERE r.created_at >= now() - make_interval(days => %s) AND r.value IS NOT NULL"
    " AND o.value IS NOT NULL AND o.store_id = r.store_id"
    " AND ((r.status = 'active' AND o.status = 'superseded') OR r.status = 'challenger')"
    " ORDER BY r.created_at, r.id"
)
EVIDENCE = (
    "SELECT uri, post_id, author, author_name, said_at::text AS said_at"
    " FROM memory_evidence WHERE memory_id = %s ORDER BY id"
)


@dataclass(frozen=True)
class Action:
    kind: str  # restore | detach | manual
    pair: dict[str, Any]
    judged: bool = True

    def line(self) -> str:
        p = self.pair
        done = "" if self.judged else " (unjudged: needs ANTHROPIC_API_KEY)"
        return (
            f"{self.kind:<7} {p['rid']} [{p['rstatus']}] {p['attribute']}={p['rvalue']!r}"
            f" ({p['rtitle']}) vs {p['oid']} {p['ovalue']!r} ({p['otitle']}){done}"
        )


def build_plan(pairs: list[dict[str, Any]], judge: ValueJudge | None) -> list[Action]:
    plan: list[Action] = []
    for p in pairs:
        verdict = (
            None
            if judge is None
            else judge.same_topic(p["rvalue"], p["ovalue"], p["rtitle"], p["otitle"])
        )
        if verdict is True:
            continue
        kind = "manual" if p["blocked"] else ("restore" if p["rstatus"] == "active" else "detach")
        plan.append(Action(kind, p, judged=verdict is not None))
    return plan


def _lines(cur: psycopg.Cursor[dict[str, Any]], memory_id: UUID) -> Jsonb:
    cur.execute(EVIDENCE, (memory_id,))
    return Jsonb(cur.fetchall())


def _remember(  # noqa: PLR0913, PLR0917 - the arguments of app_sec.remember
    cur: psycopg.Cursor[dict[str, Any]],
    p: dict[str, Any],
    side: str,
    memory_id: UUID,
    attribute: str,
    consensus: str,
) -> None:
    refs = [r for r in p[f"{side}refs"] if not str(r.get("uri", "")).startswith("memory://")]
    cur.execute(
        "SELECT * FROM app_sec.remember(%s, %s::memory_kind, %s, %s, %s, %s, %s, %s, '{}'::jsonb,"
        " %s, %s)",
        (
            p["store_id"], p["kind"], p[f"{side}title"], p[f"{side}body"], Jsonb(refs),
            p["subject_id"], attribute, p[f"{side}value"], consensus, _lines(cur, memory_id),
        ),
    )  # fmt: skip


def apply_action(
    conn: psycopg.Connection[Any], cur: psycopg.Cursor[dict[str, Any]], action: Action
) -> None:
    p = action.pair
    if action.kind == "manual":
        return
    why = f"u40 repair: {action.kind}, {p['rid']} is another topic than {p['oid']}"
    attribute = free_attribute(conn, p["store_id"], p["subject_id"], [p["rtitle"]])  # type: ignore[arg-type]
    to = "expired" if p["rstatus"] == "active" else "rejected"
    cur.execute("SELECT app_sec.move(%s, %s::memory_status, 'retract', %s)", (p["rid"], to, why))
    if action.kind == "restore":
        _remember(cur, p, "o", p["oid"], p["attribute"], "agreed")
    _remember(cur, p, "r", p["rid"], attribute, "agreed" if p["rbasis"] == "agreed" else "stated")
    cur.execute("SELECT set_config('app.op', '', true), set_config('app.reason', '', true)")


def run(
    conn: psycopg.Connection[Any], judge: ValueJudge | None, days: int, as_user: UUID | None
) -> list[Action]:
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(PAIRS, (days,))
        plan = build_plan(cur.fetchall(), judge)
        if as_user is not None:
            bind_identity(conn, as_user, None)  # type: ignore[arg-type]
            for action in plan:
                apply_action(conn, cur, action)
    return plan


def main(argv: list[str] | None = None, judge: ValueJudge | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("--dsn", default=os.environ.get("NUNCHI_DATABASE_URL"))
    parser.add_argument("--days", type=int, default=7)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--apply", action="store_true")
    parser.add_argument("--as-user", type=UUID, help="principal id the --apply writes as")
    args = parser.parse_args(argv)
    if not args.dsn:
        parser.error("--dsn or NUNCHI_DATABASE_URL is required")
    judge = judge or build_judge()
    if args.apply and args.as_user is None:
        parser.error("--apply needs --as-user")
    if args.apply and judge is None:
        sys.stderr.write("refusing to --apply without a judge: set ANTHROPIC_API_KEY\n")
        return 2
    with psycopg.connect(args.dsn) as conn:
        plan = run(conn, judge, args.days, args.as_user if args.apply else None)
    for action in plan:
        sys.stdout.write(action.line() + "\n")
    counts = {k: sum(a.kind == k for a in plan) for k in ("restore", "detach", "manual")}
    verb = "applied" if args.apply else "dry run, nothing written"
    sys.stdout.write(f"{verb}: {counts}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
