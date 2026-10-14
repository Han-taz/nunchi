"""Window corpus (v1.3 section 11): conversation windows replayed in day order, scored on where each
gold memory ends up. Gold is a table of memory -> final status; the metrics are pure functions of
that table, the replay outcomes and the status of every row the run left behind."""

from collections import defaultdict
from collections.abc import Callable, Sequence
from datetime import date, timedelta
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, model_validator

from eval.corpus import CORPUS_DIR, START, Message
from eval.db import CURATORS
from eval.score import Outcome, _ratio
from nunchi.db import Pool, request_tx
from nunchi.domain.models import MemoryKind

Relation = Literal["new", "same", "update", "retract"]
FinalStatus = Literal["active", "provisional", "challenger", "rejected"]
NOT_LIVE = ("rejected", "expired")


class Post(BaseModel):
    model_config = ConfigDict(frozen=True)

    author: str
    text: str


class Gold(BaseModel):
    """What a perfect pipeline does with one item of a window. A retraction has no memory of its
    own; it names the `target` memory it kills. `status_after` is the memory's status when the
    run ends, after every later window and the clock have had their say."""

    model_config = ConfigDict(frozen=True)

    memory: str | None
    status_after: FinalStatus | None
    relation: Relation
    target: str | None
    kind: MemoryKind | None
    subject: str | None
    attribute: str | None

    @model_validator(mode="after")
    def _shape(self) -> "Gold":
        if self.relation == "retract":
            ok = self.target is not None and self.memory is None
        else:
            ok = self.memory is not None and self.status_after is not None and self.kind is not None
        if not ok:
            raise ValueError(f"inconsistent gold item: {self}")
        return self


class Window(BaseModel):
    model_config = ConfigDict(frozen=True)

    id: str
    day: int
    posts: tuple[Post, ...]
    gold: tuple[Gold, ...]

    @property
    def text(self) -> str:
        return "\n".join(f"{p.author}: {p.text}" for p in self.posts)


def load_windows() -> list[Window]:
    lines = (CORPUS_DIR / "windows.jsonl").read_text().splitlines()
    windows = [Window.model_validate_json(line) for line in lines]
    finals: dict[str, set[str | None]] = defaultdict(set)
    for item in (g for w in windows for g in w.gold if g.memory):
        finals[item.memory].add(item.status_after)  # type: ignore[index]
    if any(len(s) > 1 for s in finals.values()):
        raise ValueError("a gold memory has two final statuses")
    return windows


def window_messages(windows: Sequence[Window]) -> list[Message]:
    """One Message per gold item, so the fake extractor and replay_group serve windows unchanged.
    Every window is a group (the capture path reads a window as several posts). A retraction is a
    Message nobody remembers: the v1.1 pipeline has no retract op."""
    return [
        Message(
            id=f"{w.id}.{i}",
            day=w.day,
            text=w.text,
            remember=g.relation != "retract",
            kind=g.kind,
            subject=g.subject,
            attribute=g.attribute,
            relation="none" if g.relation == "retract" else g.relation,
            memory=g.memory,
            updates=None,
            group=w.id,
        )
        for w in windows
        for i, g in enumerate(w.gold)
    ]


def replay_windows(
    pool: Pool,
    windows: Sequence[Window],
    replay_group: Callable[[Pool, list[Message]], list[Outcome]],
    tick: Callable[[Pool, date], None] | None = None,
) -> tuple[list[Outcome], dict[UUID, str]]:
    """Windows in day order; `tick(pool, day)` runs before each new day's first window and once
    more after the last window, so a timer-driven pipeline sees the clock move. Returns the
    outcomes and the final status of every memory row."""
    outcomes: list[Outcome] = []
    ordered = sorted(windows, key=lambda w: w.day)
    day: int | None = None
    for w in ordered:
        if tick is not None and w.day != day:
            tick(pool, START + timedelta(days=w.day))
        day = w.day
        outcomes += replay_group(pool, window_messages([w]))
    if tick is not None and ordered:
        tick(pool, START + timedelta(days=ordered[-1].day + 1))
    with request_tx(pool, CURATORS[0], None) as conn:
        rows = conn.execute("SELECT id, status FROM memory").fetchall()
    return outcomes, {r[0]: str(r[1]) for r in rows}  # type: ignore[misc]


def window_metrics(
    windows: Sequence[Window], outcomes: Sequence[Outcome], statuses: dict[UUID, str]
) -> dict[str, object]:
    gold_final = {g.memory: g.status_after for w in windows for g in w.gold if g.memory}
    rows: dict[str, set[UUID]] = defaultdict(set)
    gold_of: dict[UUID, set[str]] = defaultdict(set)
    for o in outcomes:
        if o.remembered and o.memory_id and o.message.memory:
            rows[o.message.memory].add(o.memory_id)
            gold_of[o.memory_id].add(o.message.memory)

    active = [i for i, s in statuses.items() if s == "active"]
    wrong = [i for i in active if not any(gold_final[m] == "active" for m in gold_of[i])]
    per_memory = {m: sum(statuses[i] != "rejected" for i in ids) for m, ids in sorted(rows.items())}
    duplicated = [m for m, n in per_memory.items() if n >= 2]  # noqa: PLR2004

    retractions = [g for w in windows for g in w.gold if g.relation == "retract"]
    retracted = [
        g for g in retractions
        if g.target in rows and all(statuses[i] in NOT_LIVE for i in rows[g.target])
    ]  # fmt: skip
    return {
        "wrongly_active": {
            "active": len(active),
            "wrong": len(wrong),
            "rate": _ratio(len(wrong), len(active)),
        },
        "duplicate_per_key": {
            "rows_per_memory": per_memory,
            "statuses": {m: sorted(statuses[i] for i in ids) for m, ids in sorted(rows.items())},
            "memories": len(per_memory),
            "duplicated": len(duplicated),
            "rate": _ratio(len(duplicated), len(per_memory)),
        },
        "retraction_recall": {
            "retractions": len(retractions),
            "retracted": len(retracted),
            "recall": _ratio(len(retracted), len(retractions)),
        },
    }
