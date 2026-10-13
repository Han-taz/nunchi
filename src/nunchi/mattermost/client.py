"""Mattermost REST client: the few calls capture needs. Synchronous, with an injectable transport
so tests run against a fake server and never open a socket."""

from dataclasses import dataclass
from typing import Any

import httpx

from nunchi.domain.models import MemoryOrigin

_BINDABLE = {"O": "public", "P": "private"}


@dataclass(frozen=True)
class RoomFacts:
    """What a channel means for binding and provenance. kind is None for DMs and group messages:
    they are never bindable. A shared channel (Mattermost's Slack Connect) is external."""

    team_id: str
    kind: str | None
    origin: MemoryOrigin


def room_facts(channel: dict[str, Any]) -> RoomFacts:
    kind = _BINDABLE.get(channel["type"])
    shared = bool(channel.get("shared"))
    return RoomFacts(
        team_id=channel.get("team_id", ""),
        kind=None if kind is None else ("connect" if shared else kind),
        origin=MemoryOrigin.EXTERNAL if shared else MemoryOrigin.INTERNAL,
    )


class Mattermost:
    def __init__(
        self,
        base_url: str,
        token: str,
        site_url: str,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self._http = httpx.Client(
            base_url=f"{base_url.rstrip('/')}/api/v4",
            headers={"Authorization": f"Bearer {token}"},
            transport=transport,
            timeout=10,
        )
        self._site = site_url.rstrip("/")
        self._team_names: dict[str, str] = {}

    def _get(self, path: str) -> dict[str, Any]:
        response = self._http.get(path)
        response.raise_for_status()
        return response.json()  # type: ignore[no-any-return]

    def _post(self, path: str, body: dict[str, Any]) -> dict[str, Any]:
        response = self._http.post(path, json=body)
        response.raise_for_status()
        return response.json()  # type: ignore[no-any-return]

    def me(self) -> dict[str, Any]:
        return self._get("/users/me")

    def get_post(self, post_id: str) -> dict[str, Any]:
        return self._get(f"/posts/{post_id}")

    def get_channel(self, channel_id: str) -> dict[str, Any]:
        return self._get(f"/channels/{channel_id}")

    def permalink(self, team_id: str, post_id: str) -> str:
        if team_id not in self._team_names:
            self._team_names[team_id] = self._get(f"/teams/{team_id}")["name"]
        return f"{self._site}/{self._team_names[team_id]}/pl/{post_id}"

    def ephemeral(self, channel_id: str, user_id: str, message: str) -> None:
        self._post(
            "/posts/ephemeral",
            {"user_id": user_id, "post": {"channel_id": channel_id, "message": message}},
        )

    def direct_channel(self, user_a: str, user_b: str) -> str:
        response = self._http.post("/channels/direct", json=[user_a, user_b])
        response.raise_for_status()
        return str(response.json()["id"])
