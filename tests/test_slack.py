import json
import uuid
from types import SimpleNamespace
from typing import Any

import psycopg
import pytest
from slack_bolt import App, BoltRequest
from slack_bolt.authorization import AuthorizeResult

from nunchi.capture import CaptureResult, Created, Reconfirmed, Skipped
from nunchi.db import Pool
from nunchi.domain.models import MemoryKind, MemoryStatus
from nunchi.extract import ExtractContext, ExtractionError, FailureReason, ProposalDraft
from nunchi.slack import __main__ as slack_main
from nunchi.slack import app as slack_app
from nunchi.slack.app import Deps
from tests.conftest import STORE, TENANT, USER

CUR = uuid.UUID("00000000-0000-0000-0000-0000000000a3")
SECRET_STORE = uuid.UUID("00000000-0000-0000-0000-0000000000d2")
TEAM = "T1"
TEXT = "배포는 금요일에 하지 않는다"


class FakeSlack:
    def __init__(self) -> None:
        self.texts = {"1.1": TEXT, "2.2": "<@UBOT> 스테이징 DB 는 매일 새벽에 초기화된다"}
        self.ephemerals: list[tuple[str, str, str]] = []
        self.dms: list[tuple[str, str, list[dict[str, Any]]]] = []
        self.updates: list[tuple[str, str, str, list[dict[str, Any]]]] = []

    def conversations_history(self, *, channel: str, latest: str, **_: object) -> dict[str, Any]:
        text = self.texts.get(latest)
        return {"messages": [] if text is None else [{"ts": latest, "text": text}]}

    def chat_getPermalink(self, *, channel: str, message_ts: str) -> dict[str, Any]:
        return {
            "permalink": f"https://kc.slack.com/archives/{channel}/p{message_ts[0]}{message_ts[2]}"
        }

    def chat_postEphemeral(self, *, channel: str, user: str, text: str) -> None:
        self.ephemerals.append((channel, user, text))

    def chat_postMessage(self, *, channel: str, text: str, blocks: list[dict[str, Any]]) -> None:
        self.dms.append((channel, text, blocks))

    def chat_update(
        self, *, channel: str, ts: str, text: str, blocks: list[dict[str, Any]]
    ) -> None:
        self.updates.append((channel, ts, text, blocks))


class CountingExtractor:
    def __init__(self) -> None:
        self.calls = 0
        self.fail = False

    def extract(self, source_text: str, context: ExtractContext) -> ProposalDraft | None:
        self.calls += 1
        if self.fail:
            raise ExtractionError(FailureReason.API, "down")
        text = source_text.strip()
        if not text:
            return None
        return ProposalDraft(
            kind=MemoryKind.PROCEDURE,
            title=text.splitlines()[0],
            body=text,
            subject_name="A사",
            attribute=text,
            source_refs=context.source_refs,
            origin=context.origin,
        )


World = tuple[Deps, "FakeSlack", "CountingExtractor"]


@pytest.fixture
def slack_db(fresh_db: str, pool: Pool) -> Pool:
    with psycopg.connect(fresh_db) as conn:
        conn.execute(
            "INSERT INTO principal (id, tenant_id, kind, external_id, display_name)"
            " VALUES (%s, %s, 'user', 'c', 'x')",
            (CUR, TENANT),
        )
        conn.execute(
            "INSERT INTO store (id, tenant_id, kind, slug, description, confidential)"
            " VALUES (%s, %s, 'team', 'secret', 'd', true)",
            (SECRET_STORE, TENANT),
        )
        conn.execute(
            "INSERT INTO store_grant (store_id, principal_id, role, tenant_id) VALUES"
            " (%s, %s, 'curator', %s), (%s, %s, 'curator', %s), (%s, %s, 'contributor', %s)",
            (STORE, CUR, TENANT, SECRET_STORE, CUR, TENANT, SECRET_STORE, USER, TENANT),
        )
        conn.execute(
            "INSERT INTO principal_identity (platform, platform_user_id, tenant_id, principal_id,"
            " link_quality) VALUES ('slack', 'UREACT', %s, %s, 'scim'),"
            " ('slack', 'UCUR', %s, %s, 'scim')",
            (TENANT, USER, TENANT, CUR),
        )
        for channel, store in (("C1", STORE), ("C2", SECRET_STORE)):
            conn.execute(
                "INSERT INTO room_member (tenant_id, platform, workspace_id, channel_id,"
                " platform_user_id) VALUES (%s, 'slack', %s, %s, 'UREACT'),"
                " (%s, 'slack', %s, %s, 'UCUR')",
                (TENANT, TEAM, channel, TENANT, TEAM, channel),
            )
            conn.execute(
                "INSERT INTO room_binding (tenant_id, platform, workspace_id, channel_id, kind,"
                " store_id, bound_by, confirmed_by, confirmed_at)"
                " VALUES (%s, 'slack', %s, %s, 'public', %s, %s, %s, now())",
                (TENANT, TEAM, channel, store, USER, CUR),
            )
    return pool


