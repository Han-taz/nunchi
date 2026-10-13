import sys
from uuid import UUID

from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

from nunchi.config import Settings
from nunchi.db import open_pool
from nunchi.embed import embedder_from_settings
from nunchi.extract import build_extractor
from nunchi.slack.app import Deps, build_app


class SlackEnv(BaseSettings):
    # SLACK_BOT_TOKEN and SLACK_APP_TOKEN come from the process environment only
    model_config = SettingsConfigDict(frozen=True, extra="ignore")

    slack_bot_token: SecretStr
    slack_app_token: SecretStr
    nunchi_tenant_id: UUID


def main() -> int:
    env = SlackEnv()
    app = App(token=env.slack_bot_token.get_secret_value())
    settings = Settings()
    deps = Deps(
        open_pool(settings),
        build_extractor(),
        env.nunchi_tenant_id,
        app.client,
        embedder_from_settings(settings),
    )
    build_app(deps, app)
    SocketModeHandler(app, env.slack_app_token.get_secret_value()).start()  # type: ignore[no-untyped-call]
    return 0


if __name__ == "__main__":
    sys.exit(main())
