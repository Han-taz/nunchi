"""The numbered window and the server's check of the extractor's consensus claim (design v1.3 4.1).

The model picks post numbers and a claim. Everything it is checked against, the authors and the
bot flags, comes from the platform's data, so a model cannot invent a second speaker."""

from collections.abc import Sequence

from nunchi.domain.models import Evidence, Frozen
from nunchi.extract.draft import Consensus

DECISION_MARKERS = ("결정", "확정", "합의", "하기로 했", "으로 가기로")


class WindowPost(Frozen):
    author: str
    text: str
    bot: bool = False
    ref: Evidence | None = None  # what the platform says about this post; None where it is unknown


def render_numbered(posts: Sequence[WindowPost]) -> str:
    """One `[n] author: text` line per post, n counted from 0 over the whole window."""
    return "\n".join(f"[{i}] {p.author}: {p.text.strip()}" for i, p in enumerate(posts))


def confirm_consensus(
    claimed: Consensus, evidence: Sequence[int], posts: Sequence[WindowPost]
) -> Consensus:
    """`agreed` only when the window proves it; anything else, or an unproven claim, is `stated`.

    Proof is one of: two human authors among the evidence posts; or one evidence post with a
    decision marker that a different human author answers later in the window. Evidence numbers
    outside the window and posts by bots count for nothing."""
    if claimed is not Consensus.AGREED:
        return Consensus.STATED
    cited = sorted({i for i in evidence if 0 <= i < len(posts) and not posts[i].bot})
    if len({posts[i].author for i in cited}) >= 2:  # noqa: PLR2004 - the rule is "two people"
        return Consensus.AGREED
    for i in cited:
        declares = any(marker in posts[i].text for marker in DECISION_MARKERS)
        answered = any(p.author != posts[i].author and not p.bot for p in posts[i + 1 :])
        if declares and answered:
            return Consensus.AGREED
    return Consensus.STATED


def evidence_for(numbers: Sequence[int], posts: Sequence[WindowPost]) -> tuple[Evidence, ...]:
    """The platform data behind the cited post numbers, in window order. A number outside the
    window, a bot's post and a post with no platform data are dropped."""
    cited = sorted({i for i in numbers if 0 <= i < len(posts) and not posts[i].bot})
    return tuple(ref for i in cited if (ref := posts[i].ref) is not None)
