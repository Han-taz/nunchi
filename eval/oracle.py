"""The fake extractor: perfect gold labels, so a run measures the pipeline and not the model."""

from eval.corpus import Message
from nunchi.domain.models import MemoryKind
from nunchi.extract.draft import ExtractContext, ProposalDraft

_TITLE_CHARS = 120


class OracleExtractor:
    """Returns the gold key and the first-seen wording of each gold memory, so a restatement
    carries the identical body the server hashes. A secret message gets a leaky draft on purpose,
    so the gate (and not the extractor) is what the run measures for it."""

    def __init__(self, messages: list[Message]) -> None:
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
            subject_name=gold.subject,
            attribute=gold.attribute,
            source_refs=context.source_refs,
            origin=context.origin,
        )
