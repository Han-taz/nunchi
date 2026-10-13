import asyncio
import logging
from uuid import UUID

from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict
from uvicorn import Config, Server
from websockets.asyncio.client import connect
from websockets.exceptions import WebSocketException

from nunchi.config import Settings
from nunchi.db import open_pool
from nunchi.embed import embedder_from_settings
from nunchi.extract import build_extractor, build_judge
from nunchi.mattermost import actions
from nunchi.mattermost.cards import CardConfig
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
    mm_action_secret: SecretStr
    mm_action_url: str = "http://host.docker.internal:8787/actions"
    mm_action_host: str = "0.0.0.0"  # noqa: S104 - the Mattermost container calls in from the docker network
    mm_action_port: int = 8787


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
        CardConfig(env.mm_action_url, env.mm_action_secret.get_secret_value().encode()),
        embedder_from_settings(settings),
        build_judge(),
    )
    server = Server(Config(actions.create(deps), host=env.mm_action_host, port=env.mm_action_port))
    url = env.mm_url.replace("http", "ws", 1).rstrip("/") + "/api/v4/websocket"

    async def reconnect() -> None:
        while True:
            try:
                await listen(deps, lambda: connect(url), token)
            except (OSError, WebSocketException):
                log.exception("websocket dropped")
            await asyncio.sleep(5)

    await asyncio.gather(server.serve(), reconnect())


if __name__ == "__main__":
    asyncio.run(run(MattermostEnv()))
