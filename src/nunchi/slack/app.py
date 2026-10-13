"""Slack front end for capture (design v1.2 section 6, spec 3): a pushpin or @mention in a bound
channel runs capture() as the reactor; a proposal that needs a curator is DMed to each curator as an
Approve/Reject card whose click runs app_sec.decide as the clicker. Slack supplies only user ids;
the database decides who they are, which store a channel feeds and whether a click may decide."""

import json
import re
from dataclasses import dataclass
from datetime import date
from typing import Any
from uuid import UUID

from slack_bolt import App

from nunchi.capture import CaptureContext, CaptureResult, Reconfirmed, Rejected, Skipped, capture
from nunchi.db import Conn, Pool, request_tx
from nunchi.domain.models import MemoryOrigin, MemoryStatus, SourceRef
from nunchi.embed import Embedder
from nunchi.extract import ExtractionError, Extractor

PIN = "pushpin"
_MENTION = re.compile(r"<@[A-Z0-9]+>")

SAVED = "저장됨"
RECONFIRMED = "이미 알고 있음 (재확인했습니다)"
CONFLICT = "충돌: 기존 값과 다름 → 큐레이터 검토"
SKIPPED = "저장 안 함: 오래 남길 내용이 아니라고 판단했습니다"
REJECTED = "거부: 비밀값이 들어 있습니다"
EXTRACT_FAILED = "저장 안 함: 내용을 정리하지 못했습니다. 다시 시도해 주세요"
NOT_LINKED = "Slack 계정이 연결되어 있지 않습니다"
UNBOUND = "이 채널은 기억 저장소에 연결되어 있지 않습니다"
NO_SOURCE = "원문을 찾지 못했습니다"

_LINES = {  # decide() result -> (card text, card finished)
    "active": ("승인됨", True),
    "rejected": ("반려됨", True),
    "stale": ("처리 안 함: 카드를 보낸 뒤 내용이 바뀌었습니다", True),
    "expired": ("처리 안 함: 카드가 만료되었습니다", True),
    "wrong_clicker": ("거부: 이 카드를 받은 사람이 아닙니다", False),
    "not_curator": ("거부: 큐레이터가 아닙니다", False),
    "self_review": ("거부: 직접 제안한 항목은 승인할 수 없습니다", False),
}


@dataclass(frozen=True)
class Deps:
    pool: Pool
    extractor: Extractor
    tenant_id: UUID
    client: Any  # slack_sdk WebClient (a fake in tests); every call passes keyword arguments
    embedder: Embedder | None = None


_Dm = tuple[str, str, list[dict[str, Any]]]  # Slack user id, fallback text, blocks


@dataclass(frozen=True)
class _Outcome:
    text: str
    dms: tuple[_Dm, ...] = ()


def resolve(deps: Deps, slack_user: str) -> UUID | None:
    with deps.pool.connection() as conn:
        row = conn.execute(
            "SELECT app_sec.resolve_identity(%s, 'slack', %s)", (deps.tenant_id, slack_user)
        ).fetchone()
    assert row is not None  # noqa: S101 - a SELECT of a function always returns one row
    return row[0]  # type: ignore[return-value]


def _tell(deps: Deps, channel: str, slack_user: str, text: str) -> None:
    deps.client.chat_postEphemeral(channel=channel, user=slack_user, text=text)


def capture_from_slack(  # noqa: PLR0913
    deps: Deps, *, event_id: str, team: str, channel: str, ts: str, slack_user: str
) -> None:
    user = resolve(deps, slack_user)
    if user is None:
        _tell(deps, channel, slack_user, NOT_LINKED)
        return
    page = deps.client.conversations_history(channel=channel, latest=ts, inclusive=True, limit=1)
    messages = page["messages"]
    if not messages or messages[0]["ts"] != ts:
        _tell(deps, channel, slack_user, NO_SOURCE)
        return
    text = _MENTION.sub("", messages[0].get("text", "")).strip()
    link = deps.client.chat_getPermalink(channel=channel, message_ts=ts)["permalink"]
    ref = SourceRef(uri=link, system="slack", workspace_id=team, channel_id=channel)
    try:
        with request_tx(deps.pool, user, None) as conn:
            outcome = _capture(conn, deps, event_id, text, ref)
    except ExtractionError:
        outcome = _Outcome(EXTRACT_FAILED)
    if outcome is None:
        return
    _tell(deps, channel, slack_user, outcome.text)
    for slack_id, label, blocks in outcome.dms:
        deps.client.chat_postMessage(channel=slack_id, text=label, blocks=blocks)


def _capture(conn: Conn, deps: Deps, event_id: str, text: str, ref: SourceRef) -> _Outcome | None:
    """None means Slack redelivered an event that was already handled. The claim shares the
    transaction with the capture, so a failure rolls both back and the retry runs again."""
    claimed = conn.execute("SELECT app_sec.claim_inbound_event(%s)", (event_id,)).fetchone()
    assert claimed is not None  # noqa: S101
    if not claimed[0]:
        return None
    bound = conn.execute(
        "SELECT store_id FROM room_binding WHERE platform = 'slack' AND workspace_id = %s"
        " AND channel_id = %s AND confirmed_by IS NOT NULL AND revoked_at IS NULL",
        (ref.workspace_id, ref.channel_id),
    ).fetchone()
    if bound is None:
        return _Outcome(UNBOUND)
    context = CaptureContext(
        store_id=bound[0], origin=MemoryOrigin.INTERNAL, source_refs=(ref,), today=date.today()
    )
    return _outcome(conn, capture(conn, deps.extractor, text, context, deps.embedder), ref.uri)


