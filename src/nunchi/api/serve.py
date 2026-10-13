"""uvicorn entry point: `uvicorn --factory nunchi.api.serve:create`, configured by NUNCHI_* env."""

from fastapi import FastAPI

from nunchi.api.app import create_app
from nunchi.auth.tokens import OidcSettings, TokenVerifier
from nunchi.config import Settings
from nunchi.db import open_pool


def create() -> FastAPI:
    return create_app(open_pool(Settings()), TokenVerifier(OidcSettings()))
