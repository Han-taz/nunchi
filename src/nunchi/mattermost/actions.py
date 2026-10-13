"""The interactive-button endpoint, served by a small Starlette app in the bot process. A click is
trusted only through its HMAC; the clicker is the user_id in the request body, resolved through
principal_identity, and app_sec.decide runs as that person."""

import asyncio
import hmac
from typing import Any

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from nunchi.db import request_tx
from nunchi.mattermost.cards import VERDICTS, sign, verdict_line
from nunchi.mattermost.events import NOT_LINKED, Deps, resolve


def _signed(deps: Deps, ctx: dict[str, Any]) -> bool:
    try:
        expected = sign(deps.cards.secret, ctx["n"], ctx["m"], int(ctx["v"]), ctx["a"])
        return hmac.compare_digest(expected, str(ctx["sig"])) and ctx["a"] in VERDICTS
    except (KeyError, TypeError, ValueError):
        return False


def decide_from_action(deps: Deps, body: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    ctx = body.get("context")
    if not isinstance(ctx, dict) or not _signed(deps, ctx):
        return 403, {"error": "bad signature"}
    clicker = resolve(deps, str(body.get("user_id", "")))
    if clicker is None:
        line, final = NOT_LINKED, False
    else:
        with request_tx(deps.pool, clicker, None) as conn:
            row = conn.execute(
                "SELECT app_sec.decide(%s, %s, %s, %s)", (ctx["n"], ctx["m"], ctx["v"], ctx["a"])
            ).fetchone()
        assert row is not None  # noqa: S101 - a SELECT of a function always returns one row
        line, final = verdict_line(str(row[0]))
    card = dict(deps.client.get_post(body["post_id"])["props"]["attachments"][0])
    card["footer"] = line
    if final:
        card.pop("actions", None)
    return 200, {"update": {"props": {"attachments": [card]}}}


async def _action(request: Request) -> JSONResponse:
    deps: Deps = request.app.state.deps
    status, payload = await asyncio.to_thread(decide_from_action, deps, await request.json())
    return JSONResponse(payload, status_code=status)


def create(deps: Deps) -> Starlette:
    app = Starlette(routes=[Route("/actions", _action, methods=["POST"])])
    app.state.deps = deps
    return app
