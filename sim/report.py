"""Compare nunchi's memory with the day's gold and write JSON + Markdown."""

import argparse
import json
import os
import re
from collections import Counter
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path

import httpx
import psycopg

from sim.director import MattermostChat, Post
from sim.spec import Gold, gold_through, load

LIVE = ("active", "provisional")
OK = ("remembered", "updated-correctly", "clean")


@dataclass(frozen=True)
class Mem:
    id: str
    subject: str
    attribute: str
    value: str
    title: str
    body: str
    status: str
    created_at: datetime
    updated_at: datetime
    supersedes_id: str | None = None


@dataclass(frozen=True)
class Verdict:
    subject: str
    attribute: str
    expected: str
    outcome: str
    detail: str


def norm(s: str | None) -> str:
    return re.sub(r"\s+", " ", (s or "").casefold()).strip()


def _text(m: Mem) -> str:
    return norm(f"{m.value} {m.title} {m.body}")


def _holds(m: Mem, needles: tuple[str, ...]) -> bool:
    return all(norm(n) in _text(m) for n in needles)


def _same_key(g: Gold, m: Mem) -> bool:
    s, a, ms, ma = norm(g.subject), norm(g.attribute), norm(m.subject), norm(m.attribute)
    return bool(ms and ma) and (s in ms or ms in s) and (a in ma or ma in a)


def judge(g: Gold, mems: list[Mem]) -> Verdict:  # noqa: PLR0911 - one return per outcome
    def v(outcome: str, detail: str = "") -> Verdict:
        return Verdict(g.subject, g.attribute, g.value, outcome, detail)

    if g.expect == "absent":
        needle = (g.needle or "",)
        leak = [m for m in mems if m.status != "rejected" and _holds(m, needle)]
        return v("leaked", leak[0].id) if leak else v("clean")
    live = [m for m in mems if m.status in LIVE]
    fresh = [m for m in live if _holds(m, g.match)]
    if g.expect == "updated" and fresh:
        old = [m for m in mems if m.status == "superseded" and _holds(m, (g.was or "",))]
        if old:
            return v("updated-correctly", f"{old[0].id} -> {fresh[0].id}")
        return v("remembered", "new value live, no superseded old version")
    if fresh:
        return v(
            "remembered",
            ""
            if _same_key(g, fresh[0])
            else f"key differs: {fresh[0].subject}/{fresh[0].attribute}",
        )
    keyed = [m for m in live if _same_key(g, m)]
    if keyed:
        return v("wrong", f"live value: {keyed[0].value or keyed[0].title}")
    if any(m.status == "proposed" and _holds(m, g.match) for m in mems):
        return v("pending", "awaiting curator approval")
    return v("missing")


def compare(gold: list[Gold], mems: list[Mem]) -> list[Verdict]:
    return [judge(g, mems) for g in gold]


def timeline(posts: list[Post], mems: list[Mem]) -> list[dict[str, str]]:
    """Message -> memory: each memory event points at the latest message before it."""
    events: list[tuple[datetime, str, str, str]] = [
        (datetime.fromtimestamp(p.at_ms / 1000, UTC), "message", p.user, p.text) for p in posts
    ]
    for m in mems:
        events.append(
            (m.created_at, "memory created", m.status, f"{m.subject}/{m.attribute}={m.value}")
        )
        if m.updated_at > m.created_at:
            events.append(
                (m.updated_at, "memory updated", m.status, f"{m.subject}/{m.attribute}={m.value}")
            )
    events.sort(key=lambda e: e[0])
    return [{"at": e[0].isoformat(), "kind": e[1], "who": e[2], "text": e[3]} for e in events]


def markdown(
    day: int, verdicts: list[Verdict], tl: list[dict[str, str]], tokens: dict[str, dict[str, int]]
) -> str:
    counts = Counter(v.outcome for v in verdicts)
    good = sum(counts[o] for o in OK)
    lines = [f"# Day {day}: {good}/{len(verdicts)} ok", "", "| outcome | n |", "|---|---|"]
    lines += [f"| {k} | {n} |" for k, n in sorted(counts.items())]
    lines += ["", "| subject | attribute | expected | outcome | detail |", "|---|---|---|---|---|"]
    lines += [
        f"| {v.subject} | {v.attribute} | {v.expected} | {v.outcome} | {v.detail} |"
        for v in verdicts
    ]
    if tokens:
        lines += ["", "| model | turns | input | output |", "|---|---|---|---|"]
        lines += [
            f"| {m} | {t['turns']} | {t['input']} | {t['output']} |"
            for m, t in sorted(tokens.items())
        ]
    lines += ["", "## Timeline", ""]
    lines += [f"- {e['at'][11:19]} **{e['kind']}** {e['who']}: {e['text']}" for e in tl]
    return "\n".join(lines) + "\n"


def token_use(turn_log: list[dict[str, object]]) -> dict[str, dict[str, int]]:
    out: dict[str, dict[str, int]] = {}
    for t in turn_log:
        s = out.setdefault(str(t["model"]), {"turns": 0, "input": 0, "output": 0})
        s["turns"] += 1
        s["input"] += int(str(t["input_tokens"]))
        s["output"] += int(str(t["output_tokens"]))
    return out


_SQL = (
    "SELECT m.id::text, coalesce(e.canonical_name, ''), coalesce(m.attribute, ''),"
    " coalesce(m.value, ''), m.title, coalesce(m.body, ''), m.status::text,"
    " m.created_at, m.updated_at, m.supersedes_id::text"
    " FROM memory m LEFT JOIN entity e ON e.id = m.subject_id ORDER BY m.created_at"
)


def load_memories(url: str) -> list[Mem]:
    with psycopg.connect(url) as conn:
        return [Mem(*row) for row in conn.execute(_SQL).fetchall()]


def main(argv: list[str] | None = None) -> int:
    env = os.environ
    ap = argparse.ArgumentParser(prog="sim.report")
    ap.add_argument("--scenario", type=Path, default=Path("sim/scenario/agent_desk.yaml"))
    ap.add_argument("--day", type=int, required=True)
    ap.add_argument("--out", type=Path, default=Path("sim/out"))
    ap.add_argument("--turn-log", type=Path, help="JSON written by director --log-json")
    ap.add_argument("--posts", type=int, default=200)
    a = ap.parse_args(argv)
    sc = load(a.scenario)
    mems = load_memories(env["NUNCHI_DATABASE_URL"])
    chat = MattermostChat(
        env.get("MM_URL", "http://127.0.0.1:8065"),
        env.get("SIM_CHANNEL_ID", ""),
        env,
        httpx.Client(timeout=30),
    )
    posts = chat.recent(a.posts)
    verdicts = compare(gold_through(sc, a.day), mems)
    tl = timeline(posts, mems)
    tokens = token_use(json.loads(a.turn_log.read_text())) if a.turn_log else {}
    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / f"day{a.day}.json").write_text(
        json.dumps(
            {"verdicts": [asdict(v) for v in verdicts], "timeline": tl, "tokens": tokens},
            ensure_ascii=False,
            indent=1,
        )
    )
    (a.out / f"day{a.day}.md").write_text(markdown(a.day, verdicts, tl, tokens), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
