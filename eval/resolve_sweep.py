"""Resolve sweep: which cosine floor merges attributes the corpus says are the same and nothing
else, and how the long-value judge does on value pairs.

Pairs come from the gold labels, so no database is involved. Attribute pairs (a gold attribute
against its noisy spellings: same; two attributes of one subject: different) are scored by cosine
per floor. Value pairs (a gold value against its restatements: same; values that replace one
another under one key: different) are scored by the judge after the number guard, as in production.
Value cosine is not swept: it false-merged at every floor.
A floor is good when merged-same is high and false merges is zero."""

from collections import defaultdict
from itertools import combinations
from typing import Any

from eval.corpus import load_messages
from eval.oracle import ATTRIBUTE_VARIANTS, GOLD_VALUES, VALUE_VARIANTS
from nunchi.capture.resolve import cosine
from nunchi.capture.same import numbers_conflict
from nunchi.embed import Embedder
from nunchi.extract import ValueJudge

FLOORS = (0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.88, 0.90)
Pair = tuple[str, str]


def attribute_pairs() -> tuple[list[Pair], list[Pair]]:
    same = [(gold, v) for gold, variants in ATTRIBUTE_VARIANTS.items() for v in variants]
    per_subject: dict[str, set[str]] = defaultdict(set)
    for m in load_messages():
        if m.remember and m.subject and m.attribute:
            per_subject[m.subject].add(m.attribute)
    different = [p for attrs in per_subject.values() for p in combinations(sorted(attrs), 2)]
    return same, different


def value_pairs() -> tuple[list[Pair], list[Pair]]:
    same = [(GOLD_VALUES[m], v) for m, variants in VALUE_VARIANTS.items() for v in variants]
    by_key: dict[tuple[str | None, str | None], list[str]] = defaultdict(list)
    for m in load_messages():
        if m.remember and m.memory and m.relation in ("new", "update"):
            by_key[m.subject, m.attribute].append(GOLD_VALUES[m.memory])
    different = [p for vals in by_key.values() for p in combinations(vals, 2)]
    return same, different


def judged(judge: ValueJudge, pair: Pair) -> bool:
    return not numbers_conflict(*pair) and judge.same(*pair)


def run_resolve_sweep(embedder: Embedder, judge: ValueJudge | None = None) -> list[dict[str, Any]]:
    attr_same, attr_diff = attribute_pairs()

    def attr_sim(pair: Pair) -> float:
        return cosine(
            embedder.embed([pair[0]], "query")[0], embedder.embed([pair[1]], "document")[0]
        )

    sims = ([attr_sim(p) for p in attr_same], [attr_sim(p) for p in attr_diff])
    rows = [
        {
            "what": "attribute",
            "floor": floor,
            "same_merged": sum(s >= floor for s in sims[0]),
            "same_total": len(attr_same),
            "false_merges": sum(d >= floor for d in sims[1]),
            "different_total": len(attr_diff),
        }
        for floor in FLOORS
    ]
    if judge is not None:
        val_same, val_diff = value_pairs()
        rows.append(
            {
                "what": "judge",
                "floor": None,
                "same_merged": sum(judged(judge, p) for p in val_same),
                "same_total": len(val_same),
                "false_merges": sum(judged(judge, p) for p in val_diff),
                "different_total": len(val_diff),
            }
        )
    return rows


def resolve_sweep_table(rows: list[dict[str, Any]]) -> str:
    head = f"{'what':<10}{'floor':>6}{'same merged':>13}{'false merges':>14}"
    body = [
        f"{r['what']:<10}{r['floor'] or 'judge':>6}{r['same_merged']:>9}/{r['same_total']:<3}"
        f"{r['false_merges']:>10}/{r['different_total']:<3}"
        for r in rows
    ]
    return "\n".join([head, *body])
