"""Mattermost front end for capture, wired like the Slack module: a pushpin reaction or an @mention
runs capture() as the reactor. Mattermost supplies only user, post and channel ids; the database
decides who they are and which store a channel feeds. The reply is an ephemeral post."""

import json
import re
from dataclasses import dataclass
from datetime import date
from typing import Any
from uuid import UUID

import httpx

from nunchi.capture import CaptureContext, CaptureResult, Reconfirmed, Rejected, Skipped, capture
from nunchi.db import Conn, Pool, request_tx
from nunchi.domain.models import MemoryOrigin, SourceRef
from nunchi.embed import Embedder
from nunchi.extract import ExtractionError, Extractor
from nunchi.mattermost.client import Mattermost, room_facts

PIN = "pushpin"

SAVED = "저장됨"
RECONFIRMED = "이미 알고 있음 (재확인했습니다)"
CONFLICT = "충돌: 기존 값과 다름 → 큐레이터 검토"
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
    try:
        with request_tx(deps.pool, user, None) as conn:
            reply = _capture(conn, deps, event_id, text, ref, facts.origin)
    except ExtractionError:
        reply = EXTRACT_FAILED
    if reply is not None:
        tell(channel_id, user_id, reply)


def _capture(  # noqa: PLR0913, PLR0917
    conn: Conn, deps: Deps, event_id: str, text: str, ref: SourceRef, origin: MemoryOrigin
) -> str | None:
    """None means the event was redelivered and already handled. The claim shares the transaction
    with the capture, so a failure rolls both back and the retry runs again."""
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
        return UNBOUND
    context = CaptureContext(
        store_id=bound[0], origin=origin, source_refs=(ref,), today=date.today()
    )
    return _reply(capture(conn, deps.extractor, text, context, deps.embedder))


def _reply(result: CaptureResult) -> str:
    if isinstance(result, Skipped):
        return SKIPPED
    if isinstance(result, Rejected):
        return REJECTED
    if isinstance(result, Reconfirmed):
        return RECONFIRMED
    return CONFLICT if result.conflict_with else SAVED


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
