"""The fake extractor: perfect gold labels, so a run measures the pipeline and not the model."""

import zlib
from collections import Counter
from collections.abc import Mapping, Sequence

from eval.corpus import Message
from nunchi.domain.models import MemoryKind
from nunchi.extract.draft import (
    Consensus,
    ExtractContext,
    ProposalDraft,
    Relation,
    RelationKind,
)

_TITLE_CHARS = 120

# How a restating model drifts: each later mention of a gold name takes the next spelling here.
SUBJECT_VARIANTS = {
    "A사": ("에이사", "A Corp", "에이 사"),
    "B사": ("비사", "B Corp", "비 사"),
    "결제 모듈": ("결제모듈", "payment module"),
    "배포 파이프라인": ("배포 파이프 라인", "deploy pipeline"),
    "스테이징 서버": ("스테이징서버", "staging server"),
    "BI 대시보드": ("비아이 대시보드", "BI dashboard"),
}
ATTRIBUTE_VARIANTS = {
    "담당자": ("컨택", "담당 PM", "PM"),
    "정산일": ("정산 날짜", "정산 마감일"),
    "롤백 방법": ("롤백 절차", "롤백 하는 법"),
    "알림 채널": ("알림 채널명", "알람 채널"),
    "DB 선택": ("데이터베이스 선택", "DB 종류"),
}


# The bare answer of each gold memory: what a restatement must agree on, in any wording.
GOLD_VALUES = {
    "m01": "이민수", "m02": "박민수", "m03": "2027-03-31", "m04": "2027-06-30",
    "m05": "최지우", "m06": "정하늘", "m07": "매월 25일", "m08": "Postgres",
    "m09": "Aurora PostgreSQL", "m10": "30초",
    "m11": "PR 머지→릴리즈 태그→/deploy prod→스모크 테스트",
    "m12": "배포봇", "m13": "매주 월요일 10시", "m14": "격주 월요일 10시",
    "m15": "프로파일 다운로드→import→사번+OTP 로그인",
    "m16": "staging.nunchi.example", "m17": "계정 발급→개발환경 세팅→버디 배정→코드 투어",
    "m18": "5영업일", "m19": "2명 승인", "m20": "#alerts-prod", "m21": "#oncall-alerts",
    "m22": "4시간", "m23": "2시간", "m24": "한솔", "m25": "매일 03시, 14일 보관",
    "m26": "목요일", "m27": "채널 생성→리드 지정→30분 공유→포스트모템", "m28": "90일",
    "m29": "stg.nunchi.example",
    "m30": "Next.js", "m31": "Postgres", "m32": "2026-11-30", "m33": "매주 금요일",
    "m34": "오세훈", "m35": "Grafana", "m36": "CPU 80%", "m37": "PagerDuty", "m38": "5초",
    "m39": "격주 금요일", "m40": "VPN 접속 후 qa.nunchi.example", "m41": "매월 5일",
    "m42": "팀장", "m43": "영수증 촬영→앱 등록→팀장 승인", "m44": "Figma Variables",
    "m45": "격주 수요일", "m46": "Vercel", "m47": "분기 1회", "m48": "윤서진",
    "m49": "2026-12-15", "m50": "한지민", "m51": "#launch",
}  # fmt: skip

# Memories of eval/corpus/windows.jsonl.
WINDOW_VALUES = {
    "wm01": "CSS Modules + CSS 커스텀 프로퍼티", "wm02": "12/18", "wm03": "#ops-alerts",
    "wm04": "목요일", "wm05": "warn", "wm06": "화요일", "wm07": "30일",
}  # fmt: skip
ALL_VALUES = {**GOLD_VALUES, **WINDOW_VALUES}
# The live restatement: one model call wrote "CSS 변수" for "CSS 커스텀 프로퍼티".
WINDOW_VARIANTS = {"wm01": ("CSS Modules + CSS 변수",)}

# Noisy only. Person values come back with an honorific or a title on later mentions.
HONORIFIC_SUFFIXES = ("님", " 매니저님")
PERSON_MEMORIES = ("m01", "m02", "m05", "m06", "m24")
# Long values restated in other words: the same answer, not a new one.
VALUE_VARIANTS = {
    "m11": ("PR 머지→태그→/deploy prod→5분 스모크",),
    "m12": ("배포봇으로만",),
    "m15": ("OpenVPN 프로파일→사번+OTP 로그인",),
    "m17": ("계정 발급→개발환경 세팅→첫 주 버디→2주차 코드 투어",),
    "m25": ("매일 새벽 3시, 14일 보관",),
    "m27": ("#incident 채널→리드 지정→30분 공유→48시간 내 포스트모템",),
}


def _wording(m: Message) -> str:
    """A window's items share its text; the tag keeps their bodies apart, as a model's would be."""
    return f"{m.filled}\n({m.subject} {m.attribute})" if m.group else m.filled


class OracleJudge:
    """Gold knowledge: values are the same when they spell one gold value."""

    def __init__(self) -> None:
        self._group = {
            spelling: m
            for m, variants in {**VALUE_VARIANTS, **WINDOW_VARIANTS}.items()
            for spelling in (ALL_VALUES[m], *variants)
        }

    def same(self, first: str, second: str) -> bool:
        a, b = self._group.get(first), self._group.get(second)
        return a is not None and a == b


