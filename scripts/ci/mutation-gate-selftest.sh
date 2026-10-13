#!/usr/bin/env bash
# Prove mutation-gate.sh passes when no mutants exist only for modules without logic,
# fails on a low kill ratio, and cannot be bypassed with do_not_mutate, `pragma: no mutate`,
# a rename or logic in __init__.py. A fake `uv` stands in for mutmut and replays canned
# output; the AST, pragma and pyproject checks run for real on python >= 3.11.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
PY=""
for cand in python3.12 python3.11 "$here/../../.venv/bin/python" python3; do
  if command -v "$cand" >/dev/null 2>&1 &&
    "$cand" -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
    PY="$(command -v "$cand")"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "mutation-gate-selftest: needs python >= 3.11 (tomllib); install python3.12 or run 'uv sync --locked' for .venv" >&2
  exit 1
fi

script="$(cd "$(dirname "$0")" && pwd)/mutation-gate.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/repo"

cat >"$tmp/bin/uv" <<'SHIM'
#!/usr/bin/env bash
# uv run mutmut run [PATTERN] | uv run mutmut results --all true
case "$3" in
  run)
    case " ${SHIM_ZERO:-} " in
      *" ${4:-} "*)
        echo "AssertionError: Filtered for specific mutants, but nothing matches"
        exit 1
        ;;
      *) ;;
    esac
    [ -n "${SHIM_RUN_OUT:-}" ] && printf '%s\n' "$SHIM_RUN_OUT"
    exit "${SHIM_RUN_RC:-0}"
    ;;
  results) printf '%s' "${SHIM_RESULTS:-}" ;;
esac
SHIM
chmod +x "$tmp/bin/uv"
ln -s "$PY" "$tmp/bin/python3"

commit() { git -c user.name=t -c user.email=t@t commit -q "$@"; }

# newrepo DIR: an empty repo with a pyproject and the tag `base`
newrepo() {
  mkdir -p "$1/src/nunchi"
  cd "$1"
  git init -q
  printf '[tool.mutmut]\nsource_paths = ["src/nunchi/"]\n' >pyproject.toml
  git add -A
  commit -m base
  git tag base
}

newrepo "$tmp/repo"
echo 'X = 1' >src/nunchi/consts.py
printf 'from enum import StrEnum\n\n\nclass K(StrEnum):\n    A = "a"\n    B = "b"\n' >src/nunchi/enums.py
git add -A
commit -m constants
git tag consts_only
echo 'def f(): return 1' >src/nunchi/logic.py
git add -A
commit -m logic
git tag full

results() { # KILLED SURVIVED NOT_CHECKED
  local i
  for ((i = 1; i <= $1; i++)); do echo "    nunchi.m.x_f__mutmut_$i: killed"; done
  for ((i = 1; i <= $2; i++)); do echo "    nunchi.m.x_g__mutmut_$i: survived"; done
  for ((i = 1; i <= $3; i++)); do echo "    nunchi.m.x_h__mutmut_$i: not checked"; done
}

# case_ NAME WANT_RC PATTERN [ARGS...]  (env SHIM_* set by the caller)
case_() {
  local name="$1" want="$2" pattern="$3" rc=0
  shift 3
  PATH="$tmp/bin:$PATH" "$script" "$@" >"$tmp/out.log" 2>&1 || rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $name exited $rc, expected $want" >&2
    cat "$tmp/out.log" >&2
    exit 1
  fi
  if ! grep -q -- "$pattern" "$tmp/out.log"; then
    echo "FAIL: $name output lacked '$pattern':" >&2
    cat "$tmp/out.log" >&2
    exit 1
  fi
  echo "ok: $name -> exit $want"
}

git checkout -q consts_only
SHIM_ZERO="nunchi.consts* nunchi.enums*" \
  case_ "constants-only modules with zero mutants are skipped" 0 "no mutable code in nunchi.consts" base 80
