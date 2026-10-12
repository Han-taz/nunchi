import os
import uuid
from collections.abc import Iterator
from pathlib import Path

import psycopg
import pytest
from psycopg import sql

REPO = Path(__file__).resolve().parent.parent
APP_ROLE = "nunchi_test_app"


@pytest.fixture(scope="session")
def admin_url() -> str:
    url = os.environ.get("NUNCHI_TEST_ADMIN_URL")
    if url is None:
        pytest.skip("NUNCHI_TEST_ADMIN_URL is not set")
    return url


@pytest.fixture
def fresh_db(admin_url: str) -> Iterator[str]:
    """A new empty database on the test server. Yields its superuser URL."""
    name = f"nunchi_t_{uuid.uuid4().hex[:12]}"
    base, _, query = admin_url.partition("?")
    with psycopg.connect(admin_url, autocommit=True) as admin:
        admin.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(name)))
        try:
            suffix = f"?{query}" if query else ""
            yield f"{base.rsplit('/', 1)[0]}/{name}{suffix}"
        finally:
            admin.execute(sql.SQL("DROP DATABASE {} WITH (FORCE)").format(sql.Identifier(name)))
