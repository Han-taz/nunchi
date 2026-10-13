"""Metrics over replay outcomes. Pure functions: no database, no model."""

from collections import defaultdict
from collections.abc import Sequence
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from eval.corpus import Message, Query

REMEMBERED = ("created", "reconfirmed")
RELATIONS = ("new", "same", "update")


class Outcome(BaseModel):
    """What the real pipeline did with one message."""

    model_config = ConfigDict(frozen=True)

    message: Message
    result: str  # created | reconfirmed | skipped | rejected | error
    memory_id: UUID | None = None
    db_kind: str | None = None
    subject_id: UUID | None = None
    conflicted: bool = False
    verdict: str = "active"  # last answer of decide(); anything else is left unapproved

    @property
    def remembered(self) -> bool:
        return self.result in REMEMBERED

    @property
    def relation(self) -> str:
        if self.result == "reconfirmed":
            return "same"
        return "update" if self.conflicted else "new"


def _ratio(num: int, den: int) -> float | None:
    return round(num / den, 3) if den else None


def extraction(outcomes: Sequence[Outcome]) -> dict[str, float | int | None]:
    tp = sum(o.remembered and o.message.remember for o in outcomes)
    predicted = sum(o.remembered for o in outcomes)
    gold = sum(o.message.remember for o in outcomes)
    secrets = [o for o in outcomes if o.message.secret]
    return {
        "precision": _ratio(tp, predicted),
        "recall": _ratio(tp, gold),
        "secret_leaks": sum(o.remembered for o in secrets),
        "secrets": len(secrets),
        "errors": sum(o.result == "error" for o in outcomes),
        "unapproved": sum(o.result == "created" and o.verdict != "active" for o in outcomes),
    }


def kind_accuracy(outcomes: Sequence[Outcome]) -> float | None:
    hit = [o for o in outcomes if o.remembered and o.message.remember]
    return _ratio(sum(o.db_kind == o.message.kind for o in hit), len(hit))


def relation_accuracy(outcomes: Sequence[Outcome]) -> dict[str, float | None]:
    """Per gold relation: the share of messages the server classified the same way."""
    hit = [o for o in outcomes if o.remembered and o.message.remember]
    out: dict[str, float | None] = {}
    for rel in RELATIONS:
        group = [o for o in hit if o.message.relation == rel]
        out[rel] = _ratio(sum(o.relation == rel for o in group), len(group))
    return out


def fragmentation(outcomes: Sequence[Outcome], entity_rows: int) -> dict[str, float | int]:
    """Distinct entity rows per gold subject. 1.0 means every spelling reached one entity."""
    seen: dict[str, set[UUID]] = defaultdict(set)
    for o in outcomes:
        if o.remembered and o.message.subject and o.subject_id:
            seen[o.message.subject].add(o.subject_id)
    per = [len(ids) for ids in seen.values()]
    return {
        "gold_entities": len(seen),
        "entity_rows": entity_rows,
        "mean_rows_per_gold_entity": round(sum(per) / len(per), 3) if per else 0.0,
        "worst": max(per, default=0),
    }


def gold_by_db_id(outcomes: Sequence[Outcome]) -> dict[UUID, set[str]]:
    mapping: dict[UUID, set[str]] = defaultdict(set)
    for o in outcomes:
        if o.remembered and o.memory_id and o.message.memory:
            mapping[o.memory_id].add(o.message.memory)
    return mapping


def search_ranks(query: Query, hits: Sequence[UUID], mapping: dict[UUID, set[str]]) -> int | None:
    """1-based rank of the first hit that is a gold memory, or None."""
    for rank, hit in enumerate(hits, 1):
        if mapping.get(hit, set()) & set(query.gold):
            return rank
    return None


def search_recall(ranks: Sequence[int | None]) -> dict[str, float | None]:
    return {
        "recall@1": _ratio(sum(r is not None and r <= 1 for r in ranks), len(ranks)),
        "recall@5": _ratio(sum(r is not None and r <= 5 for r in ranks), len(ranks)),  # noqa: PLR2004
    }
