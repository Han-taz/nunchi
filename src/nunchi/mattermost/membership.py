"""Room membership refresh. Containment turns unverified 90 minutes after the oldest membership
snapshot row, so every live Mattermost binding gets a fresh snapshot each pass. The snapshot is
replaced as a whole through app_sec.replace_room_members, as the bot principal."""

import logging

import httpx

from nunchi.db import request_tx
from nunchi.mattermost.digest import Digest, bot_principal

log = logging.getLogger(__name__)


def refresh_memberships(d: Digest) -> int:
    """Returns how many bindings got a fresh snapshot; an unreadable channel keeps its old one."""
    me = bot_principal(d)
    if me is None:
        log.warning("membership: the bot has no linked principal; nothing refreshed")
        return 0
    with request_tx(d.pool, me, None) as conn:
        bindings = conn.execute(
            "SELECT id, channel_id FROM room_binding WHERE platform = 'mattermost'"
            " AND confirmed_by IS NOT NULL AND revoked_at IS NULL ORDER BY id"
        ).fetchall()
    refreshed = 0
    for binding_id, channel_id in bindings:
        try:
            members = d.client.channel_member_ids(str(channel_id))
            external = sorted(d.client.remote_users(members)) if members else []
        except httpx.HTTPError:
            log.exception("membership: channel %s unreadable", channel_id)
            continue
        if not members:
            log.warning("membership: channel %s returned no members; snapshot kept", channel_id)
            continue
        with request_tx(d.pool, me, None) as conn:
            conn.execute(
                "SELECT app_sec.replace_room_members(%s, %s, %s)", (binding_id, members, external)
            )
        refreshed += 1
    return refreshed
