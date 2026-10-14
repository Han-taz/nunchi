#!/usr/bin/env python3
"""One-shot, idempotent U41 migration of the live database to the attribute vocabulary.

usage: vocab-u41.py repair [--dsn URL] [--days N] [--only ID,ID]
                           [--dry-run | --apply --as-user UUID]
       vocab-u41.py backfill [--dsn URL] [--dry-run | --apply]

Run repair first, then backfill. Both default to --dry-run, print the plan and write nothing.

repair    Before U41 a draft about one topic could land on the key of another and then supersede
          or challenge that topic's live row. Among rows created in the last --days days
          (default 7) this finds each live row R that superseded or challenges a row O of its
          key, asks the judge for the question R and O each answer, and compares the questions:

            restore   R is active, O was superseded by it, they ask different things: R is
                      expired, O is re-created as the key's active row (its title, body and
                      evidence copied) and R is re-created under a key of its own with R's
                      evidence. A superseded row cannot be reactivated (the state machine has no
                      such transition), so the live row is a copy and O stays history.
            detach    R is an open challenger of O asking something else: R is rejected and
                      re-created under a key of its own. O is untouched.
            manual    R has an open challenger of its own; nothing is written.

          --apply runs in one transaction as --as-user (a contributor of every store touched),
          and --only limits it to the listed R ids of the dry run, so that what is applied is
          what was reviewed. A second run finds nothing, because R is no longer open on that key.
backfill  Gives every attribute that an open memory uses and the vocabulary lacks an entry: the
          judge writes its label and question from the newest open row's title and value. An
          attribute that cannot be a key (over 40 characters, or a sentence of more than 5
          words) is renamed on all its rows to a slug the judge proposes. Renaming needs a
          superuser connection (session_replication_role = replica keeps the memory triggers
          from treating it as an edit).

Connect as the schema owner (default: NUNCHI_DATABASE_URL). Both subcommands need the judge
(ANTHROPIC_API_KEY) to apply; a dry run without it lists the candidates unjudged.
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

from nunchi.capture.vocab import KEY_CHARS, LABEL_CHARS, QUESTION_CHARS, slug
from nunchi.db import bind_identity
from nunchi.extract import AttributeSpec, build_judge

SENTENCE_WORDS = 5


class Judge(Protocol):
    def describe(self, title: str, value: str, attribute: str) -> AttributeSpec | None: ...

    def same_question(self, first: str, second: str) -> bool: ...


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


OPEN_KEYS = (
    "SELECT DISTINCT ON (m.store_id, m.subject_id, m.attribute) m.tenant_id, m.store_id,"
    " m.subject_id, m.attribute, m.title, m.value FROM memory AS m"
    " WHERE m.kind <> 'note' AND m.attribute IS NOT NULL"
    " AND m.status IN ('active', 'provisional', 'challenger')"
    " AND NOT EXISTS (SELECT 1 FROM attribute_vocab AS v WHERE v.store_id = m.store_id"
    "  AND v.subject_id = m.subject_id AND v.key = m.attribute)"
    " ORDER BY m.store_id, m.subject_id, m.attribute, (m.status = 'challenger'), m.created_at DESC"
)
TAKEN = (
    "SELECT EXISTS (SELECT 1 FROM memory WHERE store_id = %(s)s AND subject_id = %(u)s"
    " AND attribute = %(k)s) OR EXISTS (SELECT 1 FROM attribute_vocab WHERE store_id = %(s)s"
    " AND subject_id = %(u)s AND key = %(k)s) AS taken"
)


def unused_key(
    cur: psycopg.Cursor[dict[str, Any]], store_id: UUID, subject_id: UUID, wanted: str
) -> str:
    """`wanted` as a slug, numbered until no memory or vocabulary entry of the subject has it."""
    base = slug(wanted)
    for n in range(1, 100):
        key = base if n == 1 else f"{base[: KEY_CHARS - 3]}-{n}"
        taken = cur.execute(TAKEN, {"s": store_id, "u": subject_id, "k": key}).fetchone()
        if taken is not None and not taken["taken"]:
            return key
    raise ValueError("no unused key")  # pragma: no cover - 99 numbered keys for one subject


@dataclass(frozen=True)
class Action:
    kind: str  # restore | detach | manual
    pair: dict[str, Any]
    spec: AttributeSpec | None = None
    judged: bool = True

    def line(self) -> str:
        p = self.pair
        done = "" if self.judged else " (unjudged: needs a judge answer)"
        return (
            f"{self.kind:<7} {p['rid']} [{p['rstatus']}] {p['attribute']}={p['rvalue']!r}"
            f" ({p['rtitle']}) vs {p['oid']} {p['ovalue']!r} ({p['otitle']}){done}"
        )


def build_plan(pairs: list[dict[str, Any]], judge: Judge | None) -> list[Action]:
    """The pairs whose two rows answer different questions. A pair the judge cannot decide is
    listed unjudged and never applied."""
    plan: list[Action] = []
    for p in pairs:
        r = judge.describe(p["rtitle"], p["rvalue"], p["attribute"]) if judge else None
        o = judge.describe(p["otitle"], p["ovalue"], p["attribute"]) if judge else None
        verdict = (
            None
            if judge is None or r is None or o is None
            else not judge.same_question(r.question, o.question)
        )
        if verdict is False:
            continue
        kind = "manual" if p["blocked"] else ("restore" if p["rstatus"] == "active" else "detach")
        plan.append(Action(kind, p, r, judged=verdict is not None))
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


def apply_action(cur: psycopg.Cursor[dict[str, Any]], action: Action) -> None:
    p = action.pair
    if action.kind == "manual" or not action.judged:
        return
    why = f"u41 repair: {action.kind}, {p['rid']} is another topic than {p['oid']}"
    wanted = action.spec.key if action.spec else p["rtitle"]
    attribute = unused_key(cur, p["store_id"], p["subject_id"], wanted)
    to = "expired" if p["rstatus"] == "active" else "rejected"
    cur.execute("SELECT app_sec.move(%s, %s::memory_status, 'retract', %s)", (p["rid"], to, why))
    if action.kind == "restore":
        _remember(cur, p, "o", p["oid"], p["attribute"], "agreed")
    _remember(cur, p, "r", p["rid"], attribute, "agreed" if p["rbasis"] == "agreed" else "stated")
    cur.execute("SELECT set_config('app.op', '', true), set_config('app.reason', '', true)")


def repair(
    conn: psycopg.Connection[Any],
    judge: Judge | None,
    days: int,
    only: set[str],
    as_user: UUID | None,
) -> list[Action]:
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(PAIRS, (days,))
        plan = build_plan(cur.fetchall(), judge)
        plan = [a for a in plan if not only or str(a.pair["rid"]) in only]
        if as_user is not None:
            bind_identity(conn, as_user, None)  # type: ignore[arg-type]
            for action in plan:
                apply_action(cur, action)
    return plan


@dataclass(frozen=True)
class Entry:
    row: dict[str, Any]
    key: str
    label: str
    question: str
    judged: bool = True

    def line(self) -> str:
        r = self.row
        renamed = "" if self.key == r["attribute"] else f" -> {self.key}"
        done = "" if self.judged else " (unjudged: needs a judge answer)"
        return f"entry   {r['attribute']}{renamed}: {self.question} ({r['title']}){done}"


def plan_backfill(rows: list[dict[str, Any]], judge: Judge | None) -> list[Entry]:
    """One entry per attribute the vocabulary lacks. A name that is a sentence cannot be a key and
    gets the judge's slug; any other name stays the key."""
    plan = []
    for r in rows:
        name = str(r["attribute"])
        spec = judge.describe(r["title"], r["value"], name) if judge else None
        keeps = len(name) <= KEY_CHARS and len(name.split()) <= SENTENCE_WORDS
        if spec is None:
            plan.append(
                Entry(r, name if keeps else slug(name), name[:LABEL_CHARS], r["title"], False)
            )
        else:
            key = name if keeps else slug(spec.key)
            plan.append(Entry(r, key, spec.label[:LABEL_CHARS], spec.question[:QUESTION_CHARS]))
    return plan


