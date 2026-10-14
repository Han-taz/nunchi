"""Statements that are never memories, however the extractor labelled them.

Todos ("수정 필요", "할 예정"), status claims ("구현 완료", "머지했다", "작업 현황") and PR
announcements go stale as the work moves, and one stored claim was false. The extractor prompt says
so; this is the server's own check on the draft's title and value."""

import re

from nunchi.extract import ProposalDraft

_TODO = re.compile(
    r"(?:필요|해야\s?(?:함|한다|합니다|됨|된다)|할\s?예정|예정이다|예정입니다)[\s.!)\]]*$"
)
_STATUS = re.compile(
    r"(?:구현|머지|푸시|배포|작업|적용|반영|수정|추가|연동)\s?(?:완료|했(?:다|습니다|어요|음))"
    r"|(?:푸시|머지)(?:했|됐|되었)"
    r"|(?:작업|진행)\s?현황"
)
_PR = re.compile(
    r"\bPR\s?#?\d+.{0,20}(?:올렸|올립니다|열었|오픈|리뷰\s?(?:요청|부탁))", re.IGNORECASE
)


def not_worth_text(title: str, value: str | None) -> bool:
    return bool(
        _TODO.search(title.strip())
        or _STATUS.search(title)
        or _PR.search(title)
        or (value is not None and _STATUS.search(value))
    )


def not_worth(draft: ProposalDraft) -> bool:
    return not_worth_text(draft.title, draft.value)
