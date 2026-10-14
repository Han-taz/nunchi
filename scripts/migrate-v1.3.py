#!/usr/bin/env python3
"""One-shot, idempotent move of v1.1 data into the v1.3 memory model (design doc section 10).

usage: migrate-v1.3.py [--dsn URL] [--dry-run | --apply] [--same-value A=B ...]

Connects as the schema owner (default: NUNCHI_DATABASE_URL). Needs db/migrations applied first.
--dry-run (the default) prints the plan and writes nothing. --apply runs the plan in one transaction.
A second run finds no `proposed` rows and changes nothing.

Data shape: a Plan is one PlanRow per proposed memory, in (store, created_at, id) order.
Each row ends in exactly one outcome: Merge into a survivor, or Settle as active / provisional / challenger.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import unicodedata
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

DEFAULT_PROMOTE_AFTER = timedelta(hours=24)
NO_PROPOSED = "memory_no_proposed"

# proposed has no outgoing edge in memory_transition. The script adds these edges for its own transaction and removes them before commit.
TEMP_EDGES = (
    ("proposed", "active", "confirm"),
    ("proposed", "provisional", "promote"),
    ("proposed", "challenger", "promote"),
    ("proposed", "rejected", "reject"),
)


def norm(text: str | None) -> str | None:
    if text is None:
        return None
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", text)).strip().casefold() or None


@dataclass
class PlanRow:
    id: str
    store_id: str
    created_at: datetime
    kind: str
    title: str
    subject_id: str | None
    attribute: str | None
    value: str | None
    source_refs: list[dict[str, Any]]
    outcome: str = ""  # merge | active | provisional | challenger
    target: str | None = None  # merge: survivor id. challenger: the live row it challenges
    rule: str = ""
    approvals: list[dict[str, Any]] = field(default_factory=list)
    merged: list[PlanRow] = field(default_factory=list)
    promote_at: datetime | None = None


def same_value(a: PlanRow, b: PlanRow, aliases: set[frozenset[str]]) -> bool:
    va, vb = norm(a.value), norm(b.value)
    if va is None or vb is None:
        return False
    return va == vb or frozenset((va, vb)) in aliases


def speakers(row: PlanRow) -> set[str]:
    return {norm(s) or "" for ref in row.source_refs for s in ref.get("speakers", [])}


def build_plan(
    cur: psycopg.Cursor[dict[str, Any]], aliases: set[frozenset[str]], now: datetime
) -> tuple[list[PlanRow], list[PlanRow]]:
    cur.execute(
        "SELECT id::text, store_id::text, created_at, kind::text, title, subject_id::text, attribute, value, source_refs"
        " FROM memory WHERE status = 'proposed' ORDER BY store_id, created_at, id"
    )
    proposed = [PlanRow(**r) for r in cur.fetchall()]
    cur.execute(
        "SELECT id::text, store_id::text, created_at, kind::text, title, subject_id::text, attribute, value, source_refs,"
        " status::text AS outcome FROM memory WHERE status IN ('active', 'provisional') AND subject_id IS NOT NULL"
    )
    live = [PlanRow(**r) for r in cur.fetchall()]
    cur.execute("SELECT store_id::text, promote_after FROM store_autonomy")
    after = {r["store_id"]: r["promote_after"] for r in cur.fetchall()}
    cur.execute(
        "SELECT r.memory_id::text, r.id AS review_id, r.at, r.card_nonce::text, r.reviewer_id::text AS reviewer,"
        " p.display_name, coalesce((SELECT array_agg(i.platform_user_id) FROM principal_identity AS i"
        "   WHERE i.principal_id = p.id), '{}') AS uids"
        " FROM review AS r JOIN principal AS p ON p.id = r.reviewer_id"
        " WHERE r.verdict = 'approve' ORDER BY r.id"
    )
    reviews: dict[str, list[dict[str, Any]]] = {}
    for r in cur.fetchall():
        reviews.setdefault(r["memory_id"], []).append(r)

    survivors: dict[str, list[PlanRow]] = {}
    for row in live:
        survivors.setdefault(row.store_id, []).append(row)
    cur.execute(
        "SELECT store_id::text, subject_id::text, attribute FROM memory WHERE status = 'challenger'"
    )
    challengers = {(r["store_id"], r["subject_id"], r["attribute"]) for r in cur.fetchall()}
    for row in proposed:
        pool = survivors.setdefault(row.store_id, [])
        keyed = row.subject_id is not None and row.attribute is not None
        hit = None
        rule = ""
        if keyed:
            hit = next(
                (
                    s
                    for s in pool
                    if (s.subject_id, s.attribute) == (row.subject_id, row.attribute)
                    and same_value(s, row, aliases)
                ),
                None,
            )
            rule = "2: same key, same value"
            if hit is None:
                hit = next(
                    (
                        s
                        for s in pool
                        if s.attribute == row.attribute and same_value(s, row, aliases)
                    ),
                    None,
                )
                rule = "3: same attribute, same value, other key"
        if hit is not None:
            row.outcome, row.target, row.rule = "merge", hit.id, rule
            hit.merged.append(row)
            continue
        clash = next(
            (
                s
                for s in pool
                if keyed and (s.subject_id, s.attribute) == (row.subject_id, row.attribute)
            ),
            None,
        )
        if clash is not None:
            key = (row.store_id, row.subject_id, row.attribute)
            if key in challengers:
                msg = f"{row.id}: key already has a live row and a challenger; resolve by hand"
                raise SystemExit(msg)
            challengers.add(key)
            row.outcome, row.target, row.rule = "challenger", clash.id, "other value on a live key"
            row.promote_at = now + after.get(row.store_id, DEFAULT_PROMOTE_AFTER)
            continue
        pool.append(row)
        approvals = [
            a
            for a in reviews.get(row.id, [])
            if norm(a["display_name"]) not in speakers(row)
            and not {norm(u) for u in a["uids"]} & speakers(row)
        ]
        row.approvals = approvals
        if approvals:
            row.outcome, row.rule = "active", "4: approved by a non-speaker"
        else:
            row.outcome, row.rule = "provisional", "4: no usable approval"
            row.promote_at = now + after.get(row.store_id, DEFAULT_PROMOTE_AFTER)
    holders = [s for pool in survivors.values() for s in pool if s.merged]
    return proposed, holders


def short(uuid: str) -> str:
    return uuid[-8:]


def author_of(row: PlanRow) -> str | None:
    names = {s for ref in row.source_refs for s in ref.get("speakers", [])}
    return next(iter(names)) if len(names) == 1 else None


def apply_plan(
    cur: psycopg.Cursor[dict[str, Any]], plan: list[PlanRow], holders: list[PlanRow]
) -> None:
    for frm, to, op in TEMP_EDGES:
        cur.execute(
            "INSERT INTO memory_transition (from_status, to_status, op, by_roles) VALUES (%s, %s, %s, '{system}')",
            (frm, to, op),
        )

    def move(row: PlanRow, status: str, op: str, reason: str) -> None:
        cur.execute(
            "SELECT set_config('app.op', %s, true), set_config('app.reason', %s, true)",
            (op, reason),
        )
        cur.execute(
            "UPDATE memory SET status = %s, basis = 'migrated', promote_at = %s WHERE id = %s",
            (status, row.promote_at, row.id),
        )

    def evidence(memory: str, op: str, items: list[dict[str, Any]]) -> None:
        cur.execute(
            "SELECT app_sec.record_evidence(%s, %s, 'migrated', %s::jsonb)",
            (memory, op, Jsonb(items)),
        )

    for row in plan:
        if row.outcome == "merge":
            move(row, "rejected", "reject", f"merged:{row.target}")
    for row in plan:
        if row.outcome in ("active", "provisional", "challenger"):
            if row.outcome == "active":
                items = [
                    {
                        "uri": None,
                        "post_id": f"card:{a['card_nonce']}"
                        if a["card_nonce"]
                        else f"review:{a['review_id']}",
                        "author": a["reviewer"],
                        "author_name": a["display_name"],
                        "said_at": a["at"].isoformat(),
                    }
                    for a in row.approvals
                ]
                cur.execute(
                    "SELECT app_sec.evidence_reason('migrated', %s::jsonb)", (Jsonb(items),)
                )
                reason = next(iter(cur.fetchone().values()))  # type: ignore[union-attr]
                move(row, "active", "confirm", reason)
                evidence(row.id, "confirm", items)
            elif row.outcome == "provisional":
                move(row, "provisional", "promote", "migrated:v1.3")
            else:
                cur.execute(
                    "SELECT set_config('app.op', 'promote', true), set_config('app.reason', 'migrated:v1.3', true)"
                )
                cur.execute(
                    "UPDATE memory SET status = 'challenger', basis = 'migrated', promote_at = %s, conflict_with = %s WHERE id = %s",
                    (row.promote_at, row.target, row.id),
                )
    for row in holders:
        items = [
            {
                "uri": f"memory://{m.id}",
                "post_id": m.id,
                "author": author_of(m),
                "author_name": None,
                "said_at": m.created_at.isoformat(),
            }
            for m in row.merged
        ]
        cur.execute("SELECT app_sec.evidence_reason('migrated', %s::jsonb)", (Jsonb(items),))
        reason = next(iter(cur.fetchone().values()))  # type: ignore[union-attr]
        cur.execute(
            "SELECT set_config('app.op', 'reconfirm', true), set_config('app.reason', %s, true)",
            (reason,),
        )
        cur.execute(
            "UPDATE memory SET last_confirmed_at = clock_timestamp() WHERE id = %s", (row.id,)
        )
        evidence(row.id, "reconfirm", items)
    cur.execute("DELETE FROM memory_transition WHERE from_status = 'proposed'")
    cur.execute(
        "UPDATE approval_card SET consumed_at = now(), outcome = 'withdrawn:v1.3' WHERE consumed_at IS NULL"
    )
    cur.execute(
        "SELECT 1 FROM pg_constraint WHERE conname = %s AND conrelid = 'memory'::regclass",
        (NO_PROPOSED,),
    )
    if cur.fetchone() is None:
        cur.execute(f"ALTER TABLE memory ADD CONSTRAINT {NO_PROPOSED} CHECK (status <> 'proposed')")


def snapshot(cur: psycopg.Cursor[dict[str, Any]]) -> list[dict[str, Any]]:
    cur.execute(
        "SELECT right(m.id::text, 8) AS id, m.status::text AS status, m.basis::text AS basis,"
        " left(m.title, 28) AS title, m.attribute, m.value,"
        " (SELECT count(*) FROM memory_evidence AS e WHERE e.memory_id = m.id) AS evidence,"
        " (SELECT count(*) FROM approval_card AS c WHERE c.memory_id = m.id AND c.consumed_at IS NULL) AS open_cards"
        " FROM memory AS m ORDER BY m.created_at, m.id"
    )
    return cur.fetchall()


def show(title: str, rows: list[dict[str, Any]]) -> None:
    print(f"\n== {title}")
    if not rows:
        print("(none)")
        return
    cols = list(rows[0])
    print(" | ".join(cols))
    for r in rows:
        print(" | ".join("" if r[c] is None else str(r[c]) for c in cols))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--dsn", default=os.environ.get("NUNCHI_DATABASE_URL"))
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument(
        "--dry-run", action="store_true", help="print the plan, write nothing (default)"
    )
    mode.add_argument("--apply", action="store_true", help="run the plan in one transaction")
    ap.add_argument(
        "--same-value",
        action="append",
        default=[],
        metavar="A=B",
        help="treat two values as the same decision (the judge's verdict, given by hand). Repeatable.",
    )
    args = ap.parse_args(argv)
    if not args.dsn:
        ap.error("--dsn or NUNCHI_DATABASE_URL is required")
    aliases: set[frozenset[str]] = set()
    for pair in args.same_value:
        a, _, b = pair.partition("=")
        if not norm(a) or not norm(b):
            ap.error(f"--same-value needs A=B, got {pair!r}")
        aliases.add(frozenset((norm(a) or "", norm(b) or "")))

    with psycopg.connect(args.dsn, row_factory=dict_row) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT to_regprocedure('app_sec.record_evidence(uuid, memory_op, promotion_basis, jsonb)') IS NOT NULL AS ok"
        )
        if not cur.fetchone()["ok"]:  # type: ignore[index]
            print(
                "db/migrations are not applied (app_sec.record_evidence is missing)",
                file=sys.stderr,
            )
            return 2
        if cur.execute("SELECT current_setting('is_superuser') AS su").fetchone()["su"] != "on":  # type: ignore[index]
            print(
                "connect as the database owner (superuser): forced row security hides rows from other roles",
                file=sys.stderr,
            )
            return 2
        cur.execute("SELECT now() AS now")
        now = cur.fetchone()["now"]  # type: ignore[index]
        plan, holders = build_plan(cur, aliases, now)
        show(
            "plan",
            [
                {
                    "id": short(r.id),
                    "created_at": r.created_at.isoformat(timespec="seconds"),
                    "key": f"{short(r.subject_id or '-')}/{r.attribute or '-'}",
                    "value": r.value,
                    "result": r.outcome
                    if r.outcome != "merge"
                    else f"merge -> {short(r.target or '')}",
                    "rule": r.rule,
                    "evidence_from_merges": len(r.merged),
                }
                for r in plan
            ],
        )
        open_cards = cur.execute(
            "SELECT count(*) AS n FROM approval_card WHERE consumed_at IS NULL"
        ).fetchone()["n"]  # type: ignore[index]
        print(f"\nopen cards to withdraw: {open_cards}")
        if not args.apply:
            print("dry-run: nothing written. Re-run with --apply.")
            return 0
        show("before", snapshot(cur))
        apply_plan(cur, plan, holders)
        show("after", snapshot(cur))
        conn.commit()
    print("\napplied.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
