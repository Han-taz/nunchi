"""The fake extractor: perfect gold labels, so a run measures the pipeline and not the model."""

import zlib
from collections import Counter
from collections.abc import Mapping, Sequence

from eval.corpus import Message
from nunchi.domain.models import MemoryKind
from nunchi.extract.draft import ExtractContext, ProposalDraft

_TITLE_CHARS = 120

# How a restating model drifts: each later mention of a gold name takes the next spelling here.
SUBJECT_VARIANTS = {
    "A사": ("에이사", "A Corp", "에이 사"),
    "B사": ("비사", "B Corp", "비 사"),
    "결제 모듈": ("결제모듈", "payment module"),
    "배포 파이프라인": ("배포 파이프 라인", "deploy pipeline"),
    "스테이징 서버": ("스테이징서버", "staging server"),
    "BI 대시보드": ("비아이 대시보드", "BI dashboard"),
}
ATTRIBUTE_VARIANTS = {
    "담당자": ("컨택", "담당 PM"),
    "정산일": ("정산 날짜", "정산 마감일"),
    "롤백 방법": ("롤백 절차", "롤백 하는 법"),
    "알림 채널": ("알림 채널명", "알람 채널"),
    "DB 선택": ("데이터베이스 선택", "DB 종류"),
}


class OracleExtractor:
    """Returns the gold key and the first-seen wording of each gold memory, so a restatement
    carries the identical body the server hashes. A secret message gets a leaky draft on purpose,
    so the gate (and not the extractor) is what the run measures for it."""

    def __init__(self, messages: list[Message], *, noisy: bool = False) -> None:
        self._noisy = noisy
        self._seen: Counter[tuple[str, str]] = Counter()
        self._by_text = {m.filled: m for m in messages}
        self._first: dict[str, str] = {}
        for m in messages:
            if m.memory is not None:
                self._first.setdefault(m.memory, m.filled)

    def extract(self, source_text: str, context: ExtractContext) -> ProposalDraft | None:
        gold = self._by_text[source_text]
        if gold.secret:
            return ProposalDraft(
                kind=MemoryKind.NOTE,
                title=source_text[:_TITLE_CHARS],
                body=source_text,
                source_refs=context.source_refs,
                origin=context.origin,
            )
        if not gold.remember or gold.kind is None or gold.memory is None:
            return None
        text = self._first[gold.memory]
        return ProposalDraft(
            kind=gold.kind,
            title=text[:_TITLE_CHARS],
            body=text,
            subject_name=self._spell(gold.subject, SUBJECT_VARIANTS, ""),
            attribute=self._spell(gold.attribute, ATTRIBUTE_VARIANTS, gold.subject or ""),
            source_refs=context.source_refs,
            origin=context.origin,
        )

    def _spell(
        self, name: str | None, variants: Mapping[str, tuple[str, ...]], scope: str
    ) -> str | None:
        """The gold spelling the first time, then the variants in turn; a name with no listed
        variants keeps its gold spelling."""
        if name is None or not self._noisy or name not in variants:
            return name
        n = self._seen[scope, name]
        self._seen[scope, name] += 1
        return name if n == 0 else variants[name][(n - 1) % len(variants[name])]


class ConceptEmbedder:
    """Wiring check for the embedding path: every spelling of a name shares one axis, which is the
    answer the real embedder has to find on its own. Its numbers bound the real embedder above.
    A spelling nobody listed gets its own axis, so it is close to nothing."""

    model = "concept-1"
    _DIM = 512

    def __init__(self) -> None:
        tables = (SUBJECT_VARIANTS, ATTRIBUTE_VARIANTS)
        groups = [(k, v) for table in tables for k, v in table.items()]
        self._axes = {
            spelling.lower(): i for i, (k, v) in enumerate(groups) for spelling in (k, *v)
        }

    def embed(self, texts: Sequence[str], prompt_name: str) -> list[list[float]]:
        out = []
        for text in texts:
            vec = [0.0] * self._DIM
            vec[self._axes.get(text.lower(), 100 + zlib.crc32(text.encode()) % 400)] = 1.0
            out.append(vec)
        return out
