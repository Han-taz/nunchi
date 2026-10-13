from pathlib import Path
from typing import Annotated, Self

from pydantic import Field, SecretStr, field_validator, model_validator
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
    db_pool_timeout: Annotated[float, Field(gt=0)] = 30.0
    db_connect_timeout: Annotated[int, Field(ge=1)] = 10
    migrations_dir: Path = Path("db/migrations")
    # Unset base URL turns embeddings off; search and capture then run on trigram alone.
    embedding_base_url: str | None = None
    embedding_api_key: SecretStr | None = None
    embedding_model: str = "embeddinggemma-2"
    # memory_embedding.embedding is vector(512); another size needs a migration first.
    embedding_dim: Annotated[int, Field(ge=512, le=512)] = 512
    embedding_timeout: Annotated[float, Field(gt=0)] = 5.0

    @field_validator("embedding_base_url", "embedding_api_key", mode="before")
    @classmethod
    def _blank_is_unset(cls, value: object) -> object:
        return None if value == "" else value

    @model_validator(mode="after")
    def _pool_bounds_are_ordered(self) -> Self:
        if self.pool_min_size > self.pool_max_size:
            msg = "pool_min_size must not exceed pool_max_size"
            raise ValueError(msg)
        return self
