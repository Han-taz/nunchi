"""Channel digest: the primary capture path for a bound Mattermost channel. Every run reads the
posts newer than the binding's cursor, groups them into conversation windows and captures each
window once. A window is a root post with its thread, or consecutive top-level posts less than
WINDOW_GAP apart. Idempotence comes from one inbound_event claim per window id, taken in the same
transaction as the capture; the cursor only saves reading work."""

import logging
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, date, datetime
from typing import Any, Literal
from uuid import UUID

import httpx

from nunchi.capture import (
    CaptureContext,
    CaptureResult,
    Created,
    Reconfirmed,
    Retracted,
    capture_all,
)
from nunchi.db import Pool, request_tx
from nunchi.domain.models import Evidence, SourceRef
from nunchi.embed import Embedder
from nunchi.extract import ExtractionError, Extractor, WindowPost, render_numbered
from nunchi.mattermost.client import Mattermost, RoomFacts, User, room_facts

log = logging.getLogger(__name__)

WINDOW_GAP_MS = 15 * 60 * 1000
MAX_LINKS = 20


@dataclass(frozen=True)
class DigestLimits:
    """max_windows caps the extractor calls per run (the rest wait for the next run);
    max_chars caps one window's text, keeping the newest lines."""

    max_windows: int = 20
    max_chars: int = 6000


@dataclass(frozen=True)
class Window:
    posts: tuple[dict[str, Any], ...]  # the whole window, oldest first
    first_new: int  # create_at of its oldest post newer than the cursor
    last_new: int

    @property
    def id(self) -> str:
        return (
            f"mm-digest:{self.posts[0]['channel_id']}:{self.posts[0]['id']}:{self.posts[-1]['id']}"
        )


@dataclass
class DigestReport:
    windows: int = 0
    created: int = 0
    confirmed: int = 0
    reconfirmed: int = 0
    challenged: int = 0
    superseded: int = 0
    retracted: int = 0
    skipped_audience: int = 0  # windows left unread because the room does not contain the readers
    stored_nothing: int = 0  # windows that wrote nothing: skipped, gated out, or only reconfirmed
    deferred: int = 0
    failed: int = 0


def _readable(post: dict[str, Any], bot_user_id: str) -> bool:
    return (
        not post.get("type")
        and not post.get("delete_at")
        and post["user_id"] != bot_user_id
        and bool(post["message"].strip())
    )


def build_windows(
    new: list[dict[str, Any]], threads: dict[str, list[dict[str, Any]]], cursor: int
) -> list[Window]:
    """new: readable posts newer than the cursor. threads: full threads by root id for every
    root that has a reply among them. Ordered by when each window last had something new."""
    windows: list[Window] = []
    for posts in threads.values():
        ordered = tuple(sorted(posts, key=lambda p: p["create_at"]))
        fresh = [p["create_at"] for p in ordered if p["create_at"] > cursor]
        windows.append(Window(ordered, fresh[0], fresh[-1]))
    in_thread = {p["id"] for posts in threads.values() for p in posts}
    runs: list[list[dict[str, Any]]] = []
    for post in sorted((p for p in new if p["id"] not in in_thread), key=lambda p: p["create_at"]):
        if runs and post["create_at"] - runs[-1][-1]["create_at"] <= WINDOW_GAP_MS:
            runs[-1].append(post)
        else:
            runs.append([post])
    windows += [Window(tuple(run), run[0]["create_at"], run[-1]["create_at"]) for run in runs]
    return sorted(windows, key=lambda w: (w.last_new, w.posts[0]["id"]))


def _is_bot(post: dict[str, Any], user: User | None) -> bool:
    props = post.get("props") or {}
    return bool(user and user.bot) or "true" in (props.get("from_bot"), props.get("from_webhook"))


def _window_post(post: dict[str, Any], user: User | None, uri: str) -> WindowPost:
    name = user.name if user else None
    return WindowPost(
        author=name or post["user_id"],
        text=post["message"].strip(),
        bot=_is_bot(post, user),
        ref=Evidence(
            uri=uri,
            post_id=post["id"],
            author=post["user_id"],
            author_name=name,
            said_at=datetime.fromtimestamp(post["create_at"] / 1000, UTC),
        ),
    )


def window_posts(
    window: Window, users: dict[str, User], permalink: Callable[[str], str]
) -> tuple[WindowPost, ...]:
    """The window as the extractor and the server's consensus check both see it. Names, bot flags,
    links and times come from the platform's data."""
    return tuple(_window_post(p, users.get(p["user_id"]), permalink(p["id"])) for p in window.posts)


def fit(posts: tuple[WindowPost, ...], max_chars: int) -> tuple[WindowPost, ...]:
    """The newest posts whose numbered text fits; the newest post alone is cut if it must be."""
    kept = posts
    while len(kept) > 1 and len(render_numbered(kept)) > max_chars:
        kept = kept[1:]
    last = kept[-1]
    return (*kept[:-1], last.model_copy(update={"text": last.text[-max_chars:]}))


def _new_cursor(
    done: list[Window], rest: list[Window], posts: list[dict[str, Any]], cursor: int
) -> int:
    """Everything before the oldest unfinished window is settled; with none left, all seen is."""
    if rest:
        return min(w.first_new for w in rest) - 1
    seen = [p["create_at"] for p in posts] + [w.last_new for w in done]
    return max(seen, default=cursor)


@dataclass(frozen=True)
class Digest:
    pool: Pool
    client: Mattermost
    extractor: Extractor
    tenant_id: UUID
    bot_user_id: str
    embedder: Embedder | None = None
    limits: DigestLimits = DigestLimits()