def apply_entry(cur: psycopg.Cursor[dict[str, Any]], e: Entry) -> None:
    """Rename the attribute on every row of its key when it is a sentence, then register it."""
    r = e.row
    key = (
        e.key if e.key == r["attribute"] else unused_key(cur, r["store_id"], r["subject_id"], e.key)
    )
    if key != r["attribute"]:
        cur.execute(
            "UPDATE memory SET attribute = %s WHERE store_id = %s AND subject_id = %s"
            " AND attribute = %s",
            (key, r["store_id"], r["subject_id"], r["attribute"]),
        )
    cur.execute(
        "INSERT INTO attribute_vocab (tenant_id, store_id, subject_id, key, label, question)"
        " VALUES (%s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING",
        (r["tenant_id"], r["store_id"], r["subject_id"], key, e.label, e.question),
    )


def backfill(conn: psycopg.Connection[Any], judge: Judge | None, apply: bool) -> list[Entry]:
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(OPEN_KEYS)
        plan = plan_backfill(cur.fetchall(), judge)
        if apply:
            cur.execute("SET LOCAL session_replication_role = replica")
            for entry in (e for e in plan if e.judged):
                apply_entry(cur, entry)
    return plan


def main(argv: list[str] | None = None, judge: Judge | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("command", choices=("repair", "backfill"))
    parser.add_argument("--dsn", default=os.environ.get("NUNCHI_DATABASE_URL"))
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--only", default="", help="repair only these R ids, comma separated")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--apply", action="store_true")
    parser.add_argument("--as-user", type=UUID, help="principal id the repair --apply writes as")
    args = parser.parse_args(argv)
    if not args.dsn:
        parser.error("--dsn or NUNCHI_DATABASE_URL is required")
    judge = judge or build_judge()
    if args.apply and args.command == "repair" and args.as_user is None:
        parser.error("repair --apply needs --as-user")
    if args.apply and judge is None:
        sys.stderr.write("refusing to --apply without a judge: set ANTHROPIC_API_KEY\n")
        return 2
    with psycopg.connect(args.dsn) as conn:
        if args.command == "repair":
            only = {i for i in args.only.split(",") if i}
            plan = repair(conn, judge, args.days, only, args.as_user if args.apply else None)
            counts = {
                k: sum(a.kind == k and a.judged for a in plan)
                for k in ("restore", "detach", "manual")
            } | {"unjudged": sum(not a.judged for a in plan)}
        else:
            plan = backfill(conn, judge, args.apply)
            counts = {"entries": len(plan), "unjudged": sum(not e.judged for e in plan)}
    for item in plan:
        sys.stdout.write(item.line() + "\n")
    verb = "applied" if args.apply else "dry run, nothing written"
    sys.stdout.write(f"{verb}: {counts}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
