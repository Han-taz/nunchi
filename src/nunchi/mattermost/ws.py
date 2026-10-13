import asyncio
import json
import logging
from collections.abc import Callable
from contextlib import AbstractAsyncContextManager
from typing import Any

from nunchi.mattermost.events import Deps, handle_event

log = logging.getLogger(__name__)


Connect = Callable[[], AbstractAsyncContextManager[Any]]


async def listen(deps: Deps, connect: Connect, token: str) -> None:
    """Authenticate, then hand each event frame to a worker thread (the capture path is blocking).
    Returns when the server closes the connection; the caller reconnects."""
    async with connect() as ws:
        challenge = {"seq": 1, "action": "authentication_challenge", "data": {"token": token}}
        await ws.send(json.dumps(challenge))
        async for raw in ws:
            frame: dict[str, Any] = json.loads(raw)
            if "event" not in frame:
                continue
            try:
                await asyncio.to_thread(handle_event, deps, frame)
            except Exception:
                log.exception("event %s failed", frame["event"])
