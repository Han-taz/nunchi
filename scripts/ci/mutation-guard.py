#!/usr/bin/env python3
"""Checks that keep mutation-gate.sh from turning "no mutants" into a silent pass.

usage:
  mutation-guard.py exact MODULE       read mutmut results on stdin, print only MODULE's own mutants
  mutation-guard.py logic FILE          exit 1 if FILE contains logic, 0 if it is constants only
  mutation-guard.py pragma BASE_REF     exit 1 if the diff adds `pragma: no mutate` under src/
  mutation-guard.py is-pragma TEXT      exit 0 if TEXT would count as a pragma (self-test hook)
  mutation-guard.py config BASE_REF     exit 1 if any [tool.mutmut] key differs from BASE_REF

A module is constants only when every top-level statement is an import, a docstring, `pass`,
an assignment to plain names of a value on a strict allowlist (literals, names, dotted names,
tuples/lists/sets/dicts of those, a negated literal, `x[literal]` of a dotted name, a bare
`auto()`/`enum.auto()`), a class of the same with dotted-name bases, or an
`if TYPE_CHECKING:` block of imports only. Every other expression (calls, conditionals,
and/or, operators, comparisons, comprehensions, lambdas, f-strings) and every function,
method or control flow statement counts as logic.
"""

import ast
import re
import subprocess
import sys
import tomllib

PRAGMA_MARK = re.compile(r"#\s*pragma\s*:", re.IGNORECASE)
PRAGMA_NO_MUTATE = re.compile(r"no\s*mutate", re.IGNORECASE)
ARGC = 3


def _is_dotted(node: ast.AST | None) -> bool:
    match node:
        case ast.Name():
            return True
        case ast.Attribute(value=value):
            return _is_dotted(value)
    return False


def _is_auto_call(node: ast.Call) -> bool:
    if node.args or node.keywords:
        return False
    match node.func:
        case ast.Name(id="auto") | ast.Attribute(value=ast.Name(id="enum"), attr="auto"):
            return True
    return False


def _container_is_constant(node: ast.AST) -> bool:
    match node:
        case ast.Tuple(elts=elts) | ast.List(elts=elts) | ast.Set(elts=elts):
            return all(_value_is_constant(e) for e in elts)
        case ast.Dict(keys=keys, values=values):
            return all(k is not None and _value_is_constant(k) for k in keys) and all(
                _value_is_constant(v) for v in values
            )
    return False


def _value_is_constant(node: ast.AST | None) -> bool:
    """Strict allowlist. Anything not named here (calls, conditionals, operators, ...) is logic."""
    match node:
        case None | ast.Constant() | ast.Name():
            return True
        case ast.Attribute():
            return _is_dotted(node)
        case ast.UnaryOp(op=ast.USub(), operand=ast.Constant()):
            return True
        case ast.Subscript(value=value, slice=ast.Constant()):
            return _is_dotted(value)
        case ast.Call():
            return _is_auto_call(node)
    return _container_is_constant(node)


def _assign_is_constant(stmt: ast.Assign | ast.AnnAssign) -> bool:
    targets = stmt.targets if isinstance(stmt, ast.Assign) else [stmt.target]
    if not all(isinstance(t, ast.Name) for t in targets):
        return False
    if isinstance(stmt, ast.AnnAssign) and not _value_is_constant(stmt.annotation):
        return False
    return _value_is_constant(stmt.value)


def _body_is_constant(body: list[ast.stmt]) -> bool:
    for stmt in body:
        match stmt:
            case ast.Import() | ast.ImportFrom() | ast.Pass():
                continue
            case ast.If() if _is_type_checking_imports(stmt):
                continue
            case ast.Expr(value=ast.Constant()):
                continue
            case ast.Assign() | ast.AnnAssign():
                if not _assign_is_constant(stmt):
                    return False
            case ast.ClassDef(bases=bases, keywords=keywords, decorator_list=[]):
                if not all(_is_dotted(b) for b in bases):
                    return False
                if not all(_is_dotted(k.value) for k in keywords):
                    return False
                if not _body_is_constant(stmt.body):
                    return False
            case _:
                return False
    return True


def _is_type_checking(test: ast.expr) -> bool:
    match test:
        case ast.Name(id="TYPE_CHECKING"):
            return True
        case ast.Attribute(value=ast.Name(id="typing"), attr="TYPE_CHECKING"):
            return True
    return False


def _is_type_checking_imports(node: ast.If) -> bool:
    return (
        _is_type_checking(node.test)
        and not node.orelse
        and all(isinstance(s, ast.Import | ast.ImportFrom) for s in node.body)
    )


def has_logic(source: str) -> bool:
    return not _body_is_constant(ast.parse(source).body)


def exact_module_mutants(module: str, results: str) -> list[str]:
    """Result lines for MODULE's own mutants.

    A mutant key is `<module>.<mutant name>` and the mutant name has no dot, so a module that
    is a prefix of another (`nunchi.d` vs `nunchi.domain`) never borrows its mutants.
    """
    prefix = module + "."
    hits = []
    for line in results.splitlines():
        key = line.strip().split(": ", 1)[0]
        if key.startswith(prefix) and "." not in key[len(prefix) :] and ": " in line:
            hits.append(line)
    return hits


def git(*args: str) -> str:
    result = subprocess.run(  # noqa: S603
        ["git", *args],  # noqa: S607
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def is_pragma(text: str) -> bool:
    """True for a comment with `# pragma:` and `no mutate`, any spacing or case (as mutmut)."""
    comment = text[text.find("#") :] if "#" in text else ""
    return bool(PRAGMA_MARK.search(comment) and PRAGMA_NO_MUTATE.search(comment))


def added_pragmas(base: str) -> list[str]:
    hits = []
    path, line = "", 0
    for row in git("diff", "-U0", f"{base}...HEAD", "--", "src/").splitlines():
        if row.startswith("+++ "):
            path = row[6:] if row.startswith("+++ b/") else ""
        elif row.startswith("@@"):
            line = int(re.search(r"\+(\d+)", row).group(1)) - 1
        elif row.startswith("+") and not row.startswith("+++"):
            line += 1
            if is_pragma(row):
                hits.append(f"{path}:{line}")
    return hits


def mutmut_config(rev: str) -> dict:
    try:
        text = git("show", f"{rev}:pyproject.toml")
    except subprocess.CalledProcessError:
        return {}
    return tomllib.loads(text).get("tool", {}).get("mutmut", {})


def changed_config_keys(base: str) -> list[str]:
    old, new = mutmut_config(base), mutmut_config("HEAD")
    return sorted(k for k in old.keys() | new.keys() if old.get(k) != new.get(k))


def main(argv: list[str]) -> int:
    if len(argv) != ARGC or argv[1] not in ("logic", "pragma", "config", "is-pragma", "exact"):
        print(__doc__, file=sys.stderr)
        return 2
    cmd, arg = argv[1], argv[2]
    if cmd == "logic":
        with open(arg, encoding="utf-8") as f:
            return int(has_logic(f.read()))
    if cmd == "exact":
        for line in exact_module_mutants(arg, sys.stdin.read()):
            print(line)
        return 0
    if cmd == "is-pragma":
        return int(not is_pragma(arg))
    if cmd == "pragma":
        hits = added_pragmas(arg)
        for hit in hits:
            print(
                f"mutation-gate: {hit} adds a 'pragma: no mutate' comment; "
                "this PR may not exempt code from mutation"
            )
        return int(bool(hits))
    keys = changed_config_keys(arg)
    for key in keys:
        print(f"mutation-gate: [tool.mutmut] {key} changed in pyproject.toml")
    return int(bool(keys))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
