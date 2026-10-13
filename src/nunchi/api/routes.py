from http import HTTPStatus
from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response
from pydantic import BaseModel, ConfigDict, Field

from nunchi.api.deps import Runner, identity, runner
from nunchi.api.problems import ApiError
from nunchi.auth.identity import Identity
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


class DecideRequest(BaseModel):
    decision: Literal["approve", "reject"]
    expected_version: int
    nonce: UUID | None = None


class DecisionBody(BaseModel):
    outcome: Literal["active", "rejected", "pending_quorum"]
    have: int | None = None
    needed: int | None = None


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
    outcome = run(lambda c: repo.propose(c, body.model_copy(update={"gate_flags": ()})))
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


REFUSALS: dict[str, HTTPStatus] = {
    "unknown_nonce": HTTPStatus.NOT_FOUND,
    "wrong_clicker": HTTPStatus.FORBIDDEN,
    "not_curator": HTTPStatus.FORBIDDEN,
    "self_review": HTTPStatus.FORBIDDEN,
    "stale": HTTPStatus.CONFLICT,
    "mismatch": HTTPStatus.CONFLICT,
    "expired": HTTPStatus.CONFLICT,
    "duplicate": HTTPStatus.CONFLICT,
}


def _decision_body(answer: str) -> DecisionBody:
    if answer in ("active", "rejected"):
        return DecisionBody(outcome=answer)
    if answer.startswith("pending_quorum:"):
        have, _, needed = answer.removeprefix("pending_quorum:").partition("/")
        return DecisionBody(outcome="pending_quorum", have=int(have), needed=int(needed))
    refusal = answer.partition(":")[0]
    raise ApiError(REFUSALS.get(refusal, HTTPStatus.CONFLICT), answer)


@router.post("/memories/{memory_id}/decide")
def decide(
    memory_id: UUID, body: DecideRequest, run: Run, who: Annotated[Identity, Depends(identity)]
) -> DecisionBody:
    """Humans decide; an agent identity never does, whatever its grants."""
    if who.agent_id is not None:
        raise ApiError(HTTPStatus.FORBIDDEN, "agents cannot decide")
    answer = run(
        lambda c: repo.decide(c, memory_id, body.nonce, body.decision, body.expected_version)
    )
    return _decision_body(answer)