@pytest.fixture
def slack(slack_db: Pool) -> World:
    client = FakeSlack()
    extractor = CountingExtractor()
    return Deps(slack_db, extractor, TENANT, client), client, extractor


def reaction(event_id: str = "Ev1", ts: str = "1.1", channel: str = "C1") -> dict[str, Any]:
    item = {"type": "message", "channel": channel, "ts": ts}
    event = {"type": "reaction_added", "user": "UREACT", "reaction": "pushpin", "item": item}
    return {"event_id": event_id, "team_id": TEAM, "event": event}


def memories(fresh_db: str) -> list[tuple[Any, ...]]:
    with psycopg.connect(fresh_db) as conn:
        return conn.execute(
            "SELECT title, status, source_refs->0->>'channel_id', source_refs->0->>'workspace_id'"
            " FROM memory WHERE title <> 'hello' ORDER BY created_at"
        ).fetchall()


def click(dm: tuple[str, str, list[dict[str, Any]]], clicker: str, action: str) -> dict[str, Any]:
    _, _, blocks = dm
    button = next(b for b in blocks[1]["elements"] if b["action_id"] == action)
    return {
        "user": {"id": clicker},
        "actions": [{"action_id": action, "value": button["value"]}],
        "channel": {"id": "D1"},
        "message": {"ts": "9.9", "blocks": blocks},
    }


@pytest.mark.db
def test_pushpin_captures_once_even_when_slack_redelivers_the_event(
    slack: World, fresh_db: str
) -> None:
    deps, client, extractor = slack
    slack_app.on_reaction(deps, reaction())
    slack_app.on_reaction(deps, reaction())
    assert extractor.calls == 1
    assert memories(fresh_db) == [(TEXT, "proposed", "C1", TEAM)]
    assert client.ephemerals == [("C1", "UREACT", "저장됨")]
    assert len(client.dms) == 1


@pytest.mark.db
def test_a_failed_capture_does_not_burn_the_event_id(slack: World, fresh_db: str) -> None:
    deps, client, extractor = slack
    extractor.fail = True
    slack_app.on_reaction(deps, reaction())
    extractor.fail = False
    slack_app.on_reaction(deps, reaction())
    assert [e[2] for e in client.ephemerals] == [
        "저장 안 함: 내용을 정리하지 못했습니다. 다시 시도해 주세요",
        "저장됨",
    ]
    assert len(memories(fresh_db)) == 1


@pytest.mark.db
@pytest.mark.parametrize(("channel", "secret"), [("C1", False), ("C2", True)])
def test_the_curator_gets_a_title_and_link_card_but_a_confidential_store_gets_the_id_only(
    slack: World, channel: str, secret: bool
) -> None:
    deps, client, _ = slack
    slack_app.on_reaction(deps, reaction(channel=channel))
    [(to, text, blocks)] = client.dms
    value = json.loads(blocks[1]["elements"][0]["value"])
    assert [b["action_id"] for b in blocks[1]["elements"]] == ["approve", "reject"]
    assert (sorted(value), value["v"], to) == (["m", "n", "v"], 1, "UCUR")
    if secret:
        shown = f"기밀 store 제안 #{value['m']}"
        assert (text, blocks[0]["text"]["text"]) == (shown, shown)
        assert "slack.com" not in json.dumps(client.dms)
    else:
        assert text == TEXT
        assert blocks[0]["text"]["text"] == f"*{TEXT}*\n<https://kc.slack.com/archives/C1/p11|원문>"


