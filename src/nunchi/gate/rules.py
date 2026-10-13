"""The rule registry. Every gate decision comes from one row of RULES."""

import math
import re
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date
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
MSG_PII_BARE = "주민등록번호처럼 보이는 숫자입니다. 사람이 확인하세요"
MSG_PII_BARE_CARD = "카드번호처럼 보이는 숫자입니다. 사람이 확인하세요"
MSG_INSTRUCTION = "지시문처럼 보입니다. 사람이 내용을 확인하세요"

_ENTROPY_MIN_BITS = 3.5
_SEP = "[ ./-]?"
_CSEP = "[ ./-]"
_RRN_WINDOW = 20
_RRN_KEYWORD = re.compile("주민|등록번호|외국인|RRN|resident", re.IGNORECASE)
_INSTRUCTION_WINDOW = 15
_INSTRUCTION_OBJECT = re.compile("지시|명령|프롬프트")


def _is_rrn(m: re.Match[str]) -> bool:
    """Registration numbers issued since 2020-10 carry no checksum, so a real date is the test."""
    front = m["front"]
    year = (2000 if m["back"][0] in "3478" else 1900) + int(front[:2])
    try:
        date(year, int(front[2:4]), int(front[4:]))
    except ValueError:
        return False
    return True


def _near(m: re.Match[str], word: re.Pattern[str], window: int) -> bool:
    """True if `word` occurs within `window` characters before or after the match."""
    text = m.string
    return word.search(text, max(0, m.start() - window), m.end() + window) is not None


def _is_keyed_rrn(m: re.Match[str]) -> bool:
    return _is_rrn(m) and _near(m, _RRN_KEYWORD, _RRN_WINDOW)


def _is_unkeyed_rrn(m: re.Match[str]) -> bool:
    return _is_rrn(m) and not _near(m, _RRN_KEYWORD, _RRN_WINDOW)


def _is_directed_at_instructions(m: re.Match[str]) -> bool:
    return _near(m, _INSTRUCTION_OBJECT, _INSTRUCTION_WINDOW)


_CARD_SCHEMES: tuple[tuple[int, int, int, frozenset[int]], ...] = (
    (1, 4, 4, frozenset({13, 16, 19})),  # Visa
    (2, 51, 55, frozenset({16})),  # Mastercard
    (4, 2221, 2720, frozenset({16})),  # Mastercard 2-series
    (2, 34, 34, frozenset({15})),  # Amex
    (2, 37, 37, frozenset({15})),  # Amex
    (4, 3528, 3589, frozenset({16, 17, 18, 19})),  # JCB
    (1, 6, 6, frozenset({16, 17, 18, 19})),  # Discover, UnionPay
)
_CARD_WINDOW = 20
_CARD_KEYWORD = re.compile("카드|card|신용|결제|CVC|유효기간", re.IGNORECASE)


def _is_card(m: re.Match[str]) -> bool:
    """True if the digits have a real card scheme's issuer prefix and length and pass Luhn."""
    digits = [int(c) for c in m[0] if c.isdigit()]
    prefix_ok = any(
        lo <= int("".join(map(str, digits[:n]))) <= hi and len(digits) in lengths
        for n, lo, hi, lengths in _CARD_SCHEMES
    )
    doubled = [sum(divmod(d * 2, 10)) for d in digits[-2::-2]]
    luhn_ok = (sum(digits[::-2]) + sum(doubled)) % 10 == 0
    return prefix_ok and luhn_ok


def _is_keyed_card(m: re.Match[str]) -> bool:
    return _is_card(m) and _near(m, _CARD_KEYWORD, _CARD_WINDOW)


def _is_unkeyed_card(m: re.Match[str]) -> bool:
    return _is_card(m) and not _near(m, _CARD_KEYWORD, _CARD_WINDOW)


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
        re.compile(r"(?<!\d)(?P<front>\d{6})[- ](?P<back>[1-8]\d{6})(?!\d)"),
        Action.REJECT,
        MSG_PII,
        _is_rrn,
    ),
    Rule(
        "pii-kr-rrn-keyed",
        Kind.PII,
        re.compile(r"(?<!\d)(?P<front>\d{6})(?P<back>[1-8]\d{6})(?!\d)"),
        Action.REJECT,
        MSG_PII,
        _is_keyed_rrn,
    ),
    Rule(
        "pii-kr-rrn-bare",
        Kind.PII,
        re.compile(r"(?<!\d)(?P<front>\d{6})(?P<back>[1-8]\d{6})(?!\d)"),
        Action.FLAG,
        MSG_PII_BARE,
        _is_unkeyed_rrn,
    ),
    Rule(
        "pii-kr-phone",
        Kind.PII,
        re.compile(
            rf"(?<!\d)(?:\+?82{_SEP}\(?0?1[016789]\)?|\(?01[016789]\)?){_SEP}\d{{3,4}}{_SEP}\d{{4}}(?!\d)"
        ),
        Action.REJECT,
        MSG_PII,
    ),
    Rule(
        "pii-kr-card",
        Kind.PII,
        re.compile(
            rf"(?<!\d)(?:\d{{4}}(?:{_CSEP}\d{{4}}){{3}}(?:{_CSEP}\d{{1,3}})?|\d{{4}}{_CSEP}\d{{6}}{_CSEP}\d{{5}})(?!\d)"
        ),
        Action.REJECT,
        MSG_PII,
        _is_card,
    ),
    Rule(
        "pii-kr-card-keyed",
        Kind.PII,
        re.compile(r"(?<!\d)\d{13,19}(?!\d)"),
        Action.REJECT,
        MSG_PII,
        _is_keyed_card,
    ),
    Rule(
        "pii-kr-card-bare",
        Kind.PII,
        re.compile(r"(?<!\d)\d{13,19}(?!\d)"),
        Action.FLAG,
        MSG_PII_BARE_CARD,
        _is_unkeyed_card,
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
