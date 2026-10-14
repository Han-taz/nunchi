"""Mattermost front end for capture, wired like the Slack module: a pushpin reaction or an @mention
runs capture() as the reactor. Mattermost supplies only user, post and channel ids; the database
decides who they are and which store a channel feeds. The reply is an ephemeral post."""

import json
import re
from dataclasses import dataclass
from datetime import UTC, date, datetime
from typing import Any
from uuid import UUID

import httpx

from nunchi.capture import (
    CaptureContext,
    CaptureResult,
    Created,
    Reconfirmed,
    Rejected,
    Retracted,
    Skipped,
    capture,
)
from nunchi.db import Conn, Pool, request_tx
from nunchi.domain.models import Evidence, MemoryOrigin, MemoryStatus, SourceRef
from nunchi.embed import Embedder
from nunchi.extract import Consensus, ExtractionError, Extractor, ValueJudge
from nunchi.mattermost.client import Mattermost, room_facts

PIN = "pushpin"

SAVED_PROVISIONAL = (
    "저장됨: 기간 안에 이의가 없으면 확정됩니다. 다른 분이 같은 내용을 말하면 바로 확정됩니다"
)
SAVED_AGREED = "저장됨: 두 분이 동의한 내용이라 바로 확정했습니다"
CHALLENGED = "기존 값과 달라 대기 중: 다른 분이 동의하거나 기간 안에 이의가 없으면 바뀝니다"
SUPERSEDED = "기존 값을 새 값으로 바꿨습니다"
CONFIRMED = "다른 분의 말로 확정됐습니다"
RECONFIRMED = "이미 알고 있음 (재확인했습니다)"
RETRACTED = "철회했습니다"
SKIPPED = "저장 안 함: 오래 남길 내용이 아니라고 판단했습니다"
REJECTED = "거부: 비밀값이 들어 있습니다"
EXTRACT_FAILED = "저장 안 함: 내용을 정리하지 못했습니다. 다시 시도해 주세요"
NOT_LINKED = "Mattermost 계정이 연결되어 있지 않습니다"
UNBOUND = "이 채널은 기억 저장소에 연결되어 있지 않습니다"
NO_SOURCE = "원문을 찾지 못했습니다"


@dataclass(frozen=True)
class Deps:
    pool: Pool
    extractor: Extractor
    tenant_id: UUID
    client: Mattermost
    bot_user_id: str
    bot_username: str
    embedder: Embedder | None = None
    judge: ValueJudge | None = None


@dataclass(frozen=True)
class _Outcome:
    text: str


def resolve(deps: Deps, user_id: str) -> UUID | None:
    with deps.pool.connection() as conn:
        row = conn.execute(
            "SELECT app_sec.resolve_identity(%s, 'mattermost', %s)", (deps.tenant_id, user_id)
        ).fetchone()
    assert row is not None  # noqa: S101 - a SELECT of a function always returns one row
    return row[0]  # type: ignore[return-value]


def capture_post(deps: Deps, *, event_id: str, user_id: str, channel_id: str, post_id: str) -> None:
    """channel_id is where the reply goes; the captured post may live elsewhere only in name."""
    tell = deps.client.ephemeral
    user = resolve(deps, user_id)
    if user is None:
        tell(channel_id, user_id, NOT_LINKED)
        return
    try:
        post = deps.client.get_post(post_id)
        channel = deps.client.get_channel(post["channel_id"])
    except httpx.HTTPStatusError:
        tell(channel_id, user_id, NO_SOURCE)
        return
    facts = room_facts(channel)
    if facts.kind is None:
        tell(channel_id, user_id, UNBOUND)
        return
    text = re.sub(rf"@{re.escape(deps.bot_username)}\b", "", post.get("message", "")).strip()
    link = deps.client.permalink(facts.team_id, post["id"])
    ref = SourceRef(
        uri=link, system="mattermost", workspace_id=facts.team_id, channel_id=post["channel_id"]
    )
    consensus, evidence = _who_said(deps, post, actor=user_id, link=link)
    context = (ref, consensus, evidence)
    try:
        with request_tx(deps.pool, user, None) as conn:
            outcome = _capture(conn, deps, event_id, text, context, facts.origin)
    except ExtractionError:
        outcome = _Outcome(EXTRACT_FAILED)
    if outcome is None:
        return
    tell(channel_id, user_id, outcome.text)