SHIM_ZERO="nunchi.consts* nunchi.enums*" \
  case_ "...and the run ends with the summary line" 0 "no mutable code changed" base 80
git checkout -q full

SHIM_ZERO="nunchi.logic*" \
  case_ "zero mutants in a module with a function fails" 1 "zero mutants in nunchi.logic but it contains logic" base 80

SHIM_ZERO="nunchi.consts*" SHIM_RESULTS="$(results 9 1 0)" \
  case_ "one zero-mutant module is skipped, the rest at 90% pass" 0 "no mutable code in nunchi.consts" base 80

SHIM_ZERO="nunchi.consts*" SHIM_RESULTS="$(results 7 3 0)" \
  case_ "one zero-mutant module is skipped, the rest at 70% fail" 1 "7 of 10 mutants killed (70.0%)" base 80

SHIM_RESULTS="$(results 7 3 0)" \
  case_ "7 of 10 killed fails at 80%" 1 "7 of 10 mutants killed (70.0%)" base 80

SHIM_RESULTS="$(results 9 1 0)" \
  case_ "9 of 10 killed passes at 80%" 0 "9 of 10 mutants killed (90.0%)" base 80

SHIM_RESULTS="$(results 0 0 5)" \
  case_ "mutants generated but none checked fails" 1 "no mutants were checked" base 80

SHIM_RUN_RC=1 SHIM_RUN_OUT='RuntimeError: tests failed on a clean tree' \
  case_ "any other mutmut failure still fails" 1 "tests failed on a clean tree" base 80

git tag -f unchanged HEAD >/dev/null
SHIM_RUN_RC=1 SHIM_RUN_OUT='must not run' \
  case_ "no changed module passes without running mutmut" 0 "no mutable code changed" unchanged 80

# Bypass: do_not_mutate in pyproject plus a logic change used to print "no mutable code changed".
newrepo "$tmp/bypass-dnm"
printf 'def f():\n    return 1\n' >src/nunchi/logic.py
printf '[tool.mutmut]\nsource_paths = ["src/nunchi/"]\ndo_not_mutate = ["src/nunchi/logic.py"]\n' >pyproject.toml
git add -A
commit -m bypass
SHIM_ZERO="nunchi.logic*" \
  case_ "do_not_mutate added with a logic change fails" 1 "\[tool.mutmut\] do_not_mutate changed" base 80

newrepo "$tmp/bypass-cfg"
printf 'def f():\n    return 1\n' >src/nunchi/logic.py
printf '[tool.mutmut]\nsource_paths = ["src/other/"]\n' >pyproject.toml
git add -A
commit -m bypass
SHIM_RESULTS="$(results 9 1 0)" \
  case_ "any changed [tool.mutmut] key fails" 1 "\[tool.mutmut\] source_paths changed" base 80

# Bypass: a pragma on a changed line
newrepo "$tmp/bypass-pragma"
printf 'def f():\n    return 1  # pragma: no mutate\n' >src/nunchi/logic.py
git add -A
commit -m bypass
SHIM_ZERO="nunchi.logic*" \
  case_ "an added pragma: no mutate fails and names the line" 1 "src/nunchi/logic.py:2 adds a 'pragma: no mutate'" base 80

# Bypass: a renamed module was dropped by --diff-filter=AM
newrepo "$tmp/bypass-rename"
printf 'def f():\n    return 1\n' >src/nunchi/old.py
git add -A
commit -m old
git tag base2
git mv src/nunchi/old.py src/nunchi/renamed.py
printf 'def f():\n    return 2\n' >src/nunchi/renamed.py
git add -A
commit -m rename
SHIM_ZERO="nunchi.renamed*" \
  case_ "a renamed module with logic and zero mutants fails" 1 "zero mutants in nunchi.renamed but it contains logic" base2 80
SHIM_RESULTS="$(results 7 3 0)" \
  case_ "a renamed module is mutated and judged by its ratio" 1 "7 of 10 mutants killed (70.0%)" base2 80

