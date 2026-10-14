"""A subject's attribute vocabulary (design v1.4): the keys its memories are stored under and the
question each key answers.

A key stands for a question, so two statements under one key are about one topic by construction.
A draft that names a key the subject already has uses it. A draft that proposes a new key is
compared with the subject's entries by their questions, never by values; only when none asks the
same thing does the server register a new entry. A missing judge, a judge error or any doubt
means the questions differ: a new entry, and no existing decision is touched."""

import re
import unicodedata
from collections.abc import Mapping
from uuid import UUID

from nunchi.db import Conn
from nunchi.extract import ProposalDraft, ValueJudge, VocabEntry

KEY_CHARS = 40
LABEL_CHARS = 80
QUESTION_CHARS = 200
COMPARED = 8  # a subject rarely has more attributes than a new question is compared with
_OPEN = ("active", "provisional", "challenger")


def slug(text: str) -> str:
    """A short lowercase key of hyphenated words, unchanged by app_sec.norm_text."""
    words = re.findall(r"\w+", unicodedata.normalize("NFKC", text).lower())
    return "-".join(words)[:KEY_CHARS].strip("-_") or "attribute"


def _normalized(text: str) -> str:
    """What app_sec.norm_text makes of `text`: the form memory.attribute is stored in."""
    return " ".join(text.lower().split())


def load(conn: Conn, store_id: UUID, subject_id: UUID) -> tuple[VocabEntry, ...]:
    """The subject's entries, then the attributes its open memories use without an entry (rows
    stored before the vocabulary existed), the title of such an attribute's oldest row standing in
    for its question."""
    rows = conn.execute(
        "(SELECT key, label, question FROM attribute_vocab WHERE store_id = %s AND subject_id = %s"
        " ORDER BY created_at, key) UNION ALL"
        " (SELECT DISTINCT ON (m.attribute) m.attribute, m.attribute, m.title FROM memory AS m"
        " WHERE m.store_id = %s AND m.subject_id = %s AND m.status = ANY(%s)"
        " AND m.attribute IS NOT NULL AND NOT EXISTS (SELECT 1 FROM attribute_vocab AS v"
        "  WHERE v.store_id = m.store_id AND v.subject_id = m.subject_id AND v.key = m.attribute)"
        " ORDER BY m.attribute, m.created_at)",
        (store_id, subject_id, store_id, subject_id, list(_OPEN)),
    ).fetchall()
    return tuple(VocabEntry(key=str(k), label=str(lb), question=str(q)) for k, lb, q in rows)


def settle_attribute(
    conn: Conn, store_id: UUID, subject_id: UUID, draft: ProposalDraft, judge: ValueJudge | None
) -> ProposalDraft:
    """The draft with its attribute set to the key of the vocabulary entry it answers, registering
    a new entry when it answers a question the subject has not got. A key the subject has is
    trusted, unless the draft states the question it answers and the judge says that is not the
    key's question: a model that copied a neighbour's key must not replace its decision."""
    if draft.attribute is None:
        return draft
    entries = load(conn, store_id, subject_id)
    by_key = {e.key: e for e in entries}
    key = next(
        (k for k in (_normalized(draft.attribute), slug(draft.attribute)) if k in by_key), ""
    )
    asked = draft.attribute_question
    wanted = draft.attribute
    if key and _is_other_question(by_key[key], asked, judge):
        entries, key, wanted = (
            tuple(e for e in entries if e.key != key),
            "",
            draft.attribute_label or asked or "",
        )
    if not key:
        label = (draft.attribute_label or draft.attribute)[:LABEL_CHARS]
        question = (asked or label)[:QUESTION_CHARS]
        key = _same_question_key(entries, question, judge) or _unused(by_key, wanted)
        if key not in by_key:
            conn.execute(
                "SELECT app_sec.register_attribute(%s, %s, %s, %s, %s)",
                (store_id, subject_id, key, label, question),
            )
    return draft.model_copy(update={"attribute": key})


def _is_other_question(entry: VocabEntry, asked: str | None, judge: ValueJudge | None) -> bool:
    return bool(
        asked
        and judge
        and asked != entry.question
        and not judge.same_question(asked, entry.question)
    )


def _unused(taken: Mapping[str, VocabEntry], text: str) -> str:
    base = slug(text)
    numbered = (f"{base[: KEY_CHARS - 3]}-{n}" for n in range(2, 100))
    return next(k for k in (base, *numbered) if k not in taken)


def _same_question_key(
    entries: tuple[VocabEntry, ...], question: str, judge: ValueJudge | None
) -> str | None:
    if judge is None:
        return None
    return next(
        (e.key for e in entries[:COMPARED] if judge.same_question(question, e.question)), None
    )
