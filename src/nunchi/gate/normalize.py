"""Canonical form of untrusted text, so rules match what a reader would see."""

import re
import unicodedata

_INVISIBLE = re.compile(
    "[\u00ad\u034f\u061c\u180e\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u206f\ufeff]"
)

# Cyrillic letters and Hangul jamo that render like Latin letters. The jamo are the code
# points NFKC produces from compatibility jamo (\u3147 and \u3163), so they run after NFKC.
_FROM = (
    "\u0410\u0412\u0415\u041a\u041c\u041d\u041e\u0420\u0421\u0422\u0425\u0406\u0408\u0405"
    "\u0430\u0435\u043e\u0440\u0441\u0443\u0445\u0456\u0458\u0455\u04bb\u0501\u051b\u051d"
    "\u110b\u1175"
)
_TO = "ABEKMHOPCTXIJSaeopcyxijshdqwol"
_HOMOGLYPHS = str.maketrans(_FROM, _TO)


def normalize(text: str) -> str:
    """NFKC, drop invisible characters, fold homoglyphs, collapse whitespace."""
    without_invisible = _INVISIBLE.sub("", text)
    folded = unicodedata.normalize("NFKC", without_invisible).translate(_HOMOGLYPHS)
    return " ".join(folded.split())
