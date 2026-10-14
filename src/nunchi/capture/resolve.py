"""Server-side entity and attribute resolution (design v1.2 section 3).

The model's spelling is a hint. A new subject name reuses an existing entity when, in order, its
match key equals an alias's, an alias is trigram-similar, or an embedding is close; only then does
it create one. The same ladder canonicalizes the attribute among the subject's live attributes.
Every threshold lives in ResolveConfig, so a sweep changes one place (env NUNCHI_RESOLVE_*)."""

import logging
import math
import re
import unicodedata
from collections.abc import Hashable, Mapping, Sequence
from typing import Any, cast
from uuid import UUID

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

from nunchi.capture.vocab import load
from nunchi.db import Conn
from nunchi.embed import Embedder, EmbedError
from nunchi.extract import EntityContext

log = logging.getLogger(__name__)

_ENTITY_KIND = "subject"
_LETTER_NAMES = {
    "에이": "a", "비": "b", "씨": "c", "디": "d", "이": "e", "에프": "f", "지": "g",
    "에이치": "h", "아이": "i", "제이": "j", "케이": "k", "엘": "l", "엠": "m", "엔": "n",
    "오": "o", "피": "p", "큐": "q", "알": "r", "에스": "s", "티": "t", "유": "u",
    "브이": "v", "더블유": "w", "엑스": "x", "와이": "y", "지이": "z",
}  # fmt: skip
_COMPANY_SUFFIX = re.compile(r"(?:\s(?:corporation|corp|inc|ltd|llc|co|company)|주식회사|㈜|사)$")


class ResolveConfig(BaseSettings):
    """Defaults tuned on eval/corpus: see the PR body. The cosine floors are for embeddinggemma-2
    and need a sweep against the real endpoint (python -m eval.run --embedder env)."""

    model_config = SettingsConfigDict(env_prefix="NUNCHI_RESOLVE_", frozen=True)

    trigram_min: float = Field(0.6, ge=0, le=1)
    subject_cosine_min: float = Field(0.80, ge=0, le=1)
    scan_limit: int = Field(200, ge=1)
    context_entities: int = Field(10, ge=1)
    context_min: float = Field(0.5, ge=0, le=1)
    context_vocabulary: int = Field(12, ge=1)


# Business attributes that mean one thing under many names, by match_key. Seeded so day one is right
# before any embedding learns it; an existing attribute of the same group wins over a new spelling.
ATTRIBUTE_SYNONYMS = (
    ("담당자", "담당", "컨택", "컨택 포인트", "담당 PM", "PM", "연락 담당", "연락 담당자", "POC"),
)


def match_key(name: str) -> str:
    """Spelling-insensitive key: "A사", "에이사", "A Corp" and "에이 사" all become "a"."""
    spaced = re.sub(r"[\s.,_()-]+", " ", unicodedata.normalize("NFKC", name).lower()).strip()
    stripped = _COMPANY_SUFFIX.sub("", spaced).replace(" ", "") or spaced.replace(" ", "")
    return _LETTER_NAMES.get(stripped, stripped)


def _synonym_group(key: str) -> frozenset[str]:
    for names in ATTRIBUTE_SYNONYMS:
        keys = frozenset(match_key(n) for n in names)
        if key in keys:
            return keys
    return frozenset()


def _rows(conn: Conn, query: str, params: Sequence[object]) -> list[tuple[Any, ...]]:
    return cast("list[tuple[Any, ...]]", conn.execute(query, params).fetchall())


def cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b, strict=True))
    return dot / ((math.hypot(*a) * math.hypot(*b)) or 1.0)


def _nearest[K: Hashable](
    embedder: Embedder | None, text: str, names: Mapping[K, str], floor: float
) -> K | None:
    """The key whose name embeds closest to text, if at least floor. A down service means no hit."""
    if embedder is None or not names:
        return None
    try:
        query = embedder.embed([text], "query")[0]
        docs = embedder.embed(list(names.values()), "document")
    except EmbedError as exc:
        log.warning("embedding unavailable, resolving without it: %s", exc)
        return None
    best = max(zip(names, docs, strict=True), key=lambda kd: cosine(query, kd[1]))
    return best[0] if cosine(query, best[1]) >= floor else None


def resolve_subject(conn: Conn, name: str, embedder: Embedder | None, cfg: ResolveConfig) -> UUID:
    exact: UUID | None = _rows(conn, "SELECT app_sec.resolve_entity(%s)", (name,))[0][0]
    if exact is not None:
        return exact
    rows = sorted(
        _rows(
            conn,
            "SELECT entity_id, canonical_name, alias_norm, sim FROM app_sec.entity_matches(%s, %s)",
            (name, cfg.scan_limit),
        ),
        key=lambda r: (-r[3], r[2]),
    )
    key = match_key(name)
    hit: UUID | None = next((r[0] for r in rows if match_key(r[2]) == key), None)
    if hit is None and rows and rows[0][3] >= cfg.trigram_min:
        hit = rows[0][0]
    if hit is None:
        hit = _nearest(embedder, name, {r[0]: r[1] for r in rows}, cfg.subject_cosine_min)
    if hit is None:
        created: UUID = _rows(conn, "SELECT app_sec.create_entity(%s, %s)", (name, _ENTITY_KIND))[
            0
        ][0]
        return created
    conn.execute("SELECT app_sec.add_entity_alias(%s, %s)", (hit, name))
    return hit


def resolve_attribute(conn: Conn, store_id: UUID, subject_id: UUID, attribute: str) -> str:
    """The subject's live attribute that `attribute` spells again (the same words in other
    spacing or case, or a seeded synonym), else `attribute` itself. Whether a different wording
    asks the same question is the vocabulary's call (nunchi.capture.vocab), not a name match."""
    rows = _rows(
        conn,
        "SELECT attribute FROM app_sec.attribute_matches(%s, %s, %s, 200)",
        (store_id, subject_id, attribute),
    )
    key = match_key(attribute)
    group = _synonym_group(key)
    same = next((r[0] for r in rows if match_key(r[0]) == key or match_key(r[0]) in group), None)
    return same or attribute


def known_entities(
    conn: Conn, store_id: UUID, source_text: str, extra: tuple[UUID, ...], cfg: ResolveConfig
) -> tuple[EntityContext, ...]:
    """Entities the extractor may reuse: those whose alias appears in the source (word
    similarity), then the subjects of the candidate memories search already found."""
    best: dict[UUID, float] = {}
    for row in _rows(
        conn,
        "SELECT entity_id, word_sim FROM app_sec.entity_matches(%s, %s)",
        (source_text, cfg.scan_limit),
    ):
        best[row[0]] = max(best.get(row[0], 0.0), row[1])
    named = sorted((i for i, w in best.items() if w >= cfg.context_min), key=lambda i: -best[i])
    ids = list(dict.fromkeys([*named, *extra]))[: cfg.context_entities]
    if not ids:
        return ()
    found = _rows(
        conn,
        "SELECT e.id, e.canonical_name,"
        " array(SELECT a.alias_norm FROM entity_alias AS a WHERE a.entity_id = e.id"
        "  ORDER BY a.alias_norm LIMIT 6)"
        " FROM entity AS e WHERE e.id = ANY(%s)",
        (ids,),
    )
    by_id = {r[0]: r for r in found}
    return tuple(
        EntityContext(
            id=i,
            name=by_id[i][1],
            aliases=tuple(by_id[i][2]),
            vocabulary=load(conn, store_id, i)[: cfg.context_vocabulary],
        )
        for i in ids
        if i in by_id
    )
