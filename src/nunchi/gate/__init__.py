"""Deterministic write gate: no LLM, same text in, same verdict out."""

from dataclasses import dataclass
from enum import StrEnum
from urllib.parse import unquote

from nunchi.gate.normalize import normalize
from nunchi.gate.rules import RULES, Action, Kind, Rule


class Verdict(StrEnum):
    ALLOW = "allow"
    FLAG = "flag"
    REJECT = "reject"


@dataclass(frozen=True, slots=True)
class Flag:
    """A rule hit. Never carries the matched text, which may be the secret itself."""

    rule_id: str
    kind: Kind
    action: Action
    message: str


@dataclass(frozen=True, slots=True)
class GateResult:
    flags: tuple[Flag, ...]

    @property
    def verdict(self) -> Verdict:
        actions = {f.action for f in self.flags}
        if Action.REJECT in actions:
            return Verdict.REJECT
        return Verdict.FLAG if actions else Verdict.ALLOW

    def to_json(self) -> dict[str, object]:
        """Shape stored in memory.gate_result."""
        return {
            "verdict": self.verdict.value,
            "flags": [
                {
                    "rule": f.rule_id,
                    "kind": f.kind.value,
                    "action": f.action.value,
                    "message": f.message,
                }
                for f in self.flags
            ],
        }


def _hit(rule: Rule, views: tuple[str, ...]) -> bool:
    return any(rule.check is None or rule.check(m) for v in views for m in rule.pattern.finditer(v))


def evaluate(text: str) -> GateResult:
    canonical = normalize(text)
    # The percent-decoded copy exists only for matching; nothing stores it.
    views = tuple(dict.fromkeys((canonical, normalize(unquote(canonical)))))
    return GateResult(
        tuple(Flag(r.id, r.kind, r.action, r.message) for r in RULES if _hit(r, views))
    )


def evaluate_pair(raw: str, extracted: str) -> GateResult:
    """Merge the verdicts for the source text and the extractor output; strictest wins."""
    merged = dict.fromkeys(evaluate(raw).flags + evaluate(extracted).flags)
    return GateResult(tuple(merged))


__all__ = ["RULES", "Flag", "GateResult", "Verdict", "evaluate", "evaluate_pair"]
