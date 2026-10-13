import json
from collections.abc import Sequence
from datetime import date
from pathlib import Path
from uuid import UUID

import pytest
from eval import score
from eval.corpus import Message, Query, load_messages, load_queries
from eval.embedding import CachingEmbedder
from eval.oracle import GOLD_VALUES, ConceptEmbedder, OracleExtractor
from eval.run import main, run_eval, table
from eval.score import Outcome
from eval.sweep import run_sweep, sweep_table

from nunchi.domain.models import MemoryOrigin
from nunchi.embed import PromptName
from nunchi.extract import ExtractContext


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
    assert report["extraction"]["unapproved"] == 0
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
        draft = oracle.extract(m.filled, ctx)
        assert draft is not None
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
    clean = [OracleExtractor(load_messages()).extract(m.filled, ctx) for m in restated]
    noisy = [OracleExtractor(load_messages(), noisy=True).extract(m.filled, ctx) for m in restated]
    assert len({d.body for d in clean if d}) == 1
    assert [d.body for d in noisy if d] == [m.filled for m in restated]
    assert {d.value for d in clean + noisy if d} == {"이민수"}


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
    # Equal scores break ties by random row id, so recall wobbles by a query or two between runs.
    assert rows[0]["recall@1"] == pytest.approx(0.62, abs=0.05)
    assert rows[0]["recall@5"] == pytest.approx(0.667, abs=0.05)
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
        drafts = (oracle.extract(m.filled, ctx) for m in load_messages() if m.memory == memory)
        return [d.value for d in drafts if d]

    assert values("m01")[:3] == ["이민수", "이민수님", "이민수 매니저님"]
    assert values("m25")[:2] == ["매일 03시, 14일 보관", "매일 새벽 3시, 14일 보관"]
