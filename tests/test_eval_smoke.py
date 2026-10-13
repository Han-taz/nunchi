from uuid import UUID

import pytest
from eval import score
from eval.corpus import Message, Query, load_messages, load_queries
from eval.oracle import OracleExtractor
from eval.run import run_eval, table
from eval.score import Outcome


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
