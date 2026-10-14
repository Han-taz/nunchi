import uuid
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

import psycopg
import pytest

from nunchi import migrate
from nunchi.worker.__main__ import main
from nunchi.worker.freshness import run_once
from tests.conftest import OTHER, REPO, USER

TENANT = uuid.UUID("00000000-0000-0000-0000-0000000000c1")
STORE = uuid.UUID("00000000-0000-0000-0000-0000000000d1")
SUBJECT = uuid.UUID("00000000-0000-0000-0000-0000000000e4")


@pytest.fixture
def conn(fresh_db: str) -> Iterator[psycopg.Connection[tuple[object, ...]]]:
    with psycopg.connect(fresh_db) as c:
        migrate.migrate(c, REPO / "db" / "migrations")
        c.execute("INSERT INTO tenant (id, name) VALUES (%s, 't')", (TENANT,))
        c.execute(
            "INSERT INTO principal (id, tenant_id, kind, external_id, display_name)"
            " VALUES (%s, %s, 'user', 'u', 'x')",
            (USER, TENANT),
        )
        c.execute(
            "INSERT INTO store (id, tenant_id, kind, slug, description)"
            " VALUES (%s, %s, 'team', 's', 'd')",
            (STORE, TENANT),
        )
        c.execute(
            "INSERT INTO entity (id, tenant_id, kind, canonical_name)"
            " VALUES (%s, %s, 'team', 'Infra')",
            (SUBJECT, TENANT),
        )
        yield c


def add(
    c: psycopg.Connection[tuple[object, ...]],
    kind: str,
    attr: str,
    age_days: int,
    valid_to: str | None = None,
) -> uuid.UUID:
    row = c.execute(
        "INSERT INTO memory (tenant_id, store_id, kind, status, title, body, source_refs,"
        " created_by, subject_id, attribute, valid_to, last_confirmed_at)"
        " VALUES (%s, %s, %s, 'active', %s, 'b', '[{\"uri\":\"x\"}]', %s, %s, %s, %s,"
        " now() - make_interval(days => %s)) RETURNING id",
        (TENANT, STORE, kind, attr, USER, SUBJECT, attr, valid_to, age_days),
    ).fetchone()
    assert row is not None
    return uuid.UUID(str(row[0]))


def stale_titles(c: psycopg.Connection[tuple[object, ...]]) -> list[str]:
    return sorted(s.title for s in run_once(c).stale)


def test_fact_goes_stale_after_180_days(conn: psycopg.Connection[tuple[object, ...]]) -> None:
    add(conn, "fact", "fresh179", 179)
    add(conn, "fact", "old181", 181)
    assert stale_titles(conn) == ["old181"]


def test_procedure_ttl_is_90_days(conn: psycopg.Connection[tuple[object, ...]]) -> None:
    add(conn, "procedure", "p89", 89)
    add(conn, "procedure", "p91", 91)
    assert stale_titles(conn) == ["p91"]


def test_store_override_replaces_the_default(conn: psycopg.Connection[tuple[object, ...]]) -> None:
    conn.execute(
        "INSERT INTO store_freshness (store_id, kind, days) VALUES (%s, 'fact', 30)", (STORE,)
    )
    add(conn, "fact", "f29", 29)
    add(conn, "fact", "f31", 31)
    result = run_once(conn)
    assert [(s.title, s.ttl_days) for s in result.stale] == [("f31", 30)]


def test_decisions_and_notes_never_go_stale(conn: psycopg.Connection[tuple[object, ...]]) -> None:
    add(conn, "decision", "d", 5000)
    conn.execute(
        "INSERT INTO memory (tenant_id, store_id, kind, status, title, created_by,"
        " last_confirmed_at)"
        " VALUES (%s, %s, 'note', 'active', 'n', %s, now() - interval '5000 days')",
        (TENANT, STORE, USER),
    )
    assert stale_titles(conn) == []


def test_valid_to_in_the_past_expires_the_row(conn: psycopg.Connection[tuple[object, ...]]) -> None:
    gone = add(conn, "decision", "gone", 1, valid_to="2000-01-01")
    kept = add(conn, "decision", "kept", 1, valid_to="2999-01-01")
    result = run_once(conn)
    rows: dict[Any, Any] = dict(conn.execute("SELECT id, status::text FROM memory").fetchall())  # type: ignore[arg-type]
    assert (result.expired, rows[gone], rows[kept]) == (1, "expired", "active")
    assert run_once(conn).expired == 0


