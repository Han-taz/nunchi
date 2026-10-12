#!/usr/bin/env bash
# Fail when a change weakens db/tests/expectations.tsv.
#
# usage: scripts/ci/expectations-guard.sh BASE HEAD
#
# A registered test may disappear only when the same change also removes the test
# itself (no db/tests/*.sql line prints its id any more). A row whose on_vulnerable
# is `fail` in BASE may not become anything else in HEAD. Reads git objects only.
set -euo pipefail

base="${1:?base ref required}"
head="${2:?head ref required}"
registry=db/tests/expectations.tsv

rows() {
  git show "$1:$registry" 2>/dev/null | awk -F '\t' '$0 !~ /^#/ && $0 !~ /^[[:space:]]*$/ { print $1 "\t" $3 }' || true
}

base_rows=$(rows "$base")
head_rows=$(rows "$head")
fail=0

while IFS=$'\t' read -r id was; do
  [ -n "$id" ] || continue
  now=$(awk -F '\t' -v id="$id" '$1 == id { print $2 }' <<<"$head_rows")
  if [ -z "$now" ]; then
    if git grep -qF "'$id " "$head" -- 'db/tests/*.sql'; then
      echo "::error::$id was deleted from $registry but its test still exists"
      fail=1
    else
      echo "removed with its test: $id"
    fi
  elif [ "$was" = fail ] && [ "$now" != fail ]; then
    echo "::error::$id on_vulnerable changed from fail to $now"
    fail=1
  fi
done <<<"$base_rows"

added=$(comm -13 <(cut -f1 <<<"$base_rows" | sort) <(cut -f1 <<<"$head_rows" | sort) | tr '\n' ' ')
echo "added: ${added:-none}"
[ "$fail" -eq 0 ] && echo "expectations registry not weakened"
exit "$fail"
