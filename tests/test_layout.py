import importlib

import pytest


@pytest.mark.parametrize("name", ["domain", "api", "mcp", "slack", "worker", "scim"])
def test_subpackage_is_importable_and_empty(name: str) -> None:
    module = importlib.import_module(f"nunchi.{name}")
    assert [k for k in vars(module) if not k.startswith("__")] == []
