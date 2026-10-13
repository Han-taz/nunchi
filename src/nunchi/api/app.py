from fastapi import FastAPI

from nunchi.api import problems
from nunchi.api.routes import router
from nunchi.auth.tokens import TokenVerifier
from nunchi.db import Pool


def create_app(pool: Pool, verifier: TokenVerifier) -> FastAPI:
    app = FastAPI(docs_url=None, redoc_url=None)
    app.state.pool = pool
    app.state.verifier = verifier
    problems.install(app)
    app.include_router(router)
    return app
