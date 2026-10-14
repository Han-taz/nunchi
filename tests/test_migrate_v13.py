import json
import subprocess
import sys
from collections.abc import Iterator

import psycopg
import pytest
from psycopg import sql
from psycopg.types.json import Jsonb

from nunchi import migrate
from tests.conftest import REPO

SCRIPT = REPO / "scripts" / "migrate-v1.3.py"
SEED = REPO / "tests" / "data" / "v13_live_shape.json"
VARIABLE = "css modules + css 변수=css modules + css 커스텀 프로퍼티"
# Seed by created_at: 113 scope, 114-115 notes, 116 styling, 117 theme, 118-120 restatements
ROWS = (
    "SELECT right(id::text, 3), status::text, coalesce(basis::text, '-')"
    " FROM memory ORDER BY created_at, id"
)


@pytest.fixture
def live_shape(fresh_db: str) -> Iterator[str]:
    with psycopg.connect(fresh_db) as conn:
        migrate.migrate(conn, REPO / "db" / "migrations")
        for table, seeded in json.loads(SEED.read_text()).items():
            for row in seeded:
                values = [Jsonb(v) if isinstance(v, list) else v for v in row.values()]
                conn.execute(
                    sql.SQL("INSERT INTO {} ({}) VALUES ({})").format(
                        sql.Identifier(table),
                        sql.SQL(", ").join(map(sql.Identifier, row)),
                        sql.SQL(", ").join(sql.Placeholder() * len(row)),
                    ),
                    values,
                )
    yield fresh_db


def run(url: str, *args: str) -> str:
    done = subprocess.run(  # noqa: S603
        [sys.executable, str(SCRIPT), "--dsn", url, *args],
        capture_output=True,
        text=True,
        check=False,
    )
    assert done.returncode == 0, done.stderr
    return done.stdout


def rows(url: str, query: str = ROWS) -> list[tuple[str, ...]]:
    with psycopg.connect(url) as conn:
        return [tuple(str(c) for c in r) for r in conn.execute(query.encode()).fetchall()]


def scalar(url: str, query: str) -> str:
    return rows(url, query)[0][0]


@pytest.mark.db
def test_dry_run_prints_the_plan_and_writes_nothing(live_shape: str) -> None:
    before = rows(live_shape)
    out = run(live_shape, "--same-value", VARIABLE)
    assert rows(live_shape) == before
    assert out.count("| merge ->") == 3
    assert out.count("| active |") == 3
    assert "open cards to withdraw: 6" in out
    assert "dry-run: nothing written" in out


@pytest.mark.db
def test_apply_collapses_the_style_decision_into_one_active_row_with_four_evidence_lines(
    live_shape: str,
) -> None:
    run(live_shape, "--apply", "--same-value", VARIABLE)
    assert rows(live_shape) == [
        ("113", "active", "migrated"),
        ("114", "provisional", "-"),
        ("115", "provisional", "-"),
        ("116", "active", "migrated"),
        ("117", "active", "migrated"),
        ("118", "rejected", "migrated"),
        ("119", "rejected", "migrated"),
        ("120", "rejected", "migrated"),
    ]
    evidence = (
        "SELECT op::text, count(*) FROM memory_evidence"
        " WHERE memory_id = (SELECT id FROM memory WHERE right(id::text, 3) = '116')"
        " GROUP BY op ORDER BY op"
    )
    assert rows(live_shape, evidence) == [("confirm", "1"), ("reconfirm", "3")]
    assert scalar(live_shape, "SELECT count(*) FROM approval_card WHERE consumed_at IS NULL") == "0"
    assert (
        scalar(live_shape, "SELECT count(*) FROM approval_card WHERE outcome = 'withdrawn:v1.3'")
        == "6"
    )
    chain = "SELECT bool_and(app_sec.verify_chain(id)) FROM memory WHERE kind = 'decision'"
    assert scalar(live_shape, chain) == "True"
    assert (
        scalar(
            live_shape,
            "SELECT convalidated FROM pg_constraint WHERE conname = 'memory_no_proposed'",
        )
        == "True"
    )


@pytest.mark.db
def test_without_a_same_value_verdict_the_css_variable_decision_stays_its_own_live_row(
    live_shape: str,
) -> None:
    run(live_shape, "--apply")
    statuses = [r[1] for r in rows(live_shape)]
    assert statuses == [
        "active",
        "provisional",
        "provisional",
        "active",
        "active",
        "active",
        "rejected",
        "rejected",
    ]


@pytest.mark.db
def test_a_second_run_changes_nothing(live_shape: str) -> None:
    run(live_shape, "--apply", "--same-value", VARIABLE)
    snap = (
        "SELECT (SELECT count(*) FROM memory_version), (SELECT count(*) FROM memory_evidence),"
        " (SELECT max(version) FROM memory)"
    )
    first = rows(live_shape, snap)
    out = run(live_shape, "--apply", "--same-value", VARIABLE)
    assert rows(live_shape, snap) == first
    assert "== plan\n(none)" in out
    assert "open cards to withdraw: 0" in out


@pytest.mark.db
def test_a_decision_nobody_outside_the_conversation_approved_waits_for_the_timer(
    live_shape: str,
) -> None:
    with psycopg.connect(live_shape) as conn:
        conn.execute("SET session_replication_role = replica")
        conn.execute("DELETE FROM review")
    run(live_shape, "--apply", "--same-value", VARIABLE)
    survivors = (
        "SELECT right(id::text, 3), status::text FROM memory"
        " WHERE kind = 'decision' AND status <> 'rejected' ORDER BY created_at, id"
    )
    assert rows(live_shape, survivors) == [
        ("113", "provisional"),
        ("116", "provisional"),
        ("117", "provisional"),
    ]
    timer = (
        "SELECT count(*) FROM memory WHERE status = 'provisional' AND kind = 'decision'"
        " AND promote_at > now() + interval '23 hours' AND promote_at < now() + interval '25 hours'"
    )
    assert scalar(live_shape, timer) == "3"


@pytest.mark.db
def test_a_click_from_the_speaker_of_the_memory_does_not_activate_it(live_shape: str) -> None:
    with psycopg.connect(live_shape) as conn:
        conn.execute(
            "UPDATE principal SET display_name = 'minji.kim' WHERE display_name = 'curator'"
        )
    run(live_shape, "--apply", "--same-value", VARIABLE)
    states = {r[0]: r[1] for r in rows(live_shape)}
    assert states["113"] == "provisional"
    assert states["116"] == "active"
