"""E2E memory story over MCP. `keys DIR` writes a JWKS; `run DIR URL` plays the story."""

import asyncio
import json
import sys
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import jwt
from jwt.algorithms import RSAAlgorithm
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

ISSUER = "https://dev-idp.test"
STORE = "00000000-0000-4000-8000-0000000000b1"
SOURCE = [{"uri": "https://example.test/e2e"}]


def write_jwks(directory: Path) -> None:
    """Publish the public half of directory/private.pem as a JWKS for the compose `jwks` service."""
    algorithm = RSAAlgorithm(RSAAlgorithm.SHA256)
    public = algorithm.prepare_key((directory / "private.pem").read_bytes()).public_key()
    jwk = json.loads(algorithm.to_jwk(public))
    (directory / "jwks").mkdir(exist_ok=True)
    (directory / "jwks" / "jwks.json").write_text(
        json.dumps({"keys": [{**jwk, "kid": "dev", "use": "sig", "alg": "RS256"}]})
    )
    for path in (directory / "jwks").iterdir():
        path.chmod(0o644)
    (directory / "jwks").chmod(0o755)


def token(directory: Path, sub: str) -> str:
    now = int(time.time())
    claims = {"iss": ISSUER, "aud": "memory-core", "sub": sub, "iat": now, "exp": now + 300}
    return jwt.encode(
        claims, (directory / "private.pem").read_bytes(), "RS256", headers={"kid": "dev"}
    )


async def call(session: ClientSession, tool: str, **args: Any) -> Any:  # noqa: ANN401
    result = await session.call_tool(tool, args)
    if result.isError:
        check(f"{tool} call", result.content, "a successful result")
    data = result.structuredContent
    return data["result"] if data is not None and set(data) == {"result"} else data


def check(step: str, actual: object, expected: object) -> None:
    ok = actual == expected
    sys.stdout.write(f"{'PASS' if ok else 'FAIL'} {step}: {actual!r}\n")
    if not ok:
        sys.stdout.write(f"     expected {expected!r}\n")
        sys.exit(1)


async def story(directory: Path, url: str) -> None:
    contributor = {"Authorization": f"Bearer {token(directory, 'contributor@dev')}"}
    async with (
        streamablehttp_client(url, headers=contributor) as (r1, w1, _),
        ClientSession(r1, w1) as writer,
    ):
        await writer.initialize()
        check(
            "tools",
            sorted(
                t.name
                for t in (await writer.list_tools()).tools
                if t.name in {"remember", "decide"}
            ),
            ["remember"],
        )

        first = await call(
            writer, "remember", text="A사 담당자는 이민수", store_id=STORE, source_refs=SOURCE
        )
        check("remember 이민수 -> created", first["outcome"], "created")
        again = await call(
            writer, "remember", text="A사 담당자는 이민수", store_id=STORE, source_refs=SOURCE
        )
        check(
            "remember again -> reconfirmed",
            (again["outcome"], again["memory_id"]),
            ("reconfirmed", first["memory_id"]),
        )

        second = await call(
            writer, "remember", text="A사 담당자는 박민수", store_id=STORE, source_refs=SOURCE
        )
        check("remember 박민수 -> created", second["outcome"], "created")
        check("conflict_with the first", second["conflict_with"], first["memory_id"])

        waiting = await call(writer, "get", memory_id=second["memory_id"])
        check("the conflicting value waits", waiting["data"]["status"], "proposed")

        hits = await call(writer, "search", query="담당자")
        check("search 담당자 -> only the first", [h["id"] for h in hits], [first["memory_id"]])
        now = await call(
            writer,
            "as_of",
            store_id=STORE,
            subject_id=hits[0]["subject_id"],
            attribute="담당자",
            on=datetime.now(UTC).date().isoformat(),
        )
        check("as_of today -> 이민수", now["data"]["body"], "A사 담당자는 이민수")


if __name__ == "__main__":
    mode, folder = sys.argv[1], Path(sys.argv[2])
    if mode == "keys":
        write_jwks(folder)
    else:
        asyncio.run(story(folder, sys.argv[3]))