@pytest.mark.db
@pytest.mark.parametrize(
    ("action", "line", "status"),
    [("approve", "승인됨", "active"), ("reject", "반려됨", "rejected")],
)
def test_the_curator_decides_through_the_card_as_themselves_and_a_second_click_is_inert(
    slack: World, fresh_db: str, action: str, line: str, status: str
) -> None:
    deps, client, _ = slack
    slack_app.on_reaction(deps, reaction())
    slack_app.decide_from_card(deps, click(client.dms[0], "UCUR", action))
    slack_app.decide_from_card(deps, click(client.dms[0], "UCUR", "approve"))
    assert [(u[0], u[1], u[2]) for u in client.updates] == [
        ("D1", "9.9", line),
        ("D1", "9.9", "이미 처리됨"),
    ]
    assert [b["type"] for b in client.updates[0][3]] == ["section", "context"]
    assert memories(fresh_db) == [(TEXT, status, "C1", TEAM)]


@pytest.mark.db
@pytest.mark.parametrize(
    ("clicker", "revoke", "line"),
    [
        ("UREACT", False, "거부: 이 카드를 받은 사람이 아닙니다"),
        ("UCUR", True, "거부: 큐레이터가 아닙니다"),
        ("UNONE", False, "Slack 계정이 연결되어 있지 않습니다"),
    ],
)
def test_a_clicker_who_cannot_decide_is_refused_and_the_card_shows_it(
    slack: World, fresh_db: str, clicker: str, revoke: bool, line: str
) -> None:
    deps, client, _ = slack
    slack_app.on_reaction(deps, reaction())
    if revoke:
        with psycopg.connect(fresh_db) as conn:
            conn.execute("DELETE FROM store_grant WHERE principal_id = %s", (CUR,))
    slack_app.decide_from_card(deps, click(client.dms[0], clicker, "approve"))
    [(_, _, text, blocks)] = client.updates
    assert (text, [b["type"] for b in blocks]) == (line, ["section", "context", "actions"])
    assert memories(fresh_db)[0][1] == "proposed"


@pytest.mark.db
@pytest.mark.parametrize(
    ("event", "text", "said"),
    [
        ({"user": "UNONE"}, None, "Slack 계정이 연결되어 있지 않습니다"),
        ({"channel": "C9"}, None, "이 채널은 기억 저장소에 연결되어 있지 않습니다"),
        ({"ts": "7.7"}, None, "원문을 찾지 못했습니다"),
        ({}, "<@UBOT>", "저장 안 함: 오래 남길 내용이 아니라고 판단했습니다"),
        ({}, "prod key " + "AKIA" + "ABCDEFGHIJKLMNOP", "거부: 비밀값이 들어 있습니다"),
        ({"reaction": "tada"}, None, None),
        ({"type": "file"}, None, None),
    ],
)
def test_reactions_that_save_nothing_say_why_to_the_reactor_only(
    slack: World, fresh_db: str, event: dict[str, str], text: str | None, said: str | None
) -> None:
    deps, client, _ = slack
    client.texts["1.1"] = text or TEXT
    body = reaction()
    body["event"] |= {k: v for k, v in event.items() if k not in {"channel", "ts", "type"}}
    body["event"]["item"] |= {k: v for k, v in event.items() if k in {"channel", "ts", "type"}}
    slack_app.on_reaction(deps, body)
    expected = (
        [] if said is None else [(body["event"]["item"]["channel"], body["event"]["user"], said)]
    )
    assert (client.ephemerals, memories(fresh_db)) == (expected, [])


@pytest.mark.db
def test_a_mention_captures_the_thread_parent_or_its_own_message_without_the_mention(
    slack: World, fresh_db: str
) -> None:
    deps, client, _ = slack
    client.texts["8.8"] = "<@UBOT> 기억해줘"
    for event_id, ts, thread in (("Ev3", "5.5", "2.2"), ("Ev4", "8.8", None)):
        event = {"user": "UREACT", "channel": "C1", "ts": ts} | (
            {"thread_ts": thread} if thread else {}
        )
        slack_app.on_mention(deps, {"event_id": event_id, "team_id": TEAM, "event": event})
    assert [m[0] for m in memories(fresh_db)] == [
        "스테이징 DB 는 매일 새벽에 초기화된다",
        "기억해줘",
    ]


