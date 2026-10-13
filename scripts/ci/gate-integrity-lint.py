"""Prove a pull_request_target workflow never executes code from the PR head.

usage: python3 -I scripts/ci/gate-integrity-lint.py [WORKFLOW]

The workflow is parsed with a strict YAML loader and the parsed document is checked against
an allowlist. Nothing here reads the YAML text with patterns, so spelling tricks such as
`run : x`, quoted keys, flow style or `? key` cannot hide a key: they parse to the same key
and meet the same allowlist.
"""

import sys
from collections.abc import Iterator
from typing import Any

try:
    import yaml
except ImportError:
    print("::error::PyYAML is not installed; install .github/tools/requirements.txt")
    sys.exit(1)

CHECKOUT = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
PR_NUMBER = "${{ github.event.pull_request.number }}"
BASE_SHA = "${{ github.event.pull_request.base.sha }}"
NOT_CANCELLED = "${{ !cancelled() }}"

EXPRESSIONS = (PR_NUMBER, BASE_SHA, NOT_CANCELLED)

TOP_KEYS = {"name", "on", "permissions", "concurrency", "jobs"}
JOB_KEYS = {"name", "runs-on", "timeout-minutes", "permissions", "env", "steps"}
STEP_KEYS = {"name", "if", "uses", "with", "run"}
FORBIDDEN_KEYS = {"shell", "defaults", "container", "services"}

ON = {"pull_request_target": {"types": ["opened", "synchronize", "reopened"]}}
CONCURRENCY = {"group": "gate-integrity-" + PR_NUMBER, "cancel-in-progress": True}
JOB = {
    "name": "gate-integrity",
    "runs-on": "ubuntu-24.04",
    "timeout-minutes": 10,
    "permissions": {"contents": "read"},
}
ENV = {"PR_NUMBER": PR_NUMBER, "BASE_SHA": BASE_SHA, "HEAD_REF": "refs/remotes/pr/head"}
ACTIONS = {CHECKOUT: {"ref": BASE_SHA, "fetch-depth": 0, "persist-credentials": False}}
IFS = (NOT_CANCELLED,)
RUNS = (
    'git fetch --no-tags origin "+refs/pull/${PR_NUMBER}/head:refs/remotes/pr/head"',
    'scripts/ci/gate-files-report.sh "$BASE_SHA" "$HEAD_REF"',
    'scripts/ci/pr-size.sh "$BASE_SHA" "$HEAD_REF" 800',
    'scripts/ci/migrations-immutable.sh "$BASE_SHA" "$HEAD_REF"',
    'scripts/ci/check-commits.sh "$BASE_SHA" "$HEAD_REF"',
    'scripts/ci/expectations-guard.sh "$BASE_SHA" "$HEAD_REF"',
)


class Rejected(Exception):
    pass


class StrictLoader(yaml.SafeLoader):
    """SafeLoader that refuses every YAML feature that can hide or rename a key."""

    def compose_node(self, parent: yaml.Node | None, index: object) -> yaml.Node | None:
        if self.check_event(yaml.AliasEvent):
            raise Rejected("aliases are not allowed")
        event = self.peek_event()
        if event.anchor is not None:
            raise Rejected("anchors are not allowed")
        if getattr(event, "tag", None) is not None:
            raise Rejected("explicit tags are not allowed")
        return super().compose_node(parent, index)

    def construct_mapping(self, node: yaml.MappingNode, deep: bool = False) -> dict[str, Any]:
        keys: list[str] = []
        for key_node, _ in node.value:
            if not isinstance(key_node, yaml.ScalarNode):
                raise Rejected("complex (non-scalar) mapping keys are not allowed")
            if key_node.tag == "tag:yaml.org,2002:merge":
                raise Rejected("merge keys (<<) are not allowed")
            if key_node.value in keys:
                raise Rejected(f"duplicate key: {key_node.value}")
            keys.append(key_node.value)
        # Keys stay the raw text, so `on` is the string "on" and not the YAML 1.1 boolean.
        return {
            key_node.value: self.construct_object(value_node, deep=deep)
            for key_node, value_node in node.value
        }


def load(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    try:
        docs = list(yaml.load_all(text, Loader=StrictLoader))
    except Rejected:
        raise
    except yaml.YAMLError as exc:
        detail = " ".join(str(exc).split())
        raise Rejected(f"cannot parse the workflow: {type(exc).__name__}: {detail}") from exc
    if len(docs) != 1:
        raise Rejected("multi-document YAML is not allowed (exactly one document is required)")
    if not isinstance(docs[0], dict):
        raise Rejected("the workflow must be a mapping")
    return docs[0]


def scalars(node: object) -> Iterator[Any]:
    if isinstance(node, dict):
        for key, value in node.items():
            yield key
            yield from scalars(value)
    elif isinstance(node, list):
        for item in node:
            yield from scalars(item)
    else:
        yield node


def same(a: object, b: object) -> bool:
    if type(a) is not type(b):
        return False
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b, strict=True))
    return a == b


