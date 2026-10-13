#!/usr/bin/env bash
# Prove migrations-immutable.sh catches every way of rewriting an applied migration.
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/migrations-immutable.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q
mkdir -p db/migrations
printf 'SELECT 1;\n' > db/migrations/0001_a.sql
printf 'SELECT 2;\n' > db/migrations/0002_b.sql

sums() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
seal() { (cd db/migrations && LC_ALL=C sums -- *.sql > SHA256SUMS); }
seal
git add -A
git -c user.name=t -c user.email=t@t commit -q -m base
git tag base

# case_ NAME EXPECTED_EXIT SETUP_FUNCTION [EXPECTED_OUTPUT_PATTERN]
case_() {
  local name="$1" want="$2" setup="$3" pattern="${4:-}"
  git checkout -q -B t base
  git clean -fdxq
  "$setup"
  git add -A
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m t
  local rc=0
  "$script" base t >out.log 2>&1 || rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $name exited $rc, expected $want" >&2
    cat out.log >&2
    exit 1
  fi
  if [ -n "$pattern" ] && ! grep -q -- "$pattern" out.log; then
    echo "FAIL: $name output lacked '$pattern':" >&2
    cat out.log >&2
    exit 1
  fi
  rm -f out.log
  echo "ok: $name -> exit $want"
}

nothing() { :; }
add_new() { printf 'SELECT 3;\n' > db/migrations/0003_c.sql; seal; }
edit_baseline_resealed() { printf 'SELECT 9;\n' > db/migrations/0001_a.sql; seal; }
edit_baseline_unsealed() { printf 'SELECT 9;\n' > db/migrations/0001_a.sql; }
delete_baseline() { rm db/migrations/0001_a.sql; seal; }
rename_baseline() { git mv db/migrations/0001_a.sql db/migrations/0001_z.sql; seal; }
add_unlisted() { printf 'SELECT 3;\n' > db/migrations/0003_c.sql; }
manifest_drops_a_line() { sed -i.bak '1d' db/migrations/SHA256SUMS && rm db/migrations/SHA256SUMS.bak; git rm -q --cached db/migrations/0001_a.sql; rm db/migrations/0001_a.sql; }
append_to_baseline() { printf 'DROP TABLE x;\n' >> db/migrations/0001_a.sql; seal; }

add_gap() { printf 'SELECT 5;\n' > db/migrations/0005_gap.sql; seal; }
add_equal_to_max() { printf 'SELECT 3;\n' > db/migrations/0002_late.sql; seal; }
add_below_max() { printf 'SELECT 3;\n' > db/migrations/0001_late.sql; seal; }
add_two_new_in_order() { printf 'SELECT 3;\n' > db/migrations/0003_c.sql; printf 'SELECT 4;\n' > db/migrations/0004_d.sql; seal; }
add_dotfile_migration() { printf 'SELECT 3;\n' > db/migrations/.0003_hidden.sql; }
add_dot_keep() { : > db/migrations/.keep; }
add_dotfile_in_subdir() { mkdir db/migrations/sub; : > db/migrations/sub/.x; }

case_ "no change" 0 nothing
case_ "new migration with its manifest line" 0 add_new
case_ "0001 edited and manifest regenerated" 1 edit_baseline_resealed "0001_a.sql is frozen: it was changed"
case_ "0001 appended to and manifest regenerated" 1 append_to_baseline "0001_a.sql is frozen"
case_ "0001 edited, manifest stale" 1 edit_baseline_unsealed "does not match the sha256"
case_ "0001 deleted" 1 delete_baseline "deleted or renamed"
case_ "0001 renamed" 1 rename_baseline "deleted or renamed"
case_ "new migration missing from the manifest" 1 add_unlisted "does not match the sha256"
case_ "0001 and its manifest line removed together" 1 manifest_drops_a_line "frozen"
case_ "new migration skipping a version" 0 add_gap
case_ "two new migrations in order" 0 add_two_new_in_order
case_ "new migration with the base's highest version" 1 add_equal_to_max "must be greater than the highest version in the base (0002)"
case_ "new migration below the base's highest version" 1 add_below_max "must be greater"
case_ "hidden dotfile migration" 1 add_dotfile_migration "is a dotfile"
case_ ".keep dotfile" 1 add_dot_keep "is a dotfile"
case_ "dotfile in a subdirectory" 1 add_dotfile_in_subdir "is a dotfile"
echo "migrations-immutable self-test ok"
