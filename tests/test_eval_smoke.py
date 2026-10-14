import json
from collections.abc import Sequence
from datetime import date
from pathlib import Path
from uuid import UUID

import pytest
from eval import score
from eval.corpus import Message, Query, load_messages, load_queries, window_groups
from eval.db import fresh_database
from eval.embedding import CachingEmbedder
from eval.oracle import GOLD_VALUES, WINDOW_VALUES, ConceptEmbedder, OracleExtractor, OracleJudge
from eval.run import main, replay_group, run_eval, run_window_eval, table
from eval.score import Outcome
from eval.sweep import run_sweep, sweep_table
from eval.windows import (
    Check,
    CheckedExtractor,
    consensus_metrics,
    load_windows,
    replay_windows,
    window_messages,
    window_metrics,
)

from nunchi.config import Settings
from nunchi.db import open_pool
from nunchi.domain.models import MemoryKind, MemoryOrigin
from nunchi.embed import PromptName
from nunchi.extract import Candidate, Consensus, ExtractContext, RelationKind


def test_corpus_labels_are_consistent() -> None:
    messages = load_messages()
    ids = {m.memory for m in messages if m.memory}
    assert all(m.updates in ids for m in messages if m.relation == "update")
    assert all(m.kind and m.memory for m in messages if m.remember)
    assert all(q.gold and set(q.gold) <= ids for q in load_queries())
    assert sum(m.secret for m in messages) == 7


def _msg(relation: str, *, remember: bool = True) -> Message:
    return Message(
        id="s",
        day=1,
        text="t",
        remember=remember,
        kind="fact" if remember else None,
        subject="A사" if remember else None,
        attribute="담당자" if remember else None,
        relation=relation,
        memory="m1" if remember else None,
        updates=None,
    )


def test_score_counts_by_hand() -> None:
    sid = UUID(int=1)
    outcomes = [
        Outcome(message=_msg("new"), result="created", memory_id=sid, db_kind="fact"),
        Outcome(message=_msg("same"), result="created", memory_id=sid, db_kind="note"),
        Outcome(
            message=_msg("update"), result="created", memory_id=sid, db_kind="fact", conflicted=True
        ),
        Outcome(message=_msg("none", remember=False), result="reconfirmed", memory_id=sid),
        Outcome(message=_msg("new"), result="skipped"),
    ]
    assert score.extraction(outcomes)["precision"] == 0.75
    assert score.extraction(outcomes)["recall"] == 0.75
    assert score.kind_accuracy(outcomes) == pytest.approx(0.667, abs=0.001)
    assert score.relation_accuracy(outcomes) == {"new": 1.0, "same": 0.0, "update": 1.0}
    query = Query(id="q", query="x", gold=("m1",))
    mapping = score.gold_by_db_id(outcomes)
    assert score.search_ranks(query, [UUID(int=9), sid], mapping) == 2


@pytest.mark.db
def test_harness_runs_five_messages_with_the_oracle(admin_url: str) -> None:
    messages = load_messages(5)
    query = Query(id="q", query="결제 모듈 DB", gold=("m08",))
    report = run_eval(admin_url, OracleExtractor(load_messages()), messages, [query])
    assert [o["result"] for o in report["outcomes"]] == [
        "skipped",
        "created",
        "skipped",
        "skipped",
        "created",
    ]
    assert report["extraction"]["precision"] == 1.0
    assert report["extraction"]["recall"] == 1.0
    assert report["fragmentation"]["entity_rows"] == 2
    assert report["extraction"]["unapproved"] == 2
    assert report["search"] == {"recall@1": 1.0, "recall@5": 1.0}
    assert "extraction precision        1.0" in table(report)