def bot_principal(d: Digest) -> UUID | None:
    with d.pool.connection() as conn:
        row = conn.execute(
            "SELECT app_sec.resolve_identity(%s, 'mattermost', %s)", (d.tenant_id, d.bot_user_id)
        ).fetchone()
    return row[0] if row else None  # type: ignore[return-value]


def run_digest(d: Digest) -> DigestReport:
    """One pass over every live, digest-enabled binding. Returns what happened."""
    report = DigestReport()
    me = bot_principal(d)
    if me is None:
        log.warning("digest: the bot has no linked principal; nothing read")
        return report
    with request_tx(d.pool, me, None) as conn:
        bindings = conn.execute(
            "SELECT id, store_id, workspace_id, channel_id, digest_cursor FROM room_binding"
            " WHERE platform = 'mattermost' AND digest_enabled AND confirmed_by IS NOT NULL"
            " AND revoked_at IS NULL ORDER BY id"
        ).fetchall()
    budget = d.limits.max_windows
    for binding_id, store_id, team_id, channel_id, cursor in bindings:
        try:
            budget -= _digest_channel(
                d, me, report, budget, (binding_id, store_id, team_id, channel_id, cursor)
            )
        except httpx.HTTPError:
            log.exception("digest: channel %s unreadable", channel_id)
            report.failed += 1
    return report


def _digest_channel(
    d: Digest, me: UUID, report: DigestReport, budget: int, binding: tuple[Any, ...]
) -> int:
    """Returns the extractor calls spent."""
    binding_id, store_id, team_id, channel_id, cursor = binding
    channel = d.client.get_channel(channel_id)
    facts = room_facts(channel)
    if facts.kind is None or facts.team_id != team_id:
        return 0  # DM and group channels are never read
    posts = [
        p
        for p in d.client.channel_posts(channel_id, cursor)
        if p["create_at"] > cursor and _readable(p, d.bot_user_id)
    ]
    if not posts:
        return 0
    roots = {p["root_id"] for p in posts if p["root_id"]}
    threads = {r: [t for t in d.client.thread(r) if _readable(t, d.bot_user_id)] for r in roots}
    windows = build_windows(posts, threads, cursor)
    if not _audience_contained(d, me, binding_id):
        report.skipped_audience += len(windows)
        return 0
    users = d.client.users(sorted({p["user_id"] for w in windows for p in w.posts}))
    done: list[Window] = []
    spent = 0
    for position, window in enumerate(windows):
        if spent >= budget:
            report.deferred += len(windows) - position
            break
        try:
            outcome = _capture_window(d, me, store_id, facts, (team_id, channel_id), window, users)
        except ExtractionError:
            log.exception("digest: extraction failed for %s", window.id)
            report.failed += 1
            break
        done.append(window)
        if isinstance(outcome, tuple):
            spent += 1
            report.windows += 1
            _count(report, outcome)
    rest = windows[len(done) :]
    advance = _new_cursor(done, rest, posts, cursor)
    if advance > cursor:
        with request_tx(d.pool, me, None) as conn:
            conn.execute("SELECT app_sec.advance_digest(%s, %s)", (binding_id, advance))
    return spent


def _audience_contained(d: Digest, me: UUID, binding_id: UUID) -> bool:
    """Everyone who may read the store is in the room, and the room snapshot is fresh. Otherwise
    the room's talk would reach people who never heard it, so nothing is stored and the cursor
    stays put for the next run."""
    with request_tx(d.pool, me, None) as conn:
        row = conn.execute("SELECT ok FROM app_sec.room_containment(%s)", (binding_id,)).fetchone()
    return bool(row and row[0])


def _count(report: DigestReport, results: tuple[CaptureResult, ...]) -> None:
    """Counted per memory. stored_nothing counts windows that wrote nothing new."""
    wrote = False
    for r in results:
        if isinstance(r, Created):
            wrote = True
            report.created += r.change == "created"
            report.challenged += r.change == "challenged"
            report.superseded += r.change == "superseded"
        elif isinstance(r, Reconfirmed):
            wrote = wrote or r.confirmed
            report.confirmed += r.confirmed
            report.reconfirmed += not r.confirmed
        elif isinstance(r, Retracted):
            wrote = True
            report.retracted += 1
    report.stored_nothing += not wrote


def _capture_window(  # noqa: PLR0913, PLR0917
    d: Digest,
    me: UUID,
    store_id: UUID,
    facts: RoomFacts,
    room: tuple[str, str],
    window: Window,
    users: dict[str, User],
) -> tuple[CaptureResult, ...] | Literal["claimed"]:
    team_id, channel_id = room
    posts = fit(
        window_posts(window, users, lambda i: d.client.permalink(team_id, i)), d.limits.max_chars
    )
    speakers = tuple(sorted({p.author for p in posts}))
    refs = tuple(
        SourceRef(
            uri=p.ref.uri,
            system="mattermost",
            workspace_id=team_id,
            channel_id=channel_id,
            speakers=speakers,
        )
        for p in posts[-MAX_LINKS:]
        if p.ref is not None
    )
    context = CaptureContext(
        store_id=store_id,
        origin=facts.origin,
        source_refs=refs,
        today=date.today(),
        window=True,
        posts=posts,
    )
    with request_tx(d.pool, me, None) as conn:
        claimed = conn.execute("SELECT app_sec.claim_inbound_event(%s)", (window.id,)).fetchone()
        if claimed is None or not claimed[0]:
            return "claimed"
        return capture_all(conn, d.extractor, render_numbered(posts), context, d.embedder)
