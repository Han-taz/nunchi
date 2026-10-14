#!/usr/bin/env python3
"""One-shot, idempotent cleanup of rows the pre-U39 pipeline stored (live sim findings).

usage: cleanup-u39.py [--dsn URL] [--dry-run | --apply --as-user PRINCIPAL_UUID]

Connects as the schema owner (default: NUNCHI_DATABASE_URL). --dry-run (the default) prints the plan
and writes nothing. --apply runs it in one transaction as --as-user, a contributor or curator of
every store touched (the retract transitions belong to that role). A second run does nothing.
Same-decision questions go to the judge model (ANTHROPIC_API_KEY); without a key the dry run lists
the candidates unjudged and --apply refuses.

Data shape: a Plan is a list of Action, at most one per open row (provisional, active, challenger):
  reject    a todo or status claim: rejected (expired when it was active).
  collapse  an open challenger that restates its key's live row: rejected, evidence moved to the
            live row as reconfirm evidence.
  merge     a later row that states an earlier row's decision under another key: same treatment.
A merged row's own open challenger becomes that key's provisional row (coordinator decision 2).
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from typing import Any
from uuid import UUID

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from nunchi.capture.same import same_decision, trigram_similarity
from nunchi.capture.worth import not_worth_text
from nunchi.db import bind_identity
from nunchi.extract import ValueJudge, build_judge

DUPLICATE_TRIGRAM_MIN = 0.3
OPEN = ("provisional", "active", "challenger")

OPEN_ROWS = (
    "SELECT m.id, m.store_id, m.status::text AS status, m.title, m.value, m.subject_id,"
    " m.attribute, m.created_at, m.version FROM memory AS m"
    " WHERE m.status::text = ANY(%s) ORDER BY m.created_at, m.id"
)
EVIDENCE = (
    "SELECT uri, post_id, author, author_name, said_at::text AS said_at, basis::text AS basis"
    " FROM memory_evidence WHERE memory_id = %s ORDER BY id"
)


@dataclass(frozen=True)
class Action:
    kind: str  # reject | collapse | merge
    row: dict[str, Any]
    into: dict[str, Any] | None
    why: str
    judged: bool = True

    def line(self) -> str:
        target = f" -> {self.into['id']} [{self.into['attribute']}]" if self.into else ""
        done = "" if self.judged else " (unjudged: needs ANTHROPIC_API_KEY)"
        return (
            f"{self.kind:<8} {self.row['id']} [{self.row['status']}] "
            f"{self.row['attribute']}={self.row['value']!r}{target}  {self.why}{done}"
        )


def _key(row: dict[str, Any]) -> tuple[Any, Any, Any]:
    return (row["store_id"], row["subject_id"], row["attribute"])


def _same(a: dict[str, Any], b: dict[str, Any], judge: ValueJudge | None) -> bool | None:
    """Whether two rows state one decision; None when only a judge could say."""
    if a["value"] is None or b["value"] is None:
        return False
    if judge is None:
        return None
    return same_decision(a["value"], a["title"], b["value"], b["title"], judge)


def build_plan(rows: list[dict[str, Any]], judge: ValueJudge | None) -> list[Action]:
    plan: list[Action] = []
    gone: set[Any] = set()
    for row in rows:
        if not_worth_text(row["title"], row["value"]):
            plan.append(Action("reject", row, None, "todo or status claim"))
            gone.add(row["id"])
    left = [r for r in rows if r["id"] not in gone]
    live = {_key(r): r for r in left if r["status"] != "challenger" and r["subject_id"]}
    for row in left:
        base = live.get(_key(row))
        if row["status"] != "challenger" or base is None:
            continue
        verdict = _same(row, base, judge)
        if verdict is not False:
            plan.append(
                Action("collapse", row, base, "restates the live row", judged=verdict is not None)
            )
            gone.add(row["id"])
    firsts = [r for r in left if r["id"] not in gone and r["status"] != "challenger" and r["value"]]
    merged: set[Any] = set()
    for i, row in enumerate(firsts):
        for earlier in firsts[:i]:
            if earlier["id"] in merged or earlier["store_id"] != row["store_id"]:
                continue
            if _key(earlier) == _key(row):
                continue
            text = (f"{row['title']} {row['value']}", f"{earlier['title']} {earlier['value']}")
            if trigram_similarity(*text) < DUPLICATE_TRIGRAM_MIN:
                continue
            verdict = _same(row, earlier, judge)
            if verdict is False:
                continue
            plan.append(
                Action(
                    "merge",
                    row,
                    earlier,
                    "same decision under another key",
                    judged=verdict is not None,
                )
            )
            merged.add(row["id"])
            break
    return plan


def reconfirm_with(cur: psycopg.Cursor[dict[str, Any]], source_id: UUID, target_id: UUID) -> None:
    """The source row's evidence becomes reconfirm evidence of the target, minus the posts the
    target already counts (the same call the write path makes)."""
    cur.execute(EVIDENCE, (source_id,))
    ev = cur.fetchall()
    if not ev:
        return
    basis = ev[0]["basis"]
    lines = Jsonb([{k: v for k, v in e.items() if k != "basis"} for e in ev])
    cur.execute("SELECT app_sec.new_evidence(%s, 'reconfirm', %s) AS fresh", (target_id, lines))
    fresh = cur.fetchone()["fresh"]  # type: ignore[index]
    if not fresh:
        return
    cur.execute("SELECT set_config('app.op', 'reconfirm', true)")
    cur.execute(
        "SELECT set_config('app.reason',"
        " app_sec.evidence_reason(%s::promotion_basis, %s::jsonb), true)",
        (basis, Jsonb(fresh)),
    )
    cur.execute(
        "UPDATE memory SET last_confirmed_at = clock_timestamp() WHERE id = %s", (target_id,)
    )
    cur.execute(
        "SELECT app_sec.record_evidence(%s, 'reconfirm', %s::promotion_basis, %s::jsonb)",
        (target_id, basis, Jsonb(fresh)),
    )


def apply_action(cur: psycopg.Cursor[dict[str, Any]], action: Action) -> None:
    row = action.row
    if action.into is not None:
        reconfirm_with(cur, row["id"], action.into["id"])
    to = "expired" if row["status"] == "active" else "rejected"
    cur.execute(
        "SELECT app_sec.move(%s, %s::memory_status, 'retract', %s)",
        (row["id"], to, f"u39 cleanup: {action.kind}"),
    )
    if row["status"] != "challenger" and row["subject_id"] is not None:
        cur.execute(
            "SELECT app_sec.adopt_orphan_challenger(%s, %s, %s)",
            (row["store_id"], row["subject_id"], row["attribute"]),
        )
    cur.execute("SELECT set_config('app.op', '', true), set_config('app.reason', '', true)")


def run(
    conn: psycopg.Connection[Any], judge: ValueJudge | None, as_user: UUID | None
) -> list[Action]:
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(OPEN_ROWS, (list(OPEN),))
        plan = build_plan(cur.fetchall(), judge)
        if as_user is not None:
            bind_identity(conn, as_user, None)
            for action in plan:
                apply_action(cur, action)
    return plan


def main(argv: list[str] | None = None, judge: ValueJudge | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("--dsn", default=os.environ.get("NUNCHI_DATABASE_URL"))
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
        plan = run(conn, judge, args.as_user if args.apply else None)
    for action in plan:
        sys.stdout.write(action.line() + "\n")
    counts = {k: sum(a.kind == k for a in plan) for k in ("reject", "collapse", "merge")}
    verb = "applied" if args.apply else "dry run, nothing written"
    sys.stdout.write(f"{verb}: {counts}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
