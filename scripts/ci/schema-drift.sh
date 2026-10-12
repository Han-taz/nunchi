#!/usr/bin/env bash
# Fail when db/schema.sql and db/migrations/ describe different schemas.
#
# usage: scripts/ci/schema-drift.sh --url POSTGRES_URL
#
# Builds one database from schema.sql and another by running the migration
# runner, then diffs `pg_dump --schema-only` of the two. schema_migrations is
# the runner's own bookkeeping and is excluded. Needs psql and pg_dump 16 and uv.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --url) url="${2:?--url needs a value}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$url" ] || { echo "--url is required" >&2; exit 2; }

base=${url%%\?*}
query=${url#"$base"}
suffix="$$_$(date +%s)"
from_schema="nunchi_drift_schema_$suffix"
from_migrations="nunchi_drift_migr_$suffix"
db_url() { echo "${base%/*}/$1$query"; }

work=$(mktemp -d)
cleanup() {
  for name in "$from_schema" "$from_migrations"; do
    psql -X -q "$url" -c "DROP DATABASE IF EXISTS $name WITH (FORCE)" >/dev/null 2>&1 || true
  done
  rm -rf "$work"
}
trap cleanup EXIT

for name in "$from_schema" "$from_migrations"; do
  psql -X -q -v ON_ERROR_STOP=1 "$url" -c "CREATE DATABASE $name" >/dev/null
done
psql -X -q -v ON_ERROR_STOP=1 "$(db_url "$from_schema")" <"$repo_root/db/schema.sql" >/dev/null
(
  cd "$repo_root"
  NUNCHI_DATABASE_URL="$(db_url "$from_migrations")" uv run --locked python -W error -m nunchi.migrate
)

# pg_dump 16.10+ prints a random \restrict token on every run; drop those lines.
dump() {
  pg_dump --schema-only --no-owner --exclude-table=schema_migrations "$(db_url "$1")" |
    grep -v -E '^\\(un)?restrict '
}
dump "$from_schema" >"$work/schema.dump"
dump "$from_migrations" >"$work/migrations.dump"

if ! diff -u "$work/schema.dump" "$work/migrations.dump"; then
  echo "schema-drift: db/schema.sql and db/migrations/ disagree. Every schema.sql change needs a new migration." >&2
  exit 1
fi
echo "schema-drift: schema.sql and the migrations produce the same schema ($(wc -l <"$work/schema.dump") dump lines)"
