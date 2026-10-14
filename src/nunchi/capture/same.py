"""Same-value decision for a key that already has a live row (design v1.2 section 3).

The database trigger compares normalized values and reconfirms on equality. This module makes
equality mean what a reader means: honorifics do not count, and a value restated in other words
counts when a yes/no judge model says the two give the same answer (embedding cosine could not tell
the same value from a different one: false merges stayed high at every floor). The judge sees both
values with their titles (a short value means little alone), the live row first, then the key's
open challenger. A merge is only ever expressed by handing the draft the live row's own value, so
the trigger stays the single decider and a missing judge, a judge error or any doubt leaves the
values different (an update, never a false merge)."""

import re
from uuid import UUID

from nunchi.capture.resolve import ResolveConfig
from nunchi.db import Conn
from nunchi.domain.models import MemoryStatus
from nunchi.extract import ProposalDraft, ValueJudge

_LIVE = tuple(s.value for s in (MemoryStatus.ACTIVE, MemoryStatus.PROVISIONAL))
_OPEN = (*_LIVE, MemoryStatus.CHALLENGER.value)

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


def canonical_value(
    conn: Conn,
    store_id: UUID,
    subject_id: UUID,
    draft: ProposalDraft,
    judge: ValueJudge | None,
) -> ProposalDraft:
    """The draft with its value stripped of honorifics, and replaced by the live row's value when
    the two denote the same answer."""
    if draft.value is None or draft.attribute is None:
        return draft
    new = strip_honorific(draft.value)
    rows = conn.execute(
        "SELECT value, title FROM memory WHERE store_id = %s AND subject_id = %s"
        " AND attribute = app_sec.norm_text(%s) AND status = ANY(%s) AND value IS NOT NULL"
        " ORDER BY (status = 'challenger'), created_at",
        (store_id, subject_id, draft.attribute, list(_OPEN)),
    ).fetchall()
    for value, title in rows:
        if same_decision(new, draft.title, str(value), str(title), judge):
            return draft.model_copy(update={"value": str(value)})
    return draft.model_copy(update={"value": new})


def reuse_attribute(  # noqa: PLR0913, PLR0917 - the key (store, subject), the draft and the knobs
    conn: Conn,
    store_id: UUID,
    subject_id: UUID,
    draft: ProposalDraft,
    judge: ValueJudge | None,
    cfg: ResolveConfig,
) -> ProposalDraft:
    """A draft whose attribute is new for its subject takes the attribute of an open row of the
    same subject that states the same decision (title and value close by trigram, then the judge
    agrees). One decision then lives under one key, not under two spellings of its property."""
    if judge is None or draft.value is None or draft.attribute is None:
        return draft
    taken = conn.execute(
        "SELECT 1 FROM memory WHERE store_id = %s AND subject_id = %s"
        " AND attribute = app_sec.norm_text(%s) AND status = ANY(%s)",
        (store_id, subject_id, draft.attribute, list(_OPEN)),
    ).fetchone()
    if taken is not None:
        return draft
    new = strip_honorific(draft.value)
    text = f"{draft.title} {new}"
    rows = conn.execute(
        "SELECT attribute, value, title FROM memory WHERE store_id = %s AND subject_id = %s"
        " AND status = ANY(%s) AND value IS NOT NULL ORDER BY created_at",
        (store_id, subject_id, list(_OPEN)),
    ).fetchall()
    scored = sorted(
        ((trigram_similarity(text, f"{t} {v}"), a, v, t) for a, v, t in rows),
        key=lambda r: -r[0],
    )
    near = [(a, v, t) for sim, a, v, t in scored if sim >= cfg.reuse_trigram_min]
    near = near[: cfg.reuse_candidates]
    for attribute, value, title in near:
        if same_decision(new, draft.title, str(value), str(title), judge):
            return draft.model_copy(update={"attribute": str(attribute)})
    return draft


def _trigrams(text: str) -> set[str]:
    grams: set[str] = set()
    for word in re.findall(r"[^\W_]+", text.casefold()):
        padded = f"  {word} "
        grams.update(padded[i : i + 3] for i in range(len(padded) - 2))
    return grams


def trigram_similarity(a: str, b: str) -> float:
    """pg_trgm's measure (shared trigrams over all trigrams of both), computed here because the
    application role may not call the extension's functions."""
    ga, gb = _trigrams(a), _trigrams(b)
    return len(ga & gb) / len(ga | gb) if ga or gb else 0.0


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


def same_decision(
    new: str, new_title: str, old: str, old_title: str, judge: ValueJudge | None
) -> bool:
    """True when the two values give one answer: equal without honorifics, or, with no number
    that disagrees, a judge model says so."""
    if strip_honorific(old).casefold() == new.casefold():
        return True
    return bool(
        judge and not numbers_conflict(new, old) and judge.same(new, old, new_title, old_title)
    )
