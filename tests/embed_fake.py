"""Deterministic embedders for tests. A text's vector counts the concepts it mentions (one axis per
concept, 512 axes), so two paraphrases that share a concept are close and anything else is not."""

import math
from collections.abc import Sequence

from nunchi.embed import EmbedUnavailable, PromptName

DIM = 512


class FakeEmbedder:
    def __init__(self, concepts: dict[str, int], model: str = "fake-1") -> None:
        self.model = model
        self._concepts = concepts
        self.calls: list[tuple[PromptName, int]] = []

    def embed(self, texts: Sequence[str], prompt_name: PromptName) -> list[list[float]]:
        self.calls.append((prompt_name, len(texts)))
        return [self._vector(t) for t in texts]

    def _vector(self, text: str) -> list[float]:
        v = [0.0] * DIM
        for word, axis in self._concepts.items():
            if word in text:
                v[axis] += 1.0
        norm = math.sqrt(sum(x * x for x in v)) or 1.0
        return [x / norm for x in v]


class DownEmbedder:
    model = "fake-1"

    def embed(self, texts: Sequence[str], prompt_name: PromptName) -> list[list[float]]:
        msg = "service is down"
        raise EmbedUnavailable(msg)
