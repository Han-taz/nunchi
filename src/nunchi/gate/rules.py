"""The rule registry. Every gate decision comes from one row of RULES."""

import math
import re
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum


class Kind(StrEnum):
    CREDENTIAL = "credential"
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
MSG_INSTRUCTION = "지시문처럼 보입니다. 사람이 내용을 확인하세요"

_ENTROPY_MIN_BITS = 3.5
_INSTRUCTION_WINDOW = 15
_INSTRUCTION_OBJECT = re.compile("지시|명령|프롬프트")


def _is_directed_at_instructions(m: re.Match[str]) -> bool:
    """True if a word for instructions occurs within the window before or after the match."""
    start, end = max(0, m.start() - _INSTRUCTION_WINDOW), m.end() + _INSTRUCTION_WINDOW
    return _INSTRUCTION_OBJECT.search(m.string, start, end) is not None


def _entropy(value: str) -> float:
    counts = Counter(value)
    return -sum(c / len(value) * math.log2(c / len(value)) for c in counts.values())


def _is_high_entropy(m: re.Match[str]) -> bool:
    return _entropy(m["value"]) >= _ENTROPY_MIN_BITS


_KEYWORDS = (
    "api[_-]?key|secret|token|passw(?:or)?d|passwd|pwd|pw|credential"
    "|비밀번호|비번|패스워드|시크릿|토큰"
)


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
        "secret-url-credentials",
        Kind.CREDENTIAL,
        re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s:/@]+:[^\s/@]+@", re.IGNORECASE),
        Action.REJECT,
        MSG_CRED,
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
            r"(?:이전|위|앞선)\s?(?:의\s?)?(?:모든\s?)?(?:지시|지침|명령|프롬프트)\S{0,3}\s?(?:를\s?|은\s?)?(?:모두\s?)?(?:무시|잊)"
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
        _is_directed_at_instructions,
    ),
    Rule(
        "inject-polite-request-ko",
        Kind.INSTRUCTION,
        re.compile(
            r"(?:지시|명령|규칙(?!적)|프롬프트|시스템)[^.\n]{0,15}?(?:해 ?주세요|하세요|바랍니다)"
        ),
        Action.FLAG,
        MSG_INSTRUCTION,
    ),
)
