"""Statements that are never memories, however the extractor labelled them.

Only a title that is plainly a concrete todo, a completed-work report or a PR announcement is
dropped. A policy ("서버에서만 사용해야 한다") or a decision ("Postgres 사용 필요", "작업 현황
대시보드는 v1.0에서 제외") is kept, and the value is never scanned."""

import re

from nunchi.extract import ProposalDraft

_END = r"[\s.!)\]]*$"
_RULES = (
    re.compile(rf"(?:수정|구현|확인|추가|통일)\s?필요{_END}"),
    re.compile(rf"(?:수정|구현|확인|추가|반영)해야\s?(?:함|합니다){_END}"),
    re.compile(r"(?:구현|머지|반영)\s?완료(?!일|조건|기준)"),
    re.compile(r"푸시\s?(?:했|완료)"),
    re.compile(r"작업\s?현황\s*(?:\([\w.\-]+\))?\s*$"),
    re.compile(r"\bPR\s?(?:#\d+\s?)?올렸", re.IGNORECASE),
)


def not_worth_text(title: str) -> bool:
    return any(rule.search(title.strip()) for rule in _RULES)


def not_worth(draft: ProposalDraft) -> bool:
    return not_worth_text(draft.title)