def test_noisy_oracle_restates_with_the_next_spelling() -> None:
    messages = [m for m in load_messages() if m.subject == "A사" and m.attribute == "담당자"]
    oracle = OracleExtractor(load_messages(), noisy=True)
    ctx = ExtractContext(
        origin=MemoryOrigin.EXTERNAL,
        today=date(2026, 10, 13),
        store_id=UUID(int=1),
    )
    spelled = []
    for m in messages[:5]:
        (draft,) = oracle.extract(m.filled, ctx)
        spelled.append((draft.subject_name, draft.attribute))
    assert spelled == [
        ("A사", "담당자"),
        ("에이사", "컨택"),
        ("A Corp", "담당 PM"),
        ("에이 사", "PM"),
        ("에이사", "컨택"),
    ]


def test_concept_embedder_puts_every_spelling_on_one_axis() -> None:
    a, b, c = ConceptEmbedder().embed(["A사", "에이사", "담당 pm"], "query")
    assert a == b
    assert a != c


def test_every_gold_memory_has_a_value_and_updates_change_it() -> None:
    messages = load_messages()
    ids = {m.memory for m in messages if m.memory}
    assert set(GOLD_VALUES) == ids
    assert all(
        GOLD_VALUES[m.memory] != GOLD_VALUES[m.updates] for m in messages if m.updates and m.memory
    )


def test_noisy_oracle_rewords_the_body_and_keeps_the_value() -> None:
    restated = [m for m in load_messages() if m.memory == "m01"]
    ctx = ExtractContext(
        origin=MemoryOrigin.EXTERNAL, today=date(2026, 10, 13), store_id=UUID(int=1)
    )
    clean = [OracleExtractor(load_messages()).extract(m.filled, ctx)[0] for m in restated]
    noisy = [
        OracleExtractor(load_messages(), noisy=True).extract(m.filled, ctx)[0] for m in restated
    ]
    assert len({d.body for d in clean}) == 1
    assert [d.body for d in noisy] == [m.filled for m in restated]
    assert {d.value for d in clean + noisy} == {"이민수"}


class CountingEmbedder:
    model = "count-1"

    def __init__(self) -> None:
        self.texts: list[str] = []

    def embed(self, texts: Sequence[str], prompt_name: PromptName) -> list[list[float]]:
        self.texts.extend(texts)
        return [[1.0] + [0.0] * 511 for _ in texts]


def test_caching_embedder_asks_the_service_once_per_text_and_prompt() -> None:
    inner = CountingEmbedder()
    cached = CachingEmbedder(inner)
    cached.embed(["a", "b", "a"], "query")
    cached.embed(["a"], "query")
    cached.embed(["a"], "document")
    assert inner.texts == ["a", "b", "a"]


@pytest.mark.db
def test_noisy_restatements_are_still_same_because_the_value_matches(admin_url: str) -> None:
    messages = load_messages(40)
    report = run_eval(
        admin_url, OracleExtractor(load_messages(), noisy=True), messages, [], ConceptEmbedder()
    )
    assert report["relation_accuracy"] == {"new": 1.0, "same": 1.0, "update": 1.0}


@pytest.mark.db
def test_sweep_scores_trigram_then_every_embed_text_floor_and_k(admin_url: str) -> None:
    rows = run_sweep(
        admin_url,
        OracleExtractor(load_messages()),
        load_messages(),
        load_queries(),
        ConceptEmbedder(),
    )
    grid = [(r["embed_text"], r["floor"], r["k"]) for r in rows]
    assert len(grid) == 17
    assert grid[0] == ("trigram", None, None)
    assert grid[1] == ("title", 0.2, 20)
    assert grid[9] == ("title+body", 0.2, 20)
    assert grid[-1] == ("title+body", 0.5, 60)
    # Equal scores break ties by random row id, so recall can wobble by a query or two between runs.
    # A changed value is a challenger now and search does not show challengers before U37, so the
    # queries whose gold is a changed value find nothing: ten runs gave 0.310 and 0.381.
    assert rows[0]["recall@1"] == pytest.approx(0.31, abs=0.03)
    assert rows[0]["recall@5"] == pytest.approx(0.38, abs=0.03)
    assert sweep_table(rows).splitlines()[1].split()[:3] == ["trigram", "-", "-"]


