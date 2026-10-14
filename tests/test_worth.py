import pytest

from nunchi.capture.worth import not_worth
from nunchi.domain.models import MemoryKind, MemoryOrigin
from nunchi.extract import ProposalDraft


def draft(title: str, value: str = "값") -> ProposalDraft:
    return ProposalDraft(
        kind=MemoryKind.FACT,
        title=title,
        subject_name="S",
        attribute="a",
        value=value,
        origin=MemoryOrigin.INTERNAL,
    )


@pytest.mark.parametrize(
    "title",
    [
        "로그인 페이지 OAuth URL을 /auth/mattermost/authorize로 수정 필요",
        "S2 간격 토큰은 foundation.md 용어(spacing-xs~2xl)로 통일 필요",
        "배포 스크립트를 정리해야 한다",
        "다음 주에 마이그레이션을 할 예정",
        "백엔드 로그아웃 엔드포인트 구현 완료 (POST /auth/mattermost/logout)",
        "docs/design/foundation.md 머지 완료, §6 스타일 방식 기준 문서",
        "로그인 라우터를 푸시했다",
        "M1 백엔드 뼈대 작업 현황 (junho.park)",
        "PR #11 올렸습니다",
    ],
)
def test_todos_and_status_claims_are_not_worth_keeping(title: str) -> None:
    assert not_worth(draft(title)) is True


def test_a_status_claim_in_the_value_is_not_worth_keeping() -> None:
    assert not_worth(draft("로그아웃 엔드포인트", "구현 완료")) is True


@pytest.mark.parametrize(
    "title",
    [
        "CI 파이프라인(lint·타입·테스트)은 M1 완료 조건",
        "F2 팀 정보 출처를 Mattermost 팀 멤버십으로 결정",
        "Cloudflare beacon은 v1.0에서 제거",
        "마이그레이션 완료일은 3월 31일",
        "PR 머지 후 릴리즈 태그를 단다",
    ],
)
def test_decisions_and_facts_stay(title: str) -> None:
    assert not_worth(draft(title)) is False
