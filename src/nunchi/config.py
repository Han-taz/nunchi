from pathlib import Path
from typing import Annotated, Self

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Process configuration, read from NUNCHI_* environment variables.

    Secrets are SecretStr so repr() and logs never show them. Nothing here
    reads the macOS Keychain; the process environment is the only source.
    """

    model_config = SettingsConfigDict(env_prefix="NUNCHI_", frozen=True, extra="forbid")

    database_url: SecretStr
    pool_min_size: Annotated[int, Field(ge=1)] = 1
    pool_max_size: Annotated[int, Field(ge=1)] = 10
    migrations_dir: Path = Path("db/migrations")

    @model_validator(mode="after")
    def _pool_bounds_are_ordered(self) -> Self:
        if self.pool_min_size > self.pool_max_size:
            msg = "pool_min_size must not exceed pool_max_size"
            raise ValueError(msg)
        return self