@pytest.mark.parametrize(
    ("result", "text"),
    [
        (Skipped(), "저장 안 함: 오래 남길 내용이 아니라고 판단했습니다"),
        (Reconfirmed(memory_id=uuid.uuid4()), "이미 알고 있음 (재확인했습니다)"),
        (
            Created(memory_id=uuid.uuid4(), tier="auto_labeled", status=MemoryStatus.ACTIVE),
            "저장됨",
        ),
        (
            Created(
                memory_id=uuid.uuid4(),
                tier="one_curator",
                status=MemoryStatus.ACTIVE,
                conflict_with=uuid.uuid4(),
            ),
            "충돌: 기존 값과 다름 → 큐레이터 검토",
        ),
    ],
)
def test_the_reply_names_the_capture_outcome(result: CaptureResult, text: str) -> None:
    assert slack_app._outcome(None, result, "x") == slack_app._Outcome(text)  # type: ignore[arg-type]


@pytest.mark.parametrize(
    ("result", "expected"),
    [
        ("pending_quorum:1/2", ("승인 대기 1/2", True)),
        ("stale", ("처리 안 함: 카드를 보낸 뒤 내용이 바뀌었습니다", True)),
        ("expired", ("처리 안 함: 카드가 만료되었습니다", True)),
        ("self_review", ("거부: 직접 제안한 항목은 승인할 수 없습니다", False)),
        ("mismatch", ("처리 안 됨: mismatch", False)),
    ],
)
def test_verdict_line_maps_every_decide_result(result: str, expected: tuple[str, bool]) -> None:
    assert slack_app.verdict_line(result) == expected


@pytest.mark.db
def test_main_wires_env_tokens_and_bolt_routes_the_three_events_to_the_handlers(
    slack_db: Pool, fresh_db: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    started: list[str] = []
    apps: list[App] = []
    fake = FakeSlack()

    def make_app(token: str) -> App:
        started.append(token)
        authorize = AuthorizeResult(enterprise_id=None, team_id=TEAM, bot_token="x")  # noqa: S106
        apps.append(
            App(
                authorize=lambda **_: authorize,
                process_before_response=True,
                request_verification_enabled=False,
                token_verification_enabled=False,
                ssl_check_enabled=False,
            )
        )
        return apps[0]

    for name, value in (("SLACK_BOT_TOKEN", "bot-test"), ("SLACK_APP_TOKEN", "app-test")):
        monkeypatch.setenv(name, value)
    monkeypatch.setenv("NUNCHI_TENANT_ID", str(TENANT))
    monkeypatch.setenv("NUNCHI_DATABASE_URL", "postgresql://unused")
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("NUNCHI_EMBEDDING_BASE_URL", raising=False)
    monkeypatch.setattr(slack_main, "App", make_app)
    monkeypatch.setattr(
        slack_main,
        "Deps",
        lambda pool, ext, tenant, _c, emb, judge: Deps(pool, ext, tenant, fake, emb, judge),
    )
    monkeypatch.setattr(slack_main, "open_pool", lambda _settings: slack_db)
    monkeypatch.setattr(
        slack_main,
        "SocketModeHandler",
        lambda _app, token: SimpleNamespace(start=lambda: started.append(token)),
    )
    assert slack_main.main() == 0
    assert started == ["bot-test", "app-test"]

    def send(body: dict[str, Any]) -> int:
        return apps[0].dispatch(BoltRequest(body=json.dumps(body), mode="socket_mode")).status

    envelope: dict[str, Any] = {"type": "event_callback", "token": "t", "team_id": TEAM}
    pin = reaction()["event"]
    mention = {"type": "app_mention", "user": "UREACT", "channel": "C1", "ts": "2.2"}
    card: dict[str, Any] = {
        "type": "block_actions",
        "team": {"id": TEAM},
        "user": {"id": "UNONE", "team_id": TEAM},
    }
    card |= {"actions": [{"type": "button", "action_id": "reject", "block_id": "b", "value": "{}"}]}
    card |= {"channel": {"id": "D1"}, "message": {"ts": "9.9", "blocks": [{"type": "section"}]}}
    statuses = [
        send(envelope | {"event_id": "Ev1", "event": pin}),
        send(envelope | {"event_id": "Ev2", "event": mention}),
        send(card),
    ]
    assert statuses == [200, 200, 200]
    assert [m[:2] for m in memories(fresh_db)] == [
        (TEXT, "provisional"),
        ("스테이징 DB 는 매일 새벽에 초기화된다", "provisional"),
    ]
    assert fake.updates[0][2] == "Slack 계정이 연결되어 있지 않습니다"