def test_stale_comes_oldest_first_and_respects_the_limit(
    conn: psycopg.Connection[tuple[object, ...]],
) -> None:
    add(conn, "fact", "a", 200)
    add(conn, "fact", "b", 400)
    add(conn, "fact", "c", 300)
    assert [s.title for s in run_once(conn, stale_limit=2).stale] == ["b", "c"]


def test_search_reports_stale_and_last_confirmed(
    conn: psycopg.Connection[tuple[object, ...]],
) -> None:
    mid = add(conn, "fact", "배포 담당자", 181)
    conn.execute(
        "INSERT INTO store_grant (store_id, principal_id, role, tenant_id)"
        " VALUES (%s, %s, 'reader', %s)",
        (STORE, USER, TENANT),
    )
    conn.execute("SELECT app_sec.begin_request(%s, NULL)", (USER,))
    row = conn.execute(
        "SELECT id, stale, now() - last_confirmed_at > interval '180 days'"
        " FROM app_sec.search('배포 담당자')"
    ).fetchone()
    assert row is not None
    assert (row[0], row[1], row[2]) == (mid, True, True)


T0 = datetime(2026, 8, 5, 9, 0, tzinfo=UTC)
CHANNEL = "c" * 26


@dataclass(frozen=True)
class Row:
    attr: str
    value: str
    status: str
    promote_at: datetime | None = None
    origin: str = "internal"
    refs: str = '[{"uri":"x"}]'


def live_row(c: psycopg.Connection[tuple[object, ...]], r: Row) -> uuid.UUID:
    row = c.execute(
        "INSERT INTO memory (tenant_id, store_id, kind, status, title, body, source_refs, origin,"
        " created_by, subject_id, attribute, value, promote_at, basis)"
        " VALUES (%s, %s, 'fact', %s, %s, 'b', %s, %s, %s, %s, %s, %s, %s, 'stated') RETURNING id",
        (
            TENANT,
            STORE,
            r.status,
            f"{r.attr} {r.value}",
            r.refs,
            r.origin,
            USER,
            SUBJECT,
            r.attr,
            r.value,
            r.promote_at,
        ),
    ).fetchone()
    assert row is not None
    return uuid.UUID(str(row[0]))


def statuses(c: psycopg.Connection[tuple[object, ...]], attr: str) -> dict[str, str]:
    rows = c.execute(
        "SELECT value, status::text FROM memory WHERE attribute = %s", (attr,)
    ).fetchall()
    return {str(v): str(st) for v, st in rows}


def test_provisional_is_promoted_at_24_hours_and_not_a_minute_before(
    conn: psycopg.Connection[tuple[object, ...]],
) -> None:
    mid = live_row(conn, Row("owner", "a", "provisional", T0 + timedelta(hours=24)))
    early = run_once(conn, now=T0 + timedelta(hours=23, minutes=59))
    assert (early.promoted, statuses(conn, "owner")) == (0, {"a": "provisional"})
    due = run_once(conn, now=T0 + timedelta(hours=24))
    assert (due.promoted, due.replaced, statuses(conn, "owner")) == (1, 0, {"a": "active"})
    row = conn.execute(
        "SELECT basis::text, promote_at, (SELECT count(*) FROM memory_evidence"
        " WHERE memory_id = %s AND op = 'promote' AND basis = 'timer') FROM memory WHERE id = %s",
        (mid, mid),
    ).fetchone()
    assert row == ("timer", None, 1)
    again = run_once(conn, now=T0 + timedelta(hours=48))
    assert (again.promoted, again.replaced) == (0, 0)


def test_challenger_replaces_the_live_row_when_its_time_comes(
    conn: psycopg.Connection[tuple[object, ...]],
) -> None:
    live_row(conn, Row("lead", "old", "active"))
    live_row(conn, Row("lead", "new", "challenger", T0 + timedelta(hours=24)))
    assert run_once(conn, now=T0 + timedelta(hours=23)).replaced == 0
    assert statuses(conn, "lead") == {"old": "active", "new": "challenger"}
    result = run_once(conn, now=T0 + timedelta(hours=24))
    assert (result.promoted, result.replaced) == (0, 1)
    assert statuses(conn, "lead") == {"old": "superseded", "new": "active"}
    ended = conn.execute(
        "SELECT valid_to = current_date FROM memory WHERE attribute = 'lead' AND value = 'old'"
    ).fetchone()
    assert ended == (True,)


