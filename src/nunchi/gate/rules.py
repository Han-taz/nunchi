"""The rule registry. Every gate decision comes from one row of RULES."""

import math
import re
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum


class Kind(StrEnum):
    CREDENTIAL = "credential"
    PII = "pii"
    INSTRUCTION = "instruction"


class Action(StrEnum):
    FLAG = "flag"
    REJECT = "reject"


Check = Callable[[re.Match[str]], bool]


@dataclass(frozen=True, slots=True)
class Rule:
    id: str
    kind: Kind
    pattern: re.Pattern[str]
    action: Action
    message: str
    check: Check | None = None


MSG_CRED = "비밀 정보(시크릿)가 포함되어 있습니다. 제거한 뒤 다시 제안하세요"
MSG_PII = "원문 링크로 대체하세요"
MSG_INSTRUCTION = "지시문처럼 보입니다. 사람이 내용을 확인하세요"

_RRN_WEIGHTS = (2, 3, 4, 5, 6, 7, 8, 9, 2, 3, 4, 5)
_ENTROPY_MIN_BITS = 3.5


def _check_digit(digits: str) -> int:
    total = sum(w * int(d) for w, d in zip(_RRN_WEIGHTS, digits[:12], strict=True))
    return (11 - total % 11) % 10


def _is_rrn(m: re.Match[str]) -> bool:
    digits = m["front"] + m["back"]
    return _check_digit(digits) == int(digits[12])


def _is_arn(m: re.Match[str]) -> bool:
    digits = m["front"] + m["back"]
    return (_check_digit(digits) + 2) % 10 == int(digits[12])


def _entropy(value: str) -> float:
    counts = Counter(value)
    return -sum(c / len(value) * math.log2(c / len(value)) for c in counts.values())


def _is_high_entropy(m: re.Match[str]) -> bool:
    return _entropy(m["value"]) >= _ENTROPY_MIN_BITS


_BANKS = (
    "[가-힣]{2,4}은행|카카오뱅크|토스뱅크|케이뱅크|농협|우체국|새마을금고|수협|신협|SC제일|계좌"
)
_KEYWORDS = "api[_-]?key|secret|token|passw(?:or)?d|passwd|pwd|credential|비밀번호|비번|시크릿|토큰"


RULES: tuple[Rule, ...] = (
    Rule(
        "secret-aws-key",
        Kind.CREDENTIAL,
        re.compile(r"(?<![A-Z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Z0-9])"),
        Action.REJECT,
        MSG_CRED,
    ),
    Rule(
        "secret-gcp-api-key",
        Kind.CREDENTIAL,
        re.compile(r"AIza[0-9A-Za-z_-]{35}"),
        Action.REJECT,
        MSG_CRED,
    ),
    Rule(
        "secret-gcp-service-account",
        Kind.CREDENTIAL,
        re.compile(r'"type"\s*:\s*"service_account"'),
        Action.REJECT,
        MSG_CRED,
    ),
    Rule(
        "secret-slack-token",
        Kind.CREDENTIAL,
        re.compile(r"\bxox[abeoprs]-[0-9A-Za-z-]{10,}|\bxapp-\d-[0-9A-Za-z-]{10,}"),
        Action.REJECT,
        MSG_CRED,
    ),
    Rule(
        "secret-github-token",
        Kind.CREDENTIAL,
        re.compile(r"\bgh[pousr]_[0-9A-Za-z]{36,}|\bgithub_pat_[0-9A-Za-z_]{22,}"),
        Action.REJECT,
        MSG_CRED,
    ),
    Rule(
        "secret-private-key",
        Kind.CREDENTIAL,
        re.compile(r"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY(?: BLOCK)?-----"),
        Action.REJECT,
        MSG_CRED,
    ),
    Rule(
        "secret-generic",
        Kind.CREDENTIAL,
        re.compile(
            rf"(?:{_KEYWORDS})s?\W{{0,3}}[:=]\s*[\"']?(?P<value>[A-Za-z0-9/+_=-]{{16,}})",
            re.IGNORECASE,
        ),
        Action.REJECT,
        MSG_CRED,
        _is_high_entropy,
    ),
    Rule(
        "pii-kr-rrn",
        Kind.PII,
        re.compile(r"(?<!\d)(?P<front>\d{6})[- ]?(?P<back>[1-4]\d{6})(?!\d)"),
        Action.REJECT,
        MSG_PII,
        _is_rrn,
    ),
    Rule(
        "pii-kr-arn",
        Kind.PII,
        re.compile(r"(?<!\d)(?P<front>\d{6})[- ]?(?P<back>[5-8]\d{6})(?!\d)"),
        Action.REJECT,
        MSG_PII,
        _is_arn,
    ),
    Rule(
        "pii-kr-phone",
        Kind.PII,
        re.compile(r"(?<!\d)(?:\+82[-. ]?10|01[016789])[-. ]?\d{3,4}[-. ]?\d{4}(?!\d)"),
        Action.REJECT,
        MSG_PII,
    ),
    Rule(
        "pii-kr-account",
        Kind.PII,
        re.compile(rf"(?:{_BANKS})\D{{0,10}}(?:\d{{2,6}}(?:-\d{{2,8}}){{1,3}}|\d{{10,14}})(?!\d)"),
        Action.REJECT,
        MSG_PII,
    ),
    Rule(
        "pii-kr-passport",
        Kind.PII,
        re.compile(
            r"(?:여권|(?i:passport))[^A-Za-z0-9]{0,10}[MSROD](?:\d{8}|\d{3}[A-Z]\d{4})(?![A-Za-z0-9])"
        ),
        Action.REJECT,
        MSG_PII,
    ),
    Rule(
        "inject-ignore-previous",
        Kind.INSTRUCTION,
        re.compile(
            r"\b(?:ignore|disregard|forget)\b[^.]{0,20}\b(?:previous|prior|above|earlier)\b"
            r"[^.]{0,20}\b(?:instructions?|prompts?|rules?)\b",
            re.IGNORECASE,
        ),
        Action.FLAG,
        MSG_INSTRUCTION,
    ),
    Rule(
        "inject-directive-en",
        Kind.INSTRUCTION,
        re.compile(
            r"\b(?:you (?:must|should|will) (?:always|never)|from now on|system prompt"
            r"|do not (?:tell|reveal|mention))\b",
            re.IGNORECASE,
        ),
        Action.FLAG,
        MSG_INSTRUCTION,
    ),
    Rule(
        "inject-ignore-previous-ko",
        Kind.INSTRUCTION,
        re.compile(
            r"(?:이전|위|앞선)\s?(?:의\s?)?(?:지시|지침|명령|프롬프트)\S{0,3}\s?(?:를\s?|은\s?)?(?:모두\s?)?(?:무시|잊)"
        ),
        Action.FLAG,
        MSG_INSTRUCTION,
    ),
    Rule(
        "inject-polite-imperative-ko",
        Kind.INSTRUCTION,
        re.compile(r"(?:하도록|해야)\s?합니다|하십시오"),
        Action.FLAG,
        MSG_INSTRUCTION,
    ),
)
