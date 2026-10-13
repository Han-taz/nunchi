"""One place that turns failures into RFC 9457 problem+json responses."""

from http import HTTPStatus

import psycopg
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from nunchi.auth.tokens import AuthError

PROBLEM_JSON = "application/problem+json"

SQLSTATE_STATUS: dict[str, HTTPStatus] = {
    "42501": HTTPStatus.FORBIDDEN,
    "23505": HTTPStatus.CONFLICT,
    "23503": HTTPStatus.NOT_FOUND,
    "28000": HTTPStatus.UNAUTHORIZED,
    "P0001": HTTPStatus.CONFLICT,
    "40001": HTTPStatus.SERVICE_UNAVAILABLE,
    "23514": HTTPStatus.UNPROCESSABLE_ENTITY,
}


class ApiError(Exception):
    def __init__(self, status: HTTPStatus, detail: str) -> None:
        super().__init__(detail)
        self.status = status
        self.detail = detail


def problem(status: HTTPStatus, detail: str, headers: dict[str, str] | None = None) -> JSONResponse:
    return JSONResponse(
        {"type": "about:blank", "title": status.phrase, "status": status.value, "detail": detail},
        status_code=status.value,
        media_type=PROBLEM_JSON,
        headers=headers,
    )


def _unauthorized() -> JSONResponse:
    return problem(
        HTTPStatus.UNAUTHORIZED,
        "authentication failed",
        {"WWW-Authenticate": "Bearer"},
    )


def install(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    def _api(_: Request, exc: ApiError) -> JSONResponse:
        return problem(exc.status, exc.detail)

    @app.exception_handler(AuthError)
    def _auth(_: Request, __: AuthError) -> JSONResponse:
        return _unauthorized()

    @app.exception_handler(psycopg.Error)
    def _db(_: Request, exc: psycopg.Error) -> JSONResponse:
        status = SQLSTATE_STATUS.get(exc.sqlstate or "", HTTPStatus.INTERNAL_SERVER_ERROR)
        if status is HTTPStatus.UNAUTHORIZED:
            return _unauthorized()
        detail = (
            status.phrase if status is HTTPStatus.INTERNAL_SERVER_ERROR else str(exc).split("\n")[0]
        )
        return problem(status, detail)

    @app.exception_handler(RequestValidationError)
    def _invalid(_: Request, exc: RequestValidationError) -> JSONResponse:
        first = exc.errors()[0]
        where = ".".join(str(p) for p in first["loc"])
        return problem(HTTPStatus.UNPROCESSABLE_ENTITY, f"{where}: {first['msg']}")

    @app.exception_handler(StarletteHTTPException)
    def _http(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        return problem(HTTPStatus(exc.status_code), str(exc.detail))
