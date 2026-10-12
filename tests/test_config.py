import pytest
from pydantic import ValidationError

from nunchi.config import Settings


def test_parses_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("NUNCHI_DATABASE_URL", "postgres://u:hunter2@h/db")
    monkeypatch.setenv("NUNCHI_POOL_MAX_SIZE", "4")
    settings = Settings()
    assert settings.database_url.get_secret_value() == "postgres://u:hunter2@h/db"
    assert settings.pool_min_size == 1
    assert settings.pool_max_size == 4
    assert str(settings.migrations_dir) == "db/migrations"


def test_secret_is_masked_in_repr(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("NUNCHI_DATABASE_URL", "postgres://u:hunter2@h/db")
    settings = Settings()
    assert "hunter2" not in repr(settings)
    assert "hunter2" not in str(settings)


def test_missing_database_url_is_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("NUNCHI_DATABASE_URL", raising=False)
    with pytest.raises(ValidationError, match="database_url"):
        Settings(_env_file=None)


def test_min_above_max_is_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("NUNCHI_DATABASE_URL", "postgres://h/db")
    monkeypatch.setenv("NUNCHI_POOL_MIN_SIZE", "5")
    monkeypatch.setenv("NUNCHI_POOL_MAX_SIZE", "2")
    with pytest.raises(ValidationError, match="must not exceed"):
        Settings()


def test_unknown_field_is_rejected() -> None:
    with pytest.raises(ValidationError, match="extra_forbidden"):
        Settings.model_validate({"database_url": "x", "bogus": 1})


def test_timeouts_default_and_validate() -> None:
    settings = Settings(database_url="postgres://u:p@h/db")
    assert (settings.db_pool_timeout, settings.db_connect_timeout) == (30.0, 10)
    with pytest.raises(ValidationError, match="db_pool_timeout"):
        Settings(database_url="postgres://u:p@h/db", db_pool_timeout=0)
    with pytest.raises(ValidationError, match="db_connect_timeout"):
        Settings(database_url="postgres://u:p@h/db", db_connect_timeout=0)