def _outcome(conn: Conn, result: CaptureResult, link: str) -> _Outcome:
    if isinstance(result, Skipped):
        return _Outcome(SKIPPED)
    if isinstance(result, Rejected):
        return _Outcome(REJECTED)
    if isinstance(result, Reconfirmed):
        return _Outcome(RECONFIRMED)
    dms = _cards(conn, result.memory_id, link) if result.status is MemoryStatus.PROPOSED else ()
    return _Outcome(CONFLICT if result.conflict_with else SAVED, dms)


def _cards(conn: Conn, memory_id: UUID, link: str) -> tuple[_Dm, ...]:
    row = conn.execute(
        "SELECT m.title, s.confidential, m.version FROM memory AS m"
        " INNER JOIN store AS s ON s.id = m.store_id WHERE m.id = %s",
        (memory_id,),
    ).fetchone()
    assert row is not None  # noqa: S101 - the proposer can read the row it just inserted
    title, confidential, version = row
    # a confidential store's card names the proposal by id only: no title, no source link
    label = f"기밀 store 제안 #{memory_id}" if confidential else str(title)
    shown = label if confidential else f"*{title}*\n<{link}|원문>"
    rows = conn.execute(
        "SELECT card_nonce, slack_user_id FROM app_sec.issue_slack_cards(%s)", (memory_id,)
    ).fetchall()
    cards: list[_Dm] = []
    for nonce, slack_user in rows:
        value = json.dumps({"n": str(nonce), "m": str(memory_id), "v": version})
        buttons = [
            {
                "type": "button",
                "action_id": action,
                "text": {"type": "plain_text", "text": text},
                "value": value,
                "style": style,
            }
            for action, text, style in (
                ("approve", "승인", "primary"),
                ("reject", "반려", "danger"),
            )
        ]
        blocks: list[dict[str, Any]] = [
            {"type": "section", "text": {"type": "mrkdwn", "text": shown}},
            {"type": "actions", "elements": buttons},
        ]
        cards.append((str(slack_user), label, blocks))
    return tuple(cards)


def verdict_line(result: str) -> tuple[str, bool]:
    """The card text for a decide() result, and whether the card is finished (buttons removed)."""
    if result in _LINES:
        return _LINES[result]
    if result.startswith("pending_quorum:"):
        return f"승인 대기 {result.removeprefix('pending_quorum:')}", True
    if result.startswith("duplicate:"):
        return "이미 처리됨", True
    return f"처리 안 됨: {result}", False


def decide_from_card(deps: Deps, body: dict[str, Any]) -> None:
    action = body["actions"][0]
    card = json.loads(action["value"])
    clicker = resolve(deps, body["user"]["id"])
    if clicker is None:
        line, final = NOT_LINKED, False
    else:
        with request_tx(deps.pool, clicker, None) as conn:
            row = conn.execute(
                "SELECT app_sec.decide(%s, %s, %s, %s)",
                (card["n"], card["m"], card["v"], action["action_id"]),
            ).fetchone()
        assert row is not None  # noqa: S101
        line, final = verdict_line(str(row[0]))
    blocks = body["message"]["blocks"]
    kept = [] if final else blocks[1:]
    status = {"type": "context", "elements": [{"type": "mrkdwn", "text": line}]}
    deps.client.chat_update(
        channel=body["channel"]["id"],
        ts=body["message"]["ts"],
        text=line,
        blocks=[blocks[0], status, *kept],
    )


def on_reaction(deps: Deps, body: dict[str, Any]) -> None:
    event = body["event"]
    item = event["item"]
    if event["reaction"] != PIN or item["type"] != "message":
        return
    capture_from_slack(
        deps,
        event_id=body["event_id"],
        team=body["team_id"],
        channel=item["channel"],
        ts=item["ts"],
        slack_user=event["user"],
    )


def on_mention(deps: Deps, body: dict[str, Any]) -> None:
    event = body["event"]
    capture_from_slack(
        deps,
        event_id=body["event_id"],
        team=body["team_id"],
        channel=event["channel"],
        ts=event.get("thread_ts", event["ts"]),
        slack_user=event["user"],
    )


def build_app(deps: Deps, app: App) -> App:
    @app.event("reaction_added")
    def _reaction(body: dict[str, Any]) -> None:
        on_reaction(deps, body)

    @app.event("app_mention")
    def _mention(body: dict[str, Any]) -> None:
        on_mention(deps, body)

    @app.action(re.compile("^(approve|reject)$"))
    def _card(ack: Any, body: dict[str, Any]) -> None:  # noqa: ANN401
        ack()
        decide_from_card(deps, body)

    return app
