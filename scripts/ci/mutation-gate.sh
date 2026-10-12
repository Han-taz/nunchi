#!/usr/bin/env bash
# Run mutmut on the modules a change touches and fail below a killed-mutant ratio.
#
# usage: scripts/ci/mutation-gate.sh [BASE_REF [MIN_PERCENT]]
#
# With a BASE_REF only src/nunchi modules changed since the merge base are mutated.
# With no arguments every module is mutated (the nightly run).
# killed = killed + timeout; the ratio ignores mutants mutmut never checked.
set -euo pipefail

base="${1:-}"
min="${2:-80}"

patterns=()
if [ -n "$base" ]; then
  while IFS= read -r file; do
    mod=${file#src/}
    mod=${mod%.py}
    mod=${mod//\//.}
    patterns+=("${mod}*")
  done < <(git diff --name-only --diff-filter=AM "$base...HEAD" -- 'src/nunchi/*.py' 'src/nunchi/**/*.py' |
    grep -v '/__init__\.py$' || true)
  if [ ${#patterns[@]} -eq 0 ]; then
    echo "mutation-gate: no mutable module changed"
    exit 0
  fi
fi

uv run mutmut run ${patterns[@]+"${patterns[@]}"}
uv run mutmut results --all true | awk -v min="$min" '
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
