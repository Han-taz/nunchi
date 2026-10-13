import asyncio
import logging
from uuid import UUID

from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict
from websockets.asyncio.client import connect
from websockets.exceptions import WebSocketException

from nunchi.config import Settings
from nunchi.db import open_pool
from nunchi.embed import embedder_from_settings
from nunchi.extract import build_extractor
from nunchi.mattermost.client import Mattermost
from nunchi.mattermost.events import Deps
from nunchi.mattermost.ws import listen

log = logging.getLogger(__name__)


class MattermostEnv(BaseSettings):
    # MM_BOT_TOKEN comes from the process environment only
    model_config = SettingsConfigDict(frozen=True, extra="ignore")

    mm_bot_token: SecretStr
    mm_url: str = "http://127.0.0.1:8065"
    mm_site_url: str = "http://127.0.0.1:8065"
    nunchi_tenant_id: UUID


async def run(env: MattermostEnv) -> None:
    token = env.mm_bot_token.get_secret_value()
    client = Mattermost(env.mm_url, token, env.mm_site_url)
    me = client.me()
    settings = Settings()
    deps = Deps(
        open_pool(settings),
        build_extractor(),
        env.nunchi_tenant_id,
        client,
        me["id"],
        me["username"],
        embedder_from_settings(settings),
    )
    url = env.mm_url.replace("http", "ws", 1).rstrip("/") + "/api/v4/websocket"
    while True:
        try:
            await listen(deps, lambda: connect(url), token)
        except (OSError, WebSocketException):
            log.exception("websocket dropped")
        await asyncio.sleep(5)


if __name__ == "__main__":
    asyncio.run(run(MattermostEnv()))
