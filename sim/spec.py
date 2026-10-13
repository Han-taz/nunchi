"""Typed scenario model. The YAML is parsed once here; everything else uses these records."""

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

import yaml

Expect = Literal["present", "updated", "absent"]


@dataclass(frozen=True)
class Persona:
    username: str
    role: str
    voice: str
    priorities: str
    quirks: str


@dataclass(frozen=True)
class Turn:
    speaker: str
    do: str
    decision: bool = False
    critical: bool = False
    event: str | None = None
    reply_to: str | None = None


@dataclass(frozen=True)
class Gold:
    subject: str
    attribute: str
    value: str
    kind: str
    expect: Expect
    match: tuple[str, ...]
    was: str | None = None
    needle: str | None = None


@dataclass(frozen=True)
class Scenario:
    product: str
    fake_key: str
    personas: dict[str, Persona]
    agenda: dict[int, tuple[Turn, ...]]
    gold: dict[int, tuple[Gold, ...]]


def _gold(raw: dict[str, Any]) -> Gold:
    value = str(raw["value"])
    return Gold(
        subject=raw["subject"],
        attribute=raw["attribute"],
        value=value,
        kind=raw["kind"],
        expect=raw["expect"],
        match=tuple(str(m) for m in raw.get("match", [value])),
        was=raw.get("was"),
        needle=raw.get("needle"),
    )


def load(path: Path) -> Scenario:
    raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    personas = {u: Persona(username=u, **p) for u, p in raw["personas"].items()}
    agenda = {
        int(d): tuple(
            Turn(
                speaker=t["s"],
                do=t["do"],
                decision=t.get("decision", False),
                critical=t.get("critical", False),
                event=t.get("event"),
                reply_to=t.get("reply"),
            )
            for t in day["turns"]
        )
        for d, day in raw["days"].items()
    }
    gold = {int(d): tuple(_gold(g) for g in items) for d, items in raw["gold"].items()}
    for turns in agenda.values():
        unknown = {t.speaker for t in turns} - personas.keys()
        if unknown:
            raise ValueError(f"unknown speaker {sorted(unknown)}")
    return Scenario(raw["product"], raw["fake_key"], personas, agenda, gold)


def gold_through(sc: Scenario, day: int) -> list[Gold]:
    """Expected team memory at the end of `day`: a later item replaces an earlier one with the
    same (subject, attribute) key; `absent` items accumulate."""
    keyed: dict[tuple[str, str, str], Gold] = {}
    for d in sorted(sc.gold):
        if d > day:
            break
        for g in sc.gold[d]:
            keyed[(g.subject, g.attribute, g.needle or "")] = g
    return list(keyed.values())