class OracleExtractor:
    """Returns the gold key, the gold value and a body for each gold memory, and copies the gold
    consensus and evidence; noisy, it claims `agreed` on everything, the overclaim the server's
    check exists to lower. Clean, the body is the
    first-seen wording, so a restatement carries the identical body the server hashes. Noisy, the
    body is the message's own wording and the key spellings drift, so only the value still says
    "same". A secret message gets a leaky draft on purpose,
    so the gate (and not the extractor) is what the run measures for it."""

    def __init__(self, messages: list[Message], *, noisy: bool = False) -> None:
        self._noisy = noisy
        self._seen: Counter[tuple[str, str]] = Counter()
        self._said: Counter[str] = Counter()
        self._by_text: dict[str, list[Message]] = {}
        for m in messages:
            if m.group is not None and m.filled in self._by_text:
                self._by_text[m.filled].append(m)
            else:
                self._by_text[m.filled] = [m]
        self._first: dict[str, str] = {}
        for m in messages:
            if m.memory is not None:
                self._first.setdefault(m.memory, _wording(m))

    def extract(self, source_text: str, context: ExtractContext) -> tuple[ProposalDraft, ...]:
        drafts = (self._draft(g, source_text, context) for g in self._by_text[source_text])
        return tuple(d for d in drafts if d is not None)

    def _draft(
        self, gold: Message, source_text: str, context: ExtractContext
    ) -> ProposalDraft | None:
        if gold.secret:
            return ProposalDraft(
                kind=MemoryKind.NOTE,
                title=source_text[:_TITLE_CHARS],
                body=source_text,
                source_refs=context.source_refs,
                origin=context.origin,
            )
        if gold.retracts is not None:
            return self._retraction(gold, context)
        if not gold.remember or gold.kind is None or gold.memory is None:
            return None
        text = _wording(gold) if self._noisy else self._first[gold.memory]
        return ProposalDraft(
            kind=gold.kind,
            title=text[:_TITLE_CHARS],
            body=text,
            value=self._value(gold.memory),
            subject_name=self._spell(gold.subject, SUBJECT_VARIANTS, ""),
            attribute=self._spell(gold.attribute, ATTRIBUTE_VARIANTS, gold.subject or ""),
            source_refs=context.source_refs,
            origin=context.origin,
            **self._claim(gold),
        )

    def _claim(self, gold: Message) -> dict[str, object]:
        agreed = self._noisy or gold.consensus == "agreed"
        return {
            "consensus": Consensus.AGREED if agreed else Consensus.STATED,
            "evidence": gold.evidence,
        }

    def _retraction(self, gold: Message, context: ExtractContext) -> ProposalDraft | None:
        """The candidate whose value is the retracted memory's, in any spelling the run produced."""
        spellings = {ALL_VALUES[gold.retracts or ""], *WINDOW_VARIANTS.get(gold.retracts or "", ())}
        target = next((c for c in context.candidates if c.value in spellings), None)
        if target is None or target.subject_name is None:
            return None
        return ProposalDraft(
            kind=target.kind,
            title=target.title,
            body=gold.filled,
            value=target.value,
            subject_name=target.subject_name,
            attribute=target.attribute,
            source_refs=context.source_refs,
            origin=context.origin,
            relation=Relation(kind=RelationKind.RETRACTS, target_id=target.id),
            **self._claim(gold),
        )

    def _value(self, memory: str) -> str:
        """The gold value; noisy, a memory's later mentions drift by honorific or wording."""
        n = self._said[memory]
        self._said[memory] += 1
        gold = ALL_VALUES[memory]
        if not self._noisy or n == 0:
            return gold
        if memory in PERSON_MEMORIES:
            return gold + HONORIFIC_SUFFIXES[(n - 1) % len(HONORIFIC_SUFFIXES)]
        variants = {**VALUE_VARIANTS, **WINDOW_VARIANTS}.get(memory)
        return variants[(n - 1) % len(variants)] if variants else gold

    def _spell(
        self, name: str | None, variants: Mapping[str, tuple[str, ...]], scope: str
    ) -> str | None:
        """The gold spelling the first time, then the variants in turn; a name with no listed
        variants keeps its gold spelling."""
        if name is None or not self._noisy or name not in variants:
            return name
        n = self._seen[scope, name]
        self._seen[scope, name] += 1
        return name if n == 0 else variants[name][(n - 1) % len(variants[name])]


class ConceptEmbedder:
    """Wiring check for the embedding path: every spelling of a name shares one axis, which is the
    answer the real embedder has to find on its own. Its numbers bound the real embedder above.
    A spelling nobody listed gets its own axis, so it is close to nothing."""

    model = "concept-1"
    _DIM = 512

    def __init__(self) -> None:
        tables = (SUBJECT_VARIANTS, ATTRIBUTE_VARIANTS)
        groups = [(k, v) for table in tables for k, v in table.items()]
        self._axes = {
            spelling.lower(): i for i, (k, v) in enumerate(groups) for spelling in (k, *v)
        }

    def embed(self, texts: Sequence[str], prompt_name: str) -> list[list[float]]:
        out = []
        for text in texts:
            vec = [0.0] * self._DIM
            vec[self._axes.get(text.lower(), 100 + zlib.crc32(text.encode()) % 400)] = 1.0
            out.append(vec)
        return out