def bad_expressions(text: str) -> Iterator[str]:
    start = text.find("${{")
    while start != -1:
        if not text.startswith(EXPRESSIONS, start):
            close = text.find("}}", start)
            yield " ".join(text[start : close + 2 if close != -1 else len(text)].split())
        start = text.find("${{", start + 3)


def check_keys(where: str, mapping: dict[str, Any], allowed: set[str], errors: list[str]) -> None:
    for key in mapping:
        if key in FORBIDDEN_KEYS:
            errors.append(f"{where}: {key}: would change how run lines execute and is not allowed")
        elif key not in allowed:
            errors.append(f"{where}: key is not on the allowlist: {key}")
    for key in allowed - mapping.keys():
        errors.append(f"{where}: required key is missing: {key}")


def check_step(index: int, step: object, errors: list[str]) -> None:
    where = f"step {index + 1}"
    if not isinstance(step, dict):
        errors.append(f"{where}: must be a mapping")
        return
    for key in step.keys() & FORBIDDEN_KEYS:
        errors.append(f"{where}: {key}: would change how run lines execute and is not allowed")
    for key in step.keys() - STEP_KEYS - FORBIDDEN_KEYS:
        errors.append(f"{where}: step key is not on the allowlist: {key}")
    if ("uses" in step) == ("run" in step):
        errors.append(f"{where}: a step needs exactly one of uses and run")
    if "if" in step and step["if"] not in IFS:
        errors.append(f"{where}: if is not on the allowlist: {step['if']!r}")
    if "uses" in step:
        action = step["uses"]
        if not isinstance(action, str) or action not in ACTIONS:
            errors.append(f"{where}: uses is not on the SHA-pinned allowlist: {action!r}")
        elif not same(step.get("with"), ACTIONS[action]):
            expected, found = ACTIONS[action], step.get("with")
            errors.append(f"{where}: with: must be exactly {expected}, found {found!r}")
    elif "with" in step:
        errors.append(f"{where}: with: is only allowed on an allowlisted action")
    if "run" in step:
        body = step["run"]
        if not isinstance(body, str) or body not in RUNS:
            errors.append(f"{where}: run body is not on the allowlist: {body!r}")


def check_job(job: object, errors: list[str]) -> None:
    if not isinstance(job, dict):
        errors.append("job: must be a mapping")
        return
    check_keys("job", job, JOB_KEYS, errors)
    for key, expected in JOB.items():
        if key in job and not same(job[key], expected):
            errors.append(f"job: {key} must be {expected!r}, found {job[key]!r}")
    env = job.get("env")
    if not isinstance(env, dict):
        errors.append("job: env must be a mapping")
    else:
        for key, value in env.items():
            if key not in ENV:
                errors.append(f"env key is not on the allowlist: {key}")
            elif not same(value, ENV[key]):
                errors.append(f"env {key} must be {ENV[key]!r}, found {value!r}")
    steps = job.get("steps")
    if not isinstance(steps, list) or not steps:
        errors.append("job: steps must be a list")
        return
    if not (isinstance(steps[0], dict) and steps[0].get("uses") == CHECKOUT):
        errors.append("the first step must be the base checkout (actions/checkout)")
    for index, step in enumerate(steps):
        check_step(index, step, errors)


def check(doc: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    for text in (s for s in scalars(doc) if isinstance(s, str)):
        errors.extend(
            f"expression is not on the base-only allowlist: {e}" for e in bad_expressions(text)
        )

    check_keys("top level", doc, TOP_KEYS, errors)
    if doc.get("name") != "gate-integrity":
        errors.append("top level: name must be gate-integrity")
    if not same(doc.get("on"), ON):
        errors.append(f"trigger: the only trigger must be exactly {ON}, found {doc.get('on')!r}")
    if not same(doc.get("permissions"), {}):
        errors.append("top level: permissions must be {}")
    if not same(doc.get("concurrency"), CONCURRENCY):
        errors.append(f"top level: concurrency must be exactly {CONCURRENCY}")

    jobs = doc.get("jobs")
    if not isinstance(jobs, dict) or list(jobs) != ["gate-integrity"]:
        errors.append("jobs: the only job must be gate-integrity")
    else:
        check_job(jobs["gate-integrity"], errors)
    return errors


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else ".github/workflows/gate-integrity.yml"
    try:
        errors = check(load(path))
    except Rejected as exc:
        errors = [str(exc)]
    except Exception as exc:
        errors = [f"cannot check the workflow: {type(exc).__name__}: {exc}"]
    for message in errors:
        print(f"::error file={path}::{message}")
    if errors:
        return 1
    print(f"{path}: no step runs code from the pull request head")
    return 0


if __name__ == "__main__":
    sys.exit(main())
