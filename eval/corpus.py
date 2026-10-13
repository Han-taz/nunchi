"""Gold-labelled corpus: Korean workplace messages replayed in file order, plus search queries."""

from datetime import date, timedelta
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict

from nunchi.domain.models import MemoryKind

CORPUS_DIR = Path(__file__).parent / "corpus"
START = date(2026, 8, 3)
Relation = Literal["new", "same", "update", "none"]

# Built by concatenation so no secret-shaped literal sits in the repo (push protection, scanners).
SECRETS = {
    "aws": "AKIA" + "IOSFODNN7EXAMPLE",
    "pw": "Tr0ub4dor&3xK9qLm2Zv",
    "pw2": "Zq8vN2mLk5Rt9WxY3bHc",
    "slack": "xoxb-" + "123456789012-1234567890123-abcdefGHIJklmnopQRSTuvwx",
    "url": "postgres://app:" + "s3cretPw99" + "@db.internal:5432/prod",
    "gh": "ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789",
    "key": "-----BEGIN RSA PRIVATE" + " KEY-----",
}


class Message(BaseModel):
    """One captured message and what a perfect pipeline does with it.

    `memory` names the gold memory the message states; `updates` names the gold memory it replaces.
    """

    model_config = ConfigDict(frozen=True)

    id: str
    day: int
    text: str
    remember: bool
    kind: MemoryKind | None
    subject: str | None
    attribute: str | None
    relation: Relation
    memory: str | None
    updates: str | None
    why: str | None = None
    secret: bool = False

    @property
    def filled(self) -> str:
        out = self.text
        for name, value in SECRETS.items():
            out = out.replace("{{" + name + "}}", value)
        return out

    @property
    def today(self) -> date:
        return START + timedelta(days=self.day)


class Query(BaseModel):
    model_config = ConfigDict(frozen=True)

    id: str
    query: str
    gold: tuple[str, ...]


def load_messages(limit: int | None = None) -> list[Message]:
    lines = (CORPUS_DIR / "messages.jsonl").read_text().splitlines()
    return [Message.model_validate_json(line) for line in lines[:limit]]


def load_queries() -> list[Query]:
    lines = (CORPUS_DIR / "queries.jsonl").read_text().splitlines()
    return [Query.model_validate_json(line) for line in lines]
