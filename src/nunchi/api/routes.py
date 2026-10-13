from http import HTTPStatus
from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response
from pydantic import BaseModel

from nunchi.api.deps import Runner, runner
from nunchi.api.problems import ApiError
from nunchi.domain import repo
from nunchi.domain.models import (
    Memory,
    MemoryKind,
    MemoryStatus,
    MemorySummary,
    MemoryVersion,
    ProposeRequest,
    SearchHit,
    StoreRole,
)


class ProposeOutcomeBody(BaseModel):
    id: UUID
    outcome: Literal["created", "reconfirmed"]


router = APIRouter(prefix="/v1")

Run = Annotated[Runner, Depends(runner)]


def _not_found() -> ApiError:
    return ApiError(HTTPStatus.NOT_FOUND, "memory not found")


def _visible(run: Runner, memory_id: UUID) -> Memory:
    memory = run(lambda c: repo.get(c, memory_id))
    if memory is None:
        raise _not_found()
    return memory


@router.get("/stores")
def list_stores(run: Run) -> list[StoreRole]:
    return run(repo.list_stores)


@router.get("/stores/{store_id}/memories")
def index(store_id: UUID, run: Run) -> list[MemorySummary]:
    return run(lambda c: repo.index(c, store_id))


@router.get("/search")
def search(
    run: Run,
    q: Annotated[str, Query(min_length=1, max_length=500)],
    store: Annotated[list[UUID] | None, Query()] = None,
    kind: Annotated[list[MemoryKind] | None, Query()] = None,
    status: Annotated[list[MemoryStatus] | None, Query()] = None,
) -> list[SearchHit]:
    statuses = status or [MemoryStatus.ACTIVE]
    return run(lambda c: repo.search(c, q, store, kind, statuses))


@router.get("/memories/{memory_id}")
def get_memory(memory_id: UUID, run: Run) -> Memory:
    return _visible(run, memory_id)


@router.post("/memories", responses={HTTPStatus.CREATED: {"model": ProposeOutcomeBody}})
def propose(body: ProposeRequest, run: Run, response: Response) -> ProposeOutcomeBody:
    outcome = run(lambda c: repo.propose(c, body))
    response.status_code = HTTPStatus.CREATED if outcome.kind == "created" else HTTPStatus.OK
    response.headers["Location"] = f"/v1/memories/{outcome.memory_id}"
    return ProposeOutcomeBody(id=outcome.memory_id, outcome=outcome.kind)


@router.get("/memories/{memory_id}/history")
def history(memory_id: UUID, run: Run) -> list[MemoryVersion]:
    _visible(run, memory_id)
    return run(lambda c: repo.history(c, memory_id))


@router.get("/memories/{memory_id}/dependents")
def dependents(memory_id: UUID, run: Run) -> list[MemorySummary]:
    _visible(run, memory_id)
    return run(lambda c: repo.dependents(c, memory_id))


@router.post("/memories/{memory_id}/decision", status_code=HTTPStatus.NOT_IMPLEMENTED)
def decide(memory_id: UUID, run: Run) -> None:
    """Reserved for app_sec.decide, which this PR leaves unwired to stay under the size cap."""
    raise ApiError(HTTPStatus.NOT_IMPLEMENTED, "decide is not implemented")