# Bypass: __init__.py was excluded
newrepo "$tmp/bypass-init"
mkdir src/nunchi/pkg
printf 'def f():\n    return 1\n' >src/nunchi/pkg/__init__.py
git add -A
commit -m init
SHIM_ZERO="nunchi.pkg.x*" \
  case_ "logic in __init__.py with zero mutants fails" 1 "zero mutants in nunchi.pkg but it contains logic" base 80
SHIM_RESULTS="$(results 7 3 0)" \
  case_ "__init__.py with mutants is judged by its ratio" 1 "7 of 10 mutants killed (70.0%)" base 80
printf 'from nunchi.pkg import consts as consts\n__all__ = ["consts"]\n' >src/nunchi/pkg/__init__.py
git add -A
commit -m init-constants
SHIM_ZERO="nunchi.pkg.x*" \
  case_ "__init__.py of imports and constants is skipped" 0 "no mutable code in nunchi.pkg" base 80

# Pragma rule: mirrors mutmut (a comment with `# pragma:` and `no mutate`), any spacing or case
for text in 'x = 1  # pragma: no mutate' 'x = 1  # pragma:  no mutate' 'x = 1  # pragma:no mutate' \
  "$(printf 'x = 1  # pragma:\tno mutate')" 'x = 1  # PRAGMA: NO MUTATE' 'x = 1  #pragma: no  mutate' \
  'x = 1  # pragma: no mutate block'; do
  "$PY" "$here/mutation-guard.py" is-pragma "$text" || {
    echo "FAIL: pragma rule missed: $text" >&2
    exit 1
  }
done
for text in 'x = 1' 'x = 1  # pragma: no cover' 'x = 1  # no mutation here' 'pragma: no mutate'; do
  if "$PY" "$here/mutation-guard.py" is-pragma "$text"; then
    echo "FAIL: pragma rule flagged: $text" >&2
    exit 1
  fi
done
echo "ok: pragma rule matches mutmut with any spacing and case"

newrepo "$tmp/bypass-pragma2"
printf 'def f():\n    return 1  # pragma:  no mutate\n' >src/nunchi/logic.py
git add -A
commit -m bypass
SHIM_ZERO="nunchi.logic*" \
  case_ "a double-space pragma fails and names the line" 1 "src/nunchi/logic.py:2 adds a 'pragma: no mutate'" base 80

# AST rule: what counts as logic
newrepo "$tmp/ast"
for src in 'import os' 'A = (1, -2, "x")' 'class C:\n    X = 1\n    class D:\n        Y = 2' \
  'from enum import auto, StrEnum\n\n\nclass E(StrEnum):\n    A = auto()' \
  'from typing import TYPE_CHECKING\nif TYPE_CHECKING:\n    from a import B\n    import c' \
  'import typing\nif typing.TYPE_CHECKING:\n    from a import B' '__all__ = ["a", "b"]'; do
  printf '%b\n' "$src" >m.py
  "$PY" "$here/mutation-guard.py" logic m.py || {
    echo "FAIL: AST rule called constants logic: $src" >&2
    exit 1
  }
done
for src in 'def f(): pass' 'class C:\n    def m(self): pass' 'X = lambda: 1' 'if True:\n    X = 1' \
  'if TYPE_CHECKING:\n    X = f()' 'if TYPE_CHECKING:\n    import a\nelse:\n    a = None' \
  'if TYPE_CHECKING:\n    import a\n    X = 1' 'X = f()' 'for i in []:\n    pass' 'try:\n    import x\nexcept ImportError:\n    x = None' 'with a:\n    pass'; do
  printf '%b\n' "$src" >m.py
  "$PY" "$here/mutation-guard.py" logic m.py || continue
  echo "FAIL: AST rule called logic constants: $src" >&2
  exit 1
done
echo "ok: AST rule separates constants from logic"

echo "mutation-gate self-test ok"