def test_an_open_challenger_holds_back_the_provisional_row_of_its_key(
    conn: psycopg.Connection[tuple[object, ...]],
) -> None:
    live_row(conn, Row("role", "a", "provisional", T0 + timedelta(hours=24)))
    live_row(conn, Row("role", "b", "challenger", T0 + timedelta(hours=25)))
    run_once(conn, now=T0 + timedelta(hours=24, minutes=30))
    assert statuses(conn, "role") == {"a": "provisional", "b": "challenger"}
    run_once(conn, now=T0 + timedelta(hours=25))
    assert statuses(conn, "role") == {"a": "superseded", "b": "active"}


def test_external_origin_is_never_promoted_by_the_timer(
    conn: psycopg.Connection[tuple[object, ...]],
) -> None:
    live_row(conn, Row("ext", "a", "provisional", T0 + timedelta(hours=24), origin="external"))
    result = run_once(conn, now=T0 + timedelta(days=3650))
    assert (result.promoted, statuses(conn, "ext")) == (0, {"a": "provisional"})


def test_the_digest_cursor_must_be_past_promote_at(
    conn: psycopg.Connection[tuple[object, ...]],
) -> None:
    conn.execute(
        "INSERT INTO principal (id, tenant_id, kind, external_id, display_name)"
        " VALUES (%s, %s, 'user', 'v', 'y')",
        (OTHER, TENANT),
    )
    conn.execute(
        "INSERT INTO store_grant (store_id, principal_id, role, tenant_id)"
        " VALUES (%s, %s, 'curator', %s)",
        (STORE, OTHER, TENANT),
    )
    conn.execute(
        "INSERT INTO room_member (tenant_id, platform, workspace_id, channel_id, platform_user_id)"
        " VALUES (%s, 'mattermost', 'team1', %s, 'u1')",
        (TENANT, CHANNEL),
    )
    binding = conn.execute(
        "INSERT INTO room_binding (tenant_id, platform, workspace_id, channel_id, kind, store_id,"
        " bound_by, confirmed_by, confirmed_at, digest_enabled)"
        " VALUES (%s, 'mattermost', 'team1', %s, 'public', %s, %s, %s, now(), true) RETURNING id",
        (TENANT, CHANNEL, STORE, USER, OTHER),
    ).fetchone()
    assert binding is not None
    refs = f'[{{"uri":"u","system":"mattermost","workspace_id":"team1","channel_id":"{CHANNEL}"}}]'
    due_at = T0 + timedelta(hours=24)
    live_row(conn, Row("slot", "a", "provisional", due_at, refs=refs))
    due_ms = int(due_at.timestamp() * 1000)
    conn.execute("UPDATE room_binding SET digest_cursor = %s", (due_ms - 1,))
    assert run_once(conn, now=due_at).promoted == 0
    conn.execute("UPDATE room_binding SET digest_cursor = %s", (due_ms,))
    assert run_once(conn, now=due_at).promoted == 1
    post = conn.execute("SELECT post_id FROM memory_evidence WHERE op = 'promote'").fetchone()
    assert post == (str(due_ms),)


def test_cli_once_prints_counts(
    fresh_db: str,
    conn: psycopg.Connection[tuple[object, ...]],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    add(conn, "fact", "old", 181)
    add(conn, "decision", "gone", 1, valid_to="2000-01-01")
    conn.commit()
    monkeypatch.setenv("NUNCHI_DATABASE_URL", fresh_db)
    assert main(["--once"]) == 0
    assert capsys.readouterr().out == "worker: promoted 0, replaced 0, expired 1, stale 1\n"


def test_cli_every_repeats_after_sleeping(
    fresh_db: str,
    conn: psycopg.Connection[tuple[object, ...]],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    conn.commit()
    sleeps: list[float] = []

    def fake_sleep(seconds: float) -> None:
        sleeps.append(seconds)
        if len(sleeps) == 2:
            raise KeyboardInterrupt

    monkeypatch.setenv("NUNCHI_DATABASE_URL", fresh_db)
    monkeypatch.setattr("nunchi.worker.__main__.time.sleep", fake_sleep)
    with pytest.raises(KeyboardInterrupt):
        main(["--every", "60"])
    assert (sleeps, capsys.readouterr().out) == (
        [60.0, 60.0],
        "worker: promoted 0, replaced 0, expired 0, stale 0\n" * 2,
    )


def test_cli_needs_exactly_one_mode() -> None:
    with pytest.raises(SystemExit) as exc:
        main([])
    assert exc.value.code == 2
