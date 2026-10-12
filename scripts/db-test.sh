#!/usr/bin/env bash
# Apply the schema to a fresh database and run db/tests/smoke_test.sql.
#
# usage: scripts/db-test.sh --url POSTGRES_URL [--profile current|vulnerable] [--results FILE]
#
# The URL must point at a Postgres 16 server and a role that can CREATE DATABASE
# and CREATE ROLE (the superuser of a throwaway server). Every run creates and
# drops its own database, so two runs never share state.
#
# Each test prints one line that starts with its id (T1, X3a, F11, N8a, A10a, ...). The file
# db/tests/expectations.tsv is the registry: a registered id that prints
# nothing, an unregistered id that prints something, or an id whose outcome
# differs from the registry makes the script exit nonzero.
#
#   current     schema = db/schema.sql. Every registered test must PASS.
#   vulnerable  schema = the v1.0 fixture plus the grant shim. Each test must
#               behave as its "on_vulnerable" column says (mutation gate).
#
# F11 times a 100k-row count(*). The limit is 200 ms locally and 1000 ms when CI is
# set (shared runners are noisy). NUNCHI_F11_LIMIT_MS overrides both.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tests_dir="$repo_root/db/tests"
registry="$tests_dir/expectations.tsv"

url=""
profile="current"
results_out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --url) url="${2:?--url needs a value}"; shift 2 ;;
    --profile) profile="${2:?--profile needs a value}"; shift 2 ;;
    --results) results_out="${2:?--results needs a value}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$url" ] || { echo "--url is required" >&2; exit 2; }

case "$profile" in
  current) schema="$repo_root/db/schema.sql"; shim="" ;;
  vulnerable)
    schema="$tests_dir/fixtures/schema_v1_0_vulnerable.sql"
    shim="$tests_dir/fixtures/vulnerable_grants_shim.sql" ;;
  *) echo "unknown profile: $profile" >&2; exit 2 ;;
esac

# Swap the database name in the URL, keeping credentials and query string.
base=${url%%\?*}
query=${url#"$base"}
db_name="nunchi_t_$$_$(date +%s)"
test_url="${base%/*}/$db_name$query"

f11_limit_ms=${NUNCHI_F11_LIMIT_MS:-$([ -n "${CI:-}" ] && echo 1000 || echo 200)}

work=$(mktemp -d)
[ -z "$results_out" ] || : >"$results_out"
cleanup() {
  psql -X -q "$url" -c "DROP DATABASE IF EXISTS $db_name WITH (FORCE)" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

psql -X -q -v ON_ERROR_STOP=1 "$url" -c "CREATE DATABASE $db_name" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 "$test_url" -f "$schema" >/dev/null
if [ -n "$shim" ]; then
  psql -X -q -v ON_ERROR_STOP=1 "$test_url" -f "$shim" >/dev/null
fi

# stdout carries SELECT results and stderr carries RAISE NOTICE output.
# Separate files keep psql's buffered streams from interleaving mid-line.
psql_status=0
psql -X -q -t -v ON_ERROR_STOP=1 -v f11_limit_ms="$f11_limit_ms" "$test_url" -f "$tests_dir/smoke_test.sql" \
  >"$work/out.txt" 2>"$work/err.txt" || psql_status=$?
cat "$work/out.txt" "$work/err.txt"
if [ "$psql_status" -ne 0 ]; then
  echo "db-test: psql exited with status $psql_status" >&2
  exit 1
fi

# Normalise to "<id> <rest>" lines.
sed -E -e 's/^psql:[^ ]+ NOTICE:  //' -e 's/^[[:space:]]+//' "$work/out.txt" "$work/err.txt" \
  | grep -E '^(T[0-9]+[a-z]?|[XFNA][0-9]+[a-z]?) ' >"$work/lines.txt" || true

awk -F '\t' -v profile="$profile" -v results="$results_out" '
  FNR == NR {
    if ($0 ~ /^#/ || $0 ~ /^[[:space:]]*$/) next
    if (NF < 3) { printf "registry line %d has fewer than 3 columns\n", FNR; bad = 1; next }
    id = $1; marker[id] = $2; vuln[id] = $3; note[id] = $4; order[++n] = id
    if (id !~ /^T/ && $3 == "pass" && $4 == "") {
      printf "registry: %s passes on the vulnerable schema but has no note explaining why\n", id; bad = 1
    }
    next
  }
  {
    id = substr($0, 1, index($0, " ") - 1)
    if (id in seen) { printf "duplicate output for %s\n", id; bad = 1; next }
    seen[id] = $0
  }
  END {
    failures = 0
    for (id in seen) if (!(id in marker)) {
      printf "UNREGISTERED %s: add it to db/tests/expectations.tsv\n", id; failures++
    }
    for (i = 1; i <= n; i++) {
      id = order[i]
      if (!(id in seen)) { status = "MISSING" }
      else if (seen[id] ~ / FAIL/ || index(seen[id], marker[id]) == 0) { status = "FAIL" }
      else { status = "PASS" }
      want = (profile == "current") ? "pass" : vuln[id]
      ok = (status == "PASS" && want == "pass") || (status == "FAIL" && want == "fail")
      if (results != "") printf "%s\t%s\n", id, status >> results
      if (!ok) {
        printf "UNEXPECTED %s: got %s, wanted %s\n  line: %s\n", id, status, want, (id in seen ? seen[id] : "(no output)")
        failures++
      }
    }
    if (bad) failures++
    printf "db-test[%s]: %d tests registered, %d unexpected\n", profile, n, failures
    exit (failures > 0)
  }
' "$registry" "$work/lines.txt"
