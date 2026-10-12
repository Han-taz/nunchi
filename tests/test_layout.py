import importlib

import pytest


@pytest.mark.parametrize("name", ["domain", "api", "mcp", "slack", "worker", "scim"])
def test_subpackage_is_importable(name: str) -> None:
    module = importlib.import_module(f"nunchi.{name}")
    assert module.__name__ == f"nunchi.{name}"
    assert module.__path__ is not None
