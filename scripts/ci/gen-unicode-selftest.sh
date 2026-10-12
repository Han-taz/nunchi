#!/usr/bin/env bash
# Prove the Unicode class check runs offline, catches a stale table, and refuses
# an upstream file whose sha256 is not the pinned one.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
gen="$root/scripts/gen-unicode-ignorables.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Any attempt to reach the network goes to a closed port and fails the run.
offline() {
  env HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 \
    NO_PROXY= python3 -I "$@"
}

expect_fail() { # NAME PATTERN CMD...
  local name="$1" pattern="$2" rc=0
  shift 2
  "$@" >"$tmp/out.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] || ! grep -q -- "$pattern" "$tmp/out.log"; then
    echo "FAIL: $name (exit $rc, wanted failure matching '$pattern')" >&2
    cat "$tmp/out.log" >&2
    exit 1
  fi
  echo "ok: $name"
}

offline "$gen" --check "$root/db/schema.sql"
echo "ok: db/schema.sql matches the vendored table with the network unreachable"

# Dropping one range from the table must make the schema block stale.
grep -v $'^Cc\t0000\t001F$' "$root/scripts/data/unicode/ignorable-ranges.tsv" >"$tmp/short.tsv"
cmp -s "$tmp/short.tsv" "$root/scripts/data/unicode/ignorable-ranges.tsv" &&
  { echo "FAIL: the Cc C0 row was not found in the table" >&2; exit 1; }
expect_fail "a table missing the C0 controls makes the check fail" "stale" \
  offline "$gen" --table "$tmp/short.tsv" --check "$root/db/schema.sql"

# A schema block edited by hand must fail too.
sed 's/\\u00ad/\\u00ae/' "$root/db/schema.sql" >"$tmp/schema.sql"
cmp -s "$tmp/schema.sql" "$root/db/schema.sql" &&
  { echo "FAIL: the schema has no \\u00ad to tamper with" >&2; exit 1; }
expect_fail "a hand-edited schema block makes the check fail" "stale" \
  offline "$gen" --check "$tmp/schema.sql"

# An upstream file that is not the pinned one is refused before it is parsed.
mkdir "$tmp/ucd"
printf '0000;<control>;Cc;0;BN;;;;;N;NULL;;;;\n' >"$tmp/ucd/UnicodeData.txt"
printf '' >"$tmp/ucd/DerivedCoreProperties.txt"
expect_fail "an unpinned UnicodeData.txt is refused" "sha256 differs" \
  offline "$gen" --verify-upstream --ucd-dir "$tmp/ucd"
expect_fail "--refresh refuses it too" "sha256 differs" \
  offline "$gen" --refresh --table "$tmp/refreshed.tsv" --ucd-dir "$tmp/ucd"
[ ! -e "$tmp/refreshed.tsv" ] || { echo "FAIL: --refresh wrote a table from an unpinned file" >&2; exit 1; }
echo "gen-unicode self-test ok"