def _who_said(
    deps: Deps, post: dict[str, Any], *, actor: str, link: str
) -> tuple[Consensus, tuple[Evidence, ...]]:
    """The author's post is evidence. Someone else pinning or mentioning it is a second person
    agreeing (design v1.3 4.2); the author doing it to their own post, or anyone to the bot's,
    is one voice."""
    author = post["user_id"]
    try:
        names = deps.client.users(sorted({author, actor}))
    except httpx.HTTPError:
        names = {}
    said = datetime.fromtimestamp(post["create_at"] / 1000, UTC)
    evidence = (
        Evidence(
            uri=link,
            post_id=post["id"],
            author=author,
            author_name=names[author].name if author in names else None,
            said_at=said,
        ),
    )
    if author in (actor, deps.bot_user_id):
        return Consensus.STATED, evidence
    agreement = Evidence(
        uri=link,
        post_id=f"{post['id']}:{actor}",
        author=actor,
        author_name=names[actor].name if actor in names else None,
        said_at=datetime.now(UTC),
    )
    return Consensus.AGREED, (*evidence, agreement)


def _capture(  # noqa: PLR0913, PLR0917
    conn: Conn,
    deps: Deps,
    event_id: str,
    text: str,
    said: tuple[SourceRef, Consensus, tuple[Evidence, ...]],
    origin: MemoryOrigin,
) -> _Outcome | None:
    """None means the event was redelivered and already handled. The claim shares the transaction
    with the capture, so a failure rolls both back and the retry runs again."""
    ref, consensus, evidence = said
    claimed = conn.execute("SELECT app_sec.claim_inbound_event(%s)", (event_id,)).fetchone()
    assert claimed is not None  # noqa: S101
    if not claimed[0]:
        return None
    bound = conn.execute(
        "SELECT store_id FROM room_binding WHERE platform = 'mattermost' AND workspace_id = %s"
        " AND channel_id = %s AND confirmed_by IS NOT NULL AND revoked_at IS NULL",
        (ref.workspace_id, ref.channel_id),
    ).fetchone()
    if bound is None:
        return _Outcome(UNBOUND)
    context = CaptureContext(
        store_id=bound[0],
        origin=origin,
        source_refs=(ref,),
        today=date.today(),
        consensus=consensus,
        evidence=evidence,
    )
    result = capture(conn, deps.extractor, text, context, deps.embedder, judge=deps.judge)
    return _Outcome(_reply(result))


def _reply(result: CaptureResult) -> str:  # noqa: PLR0911 - one line per outcome
    match result:
        case Skipped():
            return SKIPPED
        case Rejected():
            return REJECTED
        case Reconfirmed(confirmed=True):
            return CONFIRMED
        case Reconfirmed():
            return RECONFIRMED
        case Retracted():
            return RETRACTED
        case Created(change="challenged"):
            return CHALLENGED
        case Created(change="superseded"):
            return SUPERSEDED
        case Created(status=MemoryStatus.ACTIVE):
            return SAVED_AGREED
        case _:
            return SAVED_PROVISIONAL


def handle_event(deps: Deps, event: dict[str, Any]) -> None:
    """One websocket frame. Dedup keys use post+user+emoji because seq restarts on reconnect."""
    data = event.get("data", {})
    channel = event.get("broadcast", {}).get("channel_id", "")
    match event.get("event"):
        case "reaction_added":
            reaction = json.loads(data["reaction"])
            if reaction["emoji_name"] != PIN:
                return
            capture_post(
                deps,
                event_id=f"mm:{reaction['post_id']}:{reaction['user_id']}:{PIN}",
                user_id=reaction["user_id"],
                channel_id=channel,
                post_id=reaction["post_id"],
            )
        case "posted":
            post = json.loads(data["post"])
            mention = re.search(rf"@{re.escape(deps.bot_username)}\b", post["message"])
            if post["user_id"] == deps.bot_user_id or mention is None:
                return
            capture_post(
                deps,
                event_id=f"mm:{post['id']}:{post['user_id']}:mention",
                user_id=post["user_id"],
                channel_id=post["channel_id"],
                post_id=post["root_id"] or post["id"],
            )
