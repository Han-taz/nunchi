"""Same-value decision for a key that already has a live row (design v1.2 section 3).

The database trigger compares normalized values and reconfirms on equality. This module makes
equality mean what a reader means: honorifics do not count, and a long value restated in other
words counts when a yes/no judge model says the two give the same answer (embedding cosine could
not tell the same long value from a different one: false merges stayed high at every floor). A merge
is only ever expressed by handing the draft the live row's own value, so the trigger stays the
single decider and a missing judge, a judge error or any doubt leaves the values different (an
update, never a false merge)."""

import re
from uuid import UUID

from nunchi.capture.resolve import ResolveConfig
from nunchi.db import Conn
from nunchi.domain.models import MemoryKind, MemoryStatus
from nunchi.extract import ProposalDraft, ValueJudge

_LIVE = tuple(s.value for s in (MemoryStatus.ACTIVE, MemoryStatus.PROVISIONAL))
_LONG_KINDS = (MemoryKind.PROCEDURE, MemoryKind.DECISION)

HONORIFIC_TITLES = (
    "매니저", "팀장", "부장", "차장", "과장", "대리", "사원", "이사", "실장", "본부장", "파트장",
)  # fmt: skip
HONORIFIC_MARKERS = ("님", "씨")
_TITLES = "|".join(HONORIFIC_TITLES)
_MARKERS = "|".join(HONORIFIC_MARKERS)
_PERSON = re.compile(rf"^(?P<name>[가-힣]{{2,4}}?)(?:\s(?:{_TITLES}))*(?:\s?(?:{_MARKERS}))?$")


def strip_honorific(value: str) -> str:
    """ "이민수님" and "정하늘 매니저님" are the names. A title counts only after a space that
    follows a 2-4 syllable name, so "영업팀장", "개발이사", "이사회" and "대리점" keep their
    words. A marker (님, 씨) counts only at the very end. A one-syllable name ("김 대리") stays."""
    text = " ".join(value.split())
    match = _PERSON.match(text)
    return match["name"] if match else text


def canonical_value(  # noqa: PLR0913, PLR0917 - the key (store, subject, attribute) and the draft
    conn: Conn,
    store_id: UUID,
    subject_id: UUID,
    draft: ProposalDraft,
    judge: ValueJudge | None,
    cfg: ResolveConfig,
) -> ProposalDraft:
    """The draft with its value stripped of honorifics, and replaced by the live row's value when
    the two denote the same answer."""
    if draft.value is None or draft.attribute is None:
        return draft
    new = strip_honorific(draft.value)
    row = conn.execute(
        "SELECT value FROM memory WHERE store_id = %s AND subject_id = %s"
        " AND attribute = app_sec.norm_text(%s) AND status = ANY(%s) AND value IS NOT NULL",
        (store_id, subject_id, draft.attribute, list(_LIVE)),
    ).fetchone()
    if row is None:
        return draft.model_copy(update={"value": new})
    live = str(row[0])
    if _same(draft, new, live, judge, cfg):
        return draft.model_copy(update={"value": live})
    return draft.model_copy(update={"value": new})


def _numbers(text: str) -> list[int]:
    return sorted(int(n) for n in re.findall(r"\d+", text))


def numbers_conflict(a: str, b: str) -> bool:
    """True when the numbers of the two values disagree: "14일" and "30일" are never the same
    answer, however alike the words. One side may mention a number the other leaves out."""
    na, nb = _numbers(a), _numbers(b)
    shorter, longer = (na, nb) if len(na) <= len(nb) else (nb, na)
    remaining = list(longer)
    for n in shorter:
        if n not in remaining:
            return True
        remaining.remove(n)
    return False


def _same(
    draft: ProposalDraft, new: str, live: str, judge: ValueJudge | None, cfg: ResolveConfig
) -> bool:
    if strip_honorific(live).casefold() == new.casefold():
        return True
    long = draft.kind in _LONG_KINDS or len(new) > cfg.long_value_chars
    return bool(judge and long and not numbers_conflict(new, live) and judge.same(new, live))