def test_sweep_flag_needs_an_embedder(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["--db", "unused", "--extractor", "fake", "--sweep"]) == 2
    assert "needs --embedder" in capsys.readouterr().err


@pytest.mark.db
def test_sweep_flag_prints_the_table_and_saves_json(
    admin_url: str, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = ["--db", admin_url, "--extractor", "fake", "--embedder", "concept", "--sweep"]
    assert main([*argv, "--limit", "12", "--out-dir", str(tmp_path)]) == 0
    assert capsys.readouterr().out.startswith("embed text   floor    k  recall@1  recall@5\n")
    assert len(json.loads(next(tmp_path.glob("sweep-*.json")).read_text())) == 17


def test_noisy_oracle_drifts_values_by_honorific_and_wording() -> None:
    ctx = ExtractContext(
        origin=MemoryOrigin.EXTERNAL, today=date(2026, 10, 13), store_id=UUID(int=1)
    )

    def values(memory: str) -> list[str | None]:
        oracle = OracleExtractor(load_messages(), noisy=True)
        drafts = (oracle.extract(m.filled, ctx)[0] for m in load_messages() if m.memory == memory)
        return [d.value for d in drafts]

    assert values("m01")[:3] == ["이민수", "이민수님", "이민수 매니저님"]
    assert values("m25")[:2] == ["매일 03시, 14일 보관", "매일 새벽 3시, 14일 보관"]


def test_corpus_has_ten_multi_item_windows_with_one_text_each() -> None:
    groups = [g for g in window_groups(load_messages()) if g[0].group]
    assert len(groups) == 10
    assert all(len(g) >= 2 and len({m.text for m in g}) == 1 for g in groups)
    assert [len(g) for g in groups] == [3, 2, 3, 2, 2, 3, 2, 3, 2, 3]


def test_oracle_returns_one_draft_per_gold_item_of_a_window() -> None:
    oracle = OracleExtractor(load_messages())
    window = next(g for g in window_groups(load_messages()) if g[0].group == "g01")
    ctx = ExtractContext(
        origin=MemoryOrigin.EXTERNAL, today=date(2026, 10, 13), store_id=UUID(int=1)
    )
    drafts = oracle.extract(window[0].filled, ctx)
    assert [(d.subject_name, d.attribute, d.value) for d in drafts] == [
        ("리뉴얼 사이트", "프레임워크", "Next.js"),
        ("리뉴얼 사이트", "DB", "Postgres"),
        ("리뉴얼 사이트", "마감일", "2026-11-30"),
    ]


def test_item_recall_splits_multi_item_windows_from_single_messages() -> None:
    def item(group: str | None, result: str) -> Outcome:
        msg = _msg("new").model_copy(update={"group": group})
        return Outcome(message=msg, result=result, memory_id=UUID(int=1), db_kind="fact")

    outcomes = [item("g", "created"), item("g", "skipped"), item(None, "created")]
    assert score.item_recall(outcomes) == {"multi": 0.5, "single": 1.0}


def test_window_corpus_has_the_live_style_case_and_every_retraction_target() -> None:
    windows = load_windows()
    live = [w for w in windows if w.id.startswith("w-live-style-")]
    assert [w.id for w in live] == [f"w-live-style-{n}" for n in (1, 2, 3, 4)]
    assert {g.memory for w in live for g in w.gold} == {"wm01"}
    assert [len(w.gold) for w in live] == [1, 1, 1, 2]
    ids = {g.memory for w in windows for g in w.gold if g.memory}
    assert set(WINDOW_VALUES) == ids
    assert all(g.target in ids for w in windows for g in w.gold if g.relation == "retract")
    assert {g.status_after for w in windows for g in w.gold} == {
        None, "active", "provisional", "rejected",
    }  # fmt: skip


def _gold_window_outcomes() -> tuple[list[Outcome], dict[UUID, str]]:
    messages = {m.id: m for m in window_messages(load_windows())}

    def made(msg_id: str, n: int) -> Outcome:
        return Outcome(
            message=messages[msg_id], result="created", memory_id=UUID(int=n), db_kind="decision"
        )

    outcomes = [
        made("w-live-style-1.0", 1),
        made("w-live-style-2.0", 2),
        made("w-agree-1.0", 3),
        made("w-noagree-1.0", 4),
        Outcome(message=messages["w-retract-1.0"], result="skipped"),
    ]
    statuses = {UUID(int=1): "active", UUID(int=2): "active", UUID(int=3): "rejected"}
    statuses[UUID(int=4)] = "active"
    return outcomes, statuses


def test_window_metrics_count_by_hand() -> None:
    outcomes, statuses = _gold_window_outcomes()
    report = window_metrics(load_windows(), outcomes, statuses)
    assert report["wrongly_active"] == {"active": 3, "wrong": 1, "rate": 0.333}
    assert report["duplicate_per_key"]["rows_per_memory"] == {  # type: ignore[index]
        "wm01": 2, "wm02": 0, "wm04": 1,
    }  # fmt: skip
    assert report["duplicate_per_key"]["rate"] == 0.333  # type: ignore[index]
    assert report["retraction_recall"] == {"retractions": 2, "retracted": 1, "recall": 0.5}


@pytest.mark.db
def test_window_corpus_ends_with_the_timer_promotions_and_without_retractions(
    admin_url: str, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    windows = load_windows()
    report = run_window_eval(
        admin_url, OracleExtractor(window_messages(windows)), windows, judge=OracleJudge()
    )
    assert report["duplicate_per_key"]["rows_per_memory"]["wm01"] == 3
    assert report["duplicate_per_key"]["rate"] == 0.143
    statuses = report["duplicate_per_key"]["statuses"]
    assert (statuses["wm03"], statuses["wm04"], statuses["wm05"]) == (
        ["active"],
        ["provisional"],
        ["provisional"],
    )
    assert report["wrongly_active"] == {"active": 7, "wrong": 2, "rate": 0.286}
    assert report["retraction_recall"] == {"retractions": 2, "retracted": 0, "recall": 0.0}
    assert report["consensus_check"] == {
        "items": 13,
        "claimed_agreed": 4,
        "lowered": 0,
        "verified_agreed": 4,
        "wrongly_agreed": {"count": 0, "rate": 0.0},
        "missed_agreed": {"count": 0, "gold_agreed": 4},
    }
    noisy = run_window_eval(
        admin_url,
        OracleExtractor(window_messages(windows), noisy=True),
        windows,
        judge=OracleJudge(),
    )
    assert noisy["consensus_check"] == {
        "items": 13,
        "claimed_agreed": 13,
        "lowered": 9,
        "verified_agreed": 4,
        "wrongly_agreed": {"count": 0, "rate": 0.0},
        "missed_agreed": {"count": 0, "gold_agreed": 4},
    }
    argv = ["--db", admin_url, "--extractor", "noisy", "--windows", "--out-dir", str(tmp_path)]
    assert main(argv) == 0
    assert "live style rows (wm01)    3" in capsys.readouterr().out
    saved = json.loads(next(tmp_path.glob("windows-*.json")).read_text())
    assert saved["duplicate_per_key"]["rate"] == 0.143


@pytest.mark.db
def test_the_clock_ticks_on_each_new_day_and_once_after_the_last(admin_url: str) -> None:
    windows = load_windows()
    days: list[date] = []
    with fresh_database(admin_url) as app_url:
        pool = open_pool(Settings(database_url=app_url, pool_max_size=2))
        try:
            replay_windows(
                pool,
                windows,
                lambda p, group: replay_group(p, OracleExtractor(window_messages(windows)), group),
                lambda _pool, day: days.append(day),
            )
        finally:
            pool.close()
    assert [d.isoformat() for d in days] == [
        "2026-08-04", "2026-08-05", "2026-08-06", "2026-08-07", "2026-08-08",
        "2026-08-09", "2026-08-10", "2026-08-11", "2026-08-12",
    ]  # fmt: skip


def _window_draft_context() -> ExtractContext:
    return ExtractContext(
        origin=MemoryOrigin.EXTERNAL, today=date(2026, 8, 5), store_id=UUID(int=1)
    )


def test_the_windows_are_numbered_and_gold_carries_the_claim() -> None:
    windows = {w.id: w for w in load_windows()}
    live = windows["w-live-style-1"]
    assert live.text.splitlines()[2] == "[2] seoyeon.lee: 동의합니다. 그걸로 확정해요"
    claims = {w.id: [(g.consensus, g.evidence) for g in w.gold] for w in windows.values()}
    assert claims["w-live-style-1"] == [("agreed", (0, 1, 2))]
    assert claims["w-live-style-4"] == [("stated", (0,)), ("stated", (1,))]
    assert claims["w-declare-end"] == [("stated", (0,))]


def test_the_fake_copies_the_gold_claim_and_the_noisy_one_overclaims() -> None:
    windows = load_windows()
    messages = window_messages(windows)
    end = next(w for w in windows if w.id == "w-declare-end")
    for noisy, expected in ((False, Consensus.STATED), (True, Consensus.AGREED)):
        (draft,) = OracleExtractor(messages, noisy=noisy).extract(end.text, _window_draft_context())
        assert (draft.consensus, draft.evidence) == (expected, (0,))


def test_the_fake_retracts_the_candidate_that_holds_the_retracted_value() -> None:
    windows = load_windows()
    retract = next(w for w in windows if w.id == "w-retract-1")
    freeze = Candidate(
        id=UUID(int=7), kind=MemoryKind.DECISION, title="코드 프리즈", subject_name="릴리즈 1.0",
        attribute="코드 프리즈", value="12/18",
    )  # fmt: skip
    ctx = _window_draft_context().model_copy(update={"candidates": (freeze,)})
    oracle = OracleExtractor(window_messages(windows))
    (draft,) = oracle.extract(retract.text, ctx)
    assert (draft.relation.kind, draft.relation.target_id) == (RelationKind.RETRACTS, UUID(int=7))
    assert (draft.consensus, draft.evidence) == (Consensus.AGREED, (0, 1))
    assert oracle.extract(retract.text, _window_draft_context()) == ()


def test_the_checked_extractor_lowers_a_claim_the_window_does_not_prove() -> None:
    windows = load_windows()
    stated = next(w for w in windows if w.id == "w-stated-1")
    checked = CheckedExtractor(OracleExtractor(window_messages(windows), noisy=True), stated)
    (draft,) = checked.extract(stated.text, _window_draft_context())
    assert draft.consensus is Consensus.STATED
    assert checked.checks == [Check(claimed=Consensus.AGREED, verified=Consensus.STATED)]


def test_consensus_metrics_count_by_hand() -> None:
    windows = load_windows()
    agreed, stated = Consensus.AGREED, Consensus.STATED
    checks = {
        "w-live-style-1": [Check(claimed=agreed, verified=agreed)],
        "w-agree-1": [Check(claimed=agreed, verified=stated)],
        "w-stated-1": [Check(claimed=agreed, verified=agreed)],
        "w-timer-1": [Check(claimed=stated, verified=stated)],
    }
    assert consensus_metrics(windows, checks) == {
        "items": 4,
        "claimed_agreed": 3,
        "lowered": 1,
        "verified_agreed": 2,
        "wrongly_agreed": {"count": 1, "rate": 0.5},
        "missed_agreed": {"count": 1, "gold_agreed": 2},
    }
