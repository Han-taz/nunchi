import json

import pytest
from fastapi.testclient import TestClient

from nunchi.api.serve import create
from tests.conftest import TENANT


@pytest.mark.db
def test_create_builds_the_app_from_env(seeded: str, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("NUNCHI_DATABASE_URL", seeded)
    monkeypatch.setenv(
        "NUNCHI_OIDC_ISSUERS",
        json.dumps({"https://i": {"tenant_id": str(TENANT), "jwks_url": "https://i/jwks"}}),
    )
    app = create()
    try:
        assert TestClient(app).get("/v1/stores").status_code == 401
    finally:
        app.state.pool.close()
