from http import HTTPStatus
from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response
from pydantic import BaseModel, ConfigDict, Field

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


class ClientProposal(ProposeRequest):
    """REST body: gate_flags and gate_result are accepted, then dropped (server-owned)."""

    model_config = ConfigDict(extra="forbid")
    gate_result: dict[str, object] | None = Field(default=None, exclude=True)


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
def propose(body: ClientProposal, run: Run, response: Response) -> ProposeOutcomeBody:
    outcome = run(lambda c: repo.remember(c, body.model_copy(update={"gate_flags": ()})))
    created = outcome.kind in ("created", "challenged", "superseded")
    response.status_code = HTTPStatus.CREATED if created else HTTPStatus.OK
    response.headers["Location"] = f"/v1/memories/{outcome.memory_id}"
    return ProposeOutcomeBody(id=outcome.memory_id, outcome="created" if created else "reconfirmed")


@router.get("/memories/{memory_id}/history")
def history(memory_id: UUID, run: Run) -> list[MemoryVersion]:
    _visible(run, memory_id)
    return run(lambda c: repo.history(c, memory_id))


@router.get("/memories/{memory_id}/dependents")
def dependents(memory_id: UUID, run: Run) -> list[MemorySummary]:
    _visible(run, memory_id)
    return run(lambda c: repo.dependents(c, memory_id))
