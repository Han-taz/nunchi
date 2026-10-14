"""Mattermost REST client: the few calls capture needs. Synchronous, with an injectable transport
so tests run against a fake server and never open a socket."""

from collections.abc import Iterator
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

    def _get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        response = self._http.get(path, params=params)
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

    def channel_posts(
        self, channel_id: str, since: int, per_page: int = 200
    ) -> Iterator[dict[str, Any]]:
        """Posts changed since `since` (ms), paged, as the server returns them. Stops when a page
        adds no post it has not shown, so a server that ignores `page` cannot loop forever."""
        seen: set[str] = set()
        page = 0
        while True:
            body = self._get(
                f"/channels/{channel_id}/posts",
                {"since": since, "page": page, "per_page": per_page},
            )
            fresh = [i for i in body["order"] if i not in seen]
            seen.update(fresh)
            yield from (body["posts"][i] for i in fresh)
            if len(body["order"]) < per_page or not fresh:
                return
            page += 1

    def channel_member_ids(self, channel_id: str, per_page: int = 200) -> list[str]:
        ids: list[str] = []
        page = 0
        while True:
            response = self._http.get(
                f"/channels/{channel_id}/members", params={"page": page, "per_page": per_page}
            )
            response.raise_for_status()
            rows = response.json()
            ids += [m["user_id"] for m in rows if m["user_id"] not in ids]
            if len(rows) < per_page:
                return ids
            page += 1

    def remote_users(self, user_ids: list[str]) -> set[str]:
        """Users that belong to another Mattermost server (shared channels): external members."""
        response = self._http.post("/users/ids", json=user_ids)
        response.raise_for_status()
        return {u["id"] for u in response.json() if u.get("remote_id")}

    def thread(self, root_id: str) -> list[dict[str, Any]]:
        body = self._get(f"/posts/{root_id}/thread")
        return list(body["posts"].values())

    def usernames(self, user_ids: list[str]) -> dict[str, str]:
        response = self._http.post("/users/ids", json=user_ids)
        response.raise_for_status()
        return {u["id"]: u["username"] for u in response.json()}
