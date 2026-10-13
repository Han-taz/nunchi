#!/usr/bin/env bash
# Fail when a change weakens db/tests/expectations.tsv.
#
# usage: scripts/ci/expectations-guard.sh BASE HEAD
#
# A registered test may disappear only when the same change also removes the test
# itself: no non-comment line of a db/tests/*.sql file opens a string literal whose first
# token is exactly its id (the way db-test.sh reads a test's output line). A row whose
# on_vulnerable is `fail` in BASE may not become anything else in HEAD. HEAD's registry
# must exist, name only well-formed ids (T1, X3a, F11 ...), and list each id once.
# Reads git objects only.
set -euo pipefail

base="${1:?base ref required}"
head="${2:?head ref required}"
registry=db/tests/expectations.tsv

rows() {
  git show "$1:$registry" 2>/dev/null | awk -F '\t' '$0 !~ /^#/ && $0 !~ /^[[:space:]]*$/ { print $1 "\t" $3 }' || true
}

id_shape='^(T[0-9]+[a-z]?|[XFNASP][0-9]+[a-z]?)$'
fail=0

git cat-file -e "$head:$registry" 2>/dev/null || { echo "::error::$registry is missing in the head"; exit 1; }
base_rows=$(rows "$base")
head_rows=$(rows "$head")

while IFS=$'\t' read -r id _; do
  [ -n "$id" ] || continue
  if ! [[ "$id" =~ $id_shape ]]; then
    echo "::error::$registry has a malformed id: '$id'"
    fail=1
  fi
done <<<"$head_rows"
dups=$(cut -f1 <<<"$head_rows" | sort | uniq -d | tr '\n' ' ')
if [ -n "$dups" ]; then
  echo "::error::$registry lists an id more than once: $dups"
  fail=1
fi

# Ids that some db/tests/*.sql file still prints: the first token of a string literal.
emitted=$(
  git ls-tree --name-only -z "$head" db/tests/ | tr '\0' '\n' | grep '\.sql$' |
    while IFS= read -r file; do git show "$head:$file"; done |
    awk -v q="'" '
      /^[[:space:]]*--/ { next }
      {
        line = $0
        while (match(line, q "(T[0-9]+[a-z]?|[XFNASP][0-9]+[a-z]?)([^A-Za-z0-9_]|$)")) {
          token = substr(line, RSTART + 1, RLENGTH - 1)
          sub(/[^A-Za-z0-9_]$/, "", token)
          print token
          line = substr(line, RSTART + RLENGTH)
        }
      }' | sort -u || true
)

while IFS=$'\t' read -r id was; do
  [ -n "$id" ] || continue
  now=$(awk -F '\t' -v id="$id" '$1 == id { print $2 }' <<<"$head_rows")
  if [ -z "$now" ]; then
    if grep -qxF -- "$id" <<<"$emitted"; then
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
