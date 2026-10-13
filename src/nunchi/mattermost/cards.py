"""Curator approval cards as Mattermost message attachments. A card is a DM with two buttons whose
context carries (nonce, memory, version, verdict) and an HMAC over them: Mattermost does not sign
action calls, so the signature is what proves a click context came from this process."""

import hashlib
import hmac
from dataclasses import dataclass
from typing import Any
from uuid import UUID

from nunchi.db import Conn

VERDICTS = ("approve", "reject")
_BUTTONS = (("approve", "승인", "primary"), ("reject", "거절", "danger"))

_LINES = {  # decide() result -> (card text, card finished)
    "active": ("승인됨", True),
    "rejected": ("거절됨", True),
    "stale": ("처리 안 함: 카드를 보낸 뒤 내용이 바뀌었습니다", True),
    "expired": ("처리 안 함: 카드가 만료되었습니다", True),
    "wrong_clicker": ("거부: 이 카드를 받은 사람이 아닙니다", False),
    "not_curator": ("거부: 큐레이터가 아닙니다", False),
    "self_review": ("거부: 직접 제안한 항목은 승인할 수 없습니다", False),
}


@dataclass(frozen=True)
class CardConfig:
    action_url: str
    secret: bytes


@dataclass(frozen=True)
class Card:
    mattermost_user: str
    attachment: dict[str, Any]


@dataclass(frozen=True)
class PendingCard:
    nonce: UUID
    card: Card


def sign(secret: bytes, nonce: str, memory: str, version: int, verdict: str) -> str:
    message = f"{nonce}|{memory}|{version}|{verdict}".encode()
    return hmac.new(secret, message, hashlib.sha256).hexdigest()


def build_cards(conn: Conn, config: CardConfig, memory_id: UUID, link: str) -> tuple[Card, ...]:
    row = conn.execute(
        "SELECT m.title, s.confidential, m.version FROM memory AS m"
        " INNER JOIN store AS s ON s.id = m.store_id WHERE m.id = %s",
        (memory_id,),
    ).fetchone()
    assert row is not None  # noqa: S101 - the proposer can read the row it just inserted
    title, confidential, version = row
    assert isinstance(version, int)  # noqa: S101
    # a confidential store's card names the proposal by id only: no title, no source link
    shown = f"기밀 store 제안 #{memory_id}" if confidential else f"**{title}**\n[원문]({link})"
    rows = conn.execute(
        "SELECT card_nonce, platform_user_id FROM app_sec.issue_dm_cards(%s, 'mattermost')",
        (memory_id,),
    ).fetchall()
    return tuple(
        Card(str(user), _attachment(config, shown, str(nonce), str(memory_id), version))
        for nonce, user in rows
    )


def pending_cards(conn: Conn, config: CardConfig) -> tuple[PendingCard, ...]:
    """Cards owed for the caller's proposed memories that no DM has carried yet. Issues the missing
    ones first, so a proposal made by a batch job (the digest) reaches its curators on the next
    sweep, and a card whose DM failed is offered again."""
    owed = conn.execute(
        "SELECT card_nonce, memory_id, version, platform_user_id"
        " FROM app_sec.pending_dm_cards('mattermost')"
    ).fetchall()
    out: list[PendingCard] = []
    for nonce, memory_id, version, user in owed:
        assert isinstance(memory_id, UUID)  # noqa: S101
        assert isinstance(version, int)  # noqa: S101
        row = conn.execute(
            "SELECT m.title, s.confidential, m.source_refs -> 0 ->> 'uri' FROM memory AS m"
            " INNER JOIN store AS s ON s.id = m.store_id WHERE m.id = %s",
            (memory_id,),
        ).fetchone()
        assert row is not None  # noqa: S101 - the proposer can read its own memory
        title, confidential, link = row
        shown = f"기밀 store 제안 #{memory_id}" if confidential else f"**{title}**\n[원문]({link})"
        attachment = _attachment(config, shown, str(nonce), str(memory_id), version)
        out.append(PendingCard(UUID(str(nonce)), Card(str(user), attachment)))
    return tuple(out)


def _attachment(
    config: CardConfig, shown: str, nonce: str, memory: str, version: int
) -> dict[str, Any]:
    actions = [
        {
            "id": verdict,
            "name": name,
            "style": style,
            "integration": {
                "url": config.action_url,
                "context": {
                    "n": nonce,
                    "m": memory,
                    "v": version,
                    "a": verdict,
                    "sig": sign(config.secret, nonce, memory, version, verdict),
                },
            },
        }
        for verdict, name, style in _BUTTONS
    ]
    return {"text": shown, "actions": actions}


def verdict_line(result: str) -> tuple[str, bool]:
    """The card text for a decide() result, and whether the card is finished (buttons removed)."""
    if result in _LINES:
        return _LINES[result]
    if result.startswith("pending_quorum:"):
        return f"승인 대기 {result.removeprefix('pending_quorum:')}", True
    if result.startswith("duplicate:"):
        return "이미 처리됨", True
    return f"처리 안 됨: {result}", False
