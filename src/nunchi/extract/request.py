from collections.abc import Callable
from uuid import UUID

from nunchi.domain.models import ProposeRequest
from nunchi.extract.draft import ExtractContext, ProposalDraft


class UnknownSubjectError(Exception):
    """No entity carries this name yet; the caller proposes a new entity first (design §3)."""

    def __init__(self, name: str) -> None:
        super().__init__(f"no entity for subject {name!r}")
        self.name = name


def to_propose_request(
    draft: ProposalDraft,
    context: ExtractContext,
    resolve_entity: Callable[[str], UUID | None],
) -> ProposeRequest:
    """The relation is not sent: the server finds the live row by key and decides."""
    subject_id = None
    if draft.subject_name is not None:
        subject_id = resolve_entity(draft.subject_name)
        if subject_id is None:
            raise UnknownSubjectError(draft.subject_name)
    return ProposeRequest(
        store_id=context.store_id,
        kind=draft.kind,
        title=draft.title,
        body=draft.body,
        source_refs=draft.source_refs,
        subject_id=subject_id,
        attribute=draft.attribute,
        value=draft.value,
    )
