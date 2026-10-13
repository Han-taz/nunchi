#!/usr/bin/env bash
# Run mutmut on the modules a change touches and fail below a killed-mutant ratio.
#
# usage: scripts/ci/mutation-gate.sh [BASE_REF [MIN_PERCENT]]
#
# With a BASE_REF only src/nunchi modules changed since the merge base are mutated.
# With no arguments every module is mutated (the nightly run).
# killed = killed + timeout; the ratio ignores mutants mutmut never checked.
# A module's mutants are its results keys `<module>.<mutant name>` matched by exact module name
# (the mutant name has no dot), never by a prefix glob, so `nunchi.d` cannot borrow mutants from
# `nunchi.domain`. The killed ratio counts only those exact mutants.
# A changed module may be skipped as "no mutable code" only when it has no mutants of its own
# AND an AST check (scripts/ci/mutation-guard.py) finds no function,
# method, lambda or control flow in it, only constants and classes of constants. Zero mutants
# in a module with logic fails ("zero mutants in <module> but it contains logic"), so
# do_not_mutate or pragmas cannot turn a loud failure into a silent pass. The gate also
# fails when the PR adds `pragma: no mutate` under src/ or changes any [tool.mutmut] key.
# Renamed modules and __init__.py files are checked too. Any other mutmut failure fails, and
# the killed ratio over the modules that do have mutants still applies.
set -euo pipefail

base="${1:-}"
min="${2:-80}"
guard="$(cd "$(dirname "$0")" && pwd)/mutation-guard.py"

files=()
modules=()
if [ -n "$base" ]; then
  python3 "$guard" pragma "$base" || exit 1
  python3 "$guard" config "$base" || exit 1
  while IFS= read -r file; do
    mod=${file#src/}
    mod=${mod%.py}
    mod=${mod//\//.}
    mod=${mod%.__init__}
    files+=("$file")
    modules+=("$mod")
  done < <(git diff --name-only --diff-filter=AMR "$base...HEAD" -- 'src/nunchi/*.py' 'src/nunchi/**/*.py')
  if [ ${#modules[@]} -eq 0 ]; then
    echo "mutation-gate: no mutable code changed"
    exit 0
  fi
fi

# shellcheck disable=SC2016
awk_ratio='
  /: / {
    status = $NF
    if (status == "killed" || status == "timeout") killed++
    else if (status == "survived" || status == "suspicious" || $0 ~ /no tests/) bad++
    if (status == "survived") print "SURVIVED " $1
  }
  END {
    total = killed + bad
    if (total == 0) { print "mutation-gate: no mutants were checked"; exit 1 }
    pct = 100 * killed / total
    printf "mutation-gate: %d of %d mutants killed (%.1f%%), minimum %d%%\n", killed, total, pct, min
    exit (pct < min)
  }'

if [ -z "$base" ]; then
  uv run mutmut run
  uv run mutmut results --all true | awk -v min="$min" "$awk_ratio"
  exit
fi

run_log="$(mktemp)"
results_log="$(mktemp)"
own_log="$(mktemp)"
all_log="$(mktemp)"
trap 'rm -f "$run_log" "$results_log" "$own_log" "$all_log"' EXIT
for i in "${!modules[@]}"; do
  run_rc=0
  uv run mutmut run "${modules[$i]}.*" 2>&1 | tee "$run_log" || run_rc=$?
  if [ "$run_rc" -ne 0 ] && ! grep -q 'nothing matches' "$run_log"; then
    exit "$run_rc"
  fi
done
uv run mutmut results --all true >"$results_log"
mutable=0
for i in "${!modules[@]}"; do
  mod="${modules[$i]}"
  python3 "$guard" exact "$mod" <"$results_log" >"$own_log"
  if [ -s "$own_log" ]; then
    mutable=$((mutable + 1))
    cat "$own_log" >>"$all_log"
  elif python3 "$guard" logic "${files[$i]}"; then
    echo "mutation-gate: no mutable code in $mod"
  else
    echo "mutation-gate: zero mutants in $mod but it contains logic"
    exit 1
  fi
done
if [ "$mutable" -eq 0 ]; then
  echo "mutation-gate: no mutable code changed"
  exit 0
fi
awk -v min="$min" "$awk_ratio" "$all_log"
