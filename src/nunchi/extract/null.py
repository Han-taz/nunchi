from nunchi.domain.models import MemoryKind
from nunchi.extract.draft import ExtractContext, ProposalDraft

_TITLE_MAX = 300


class NullExtractor:
    """Offline extractor: the first line becomes the title and the whole text the body."""

    def extract(self, source_text: str, context: ExtractContext) -> tuple[ProposalDraft, ...]:
        text = source_text.strip()
        if not text:
            return ()
        draft = ProposalDraft(
            kind=MemoryKind.NOTE,
            title=text.splitlines()[0].strip()[:_TITLE_MAX],
            body=text,
            source_refs=context.source_refs,
            origin=context.origin,
        )
        return (draft,)
