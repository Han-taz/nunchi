#!/usr/bin/env bash
# Prove pr-size.sh enforces the limit and cannot be dodged.
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/pr-size.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git tag base
root=$(git rev-parse base)

# case_ NAME EXPECTED_EXIT SETUP_FUNCTION [EXPECTED_OUTPUT_PATTERN]
case_() {
  local name="$1" want="$2" setup="$3" pattern="${4:-}"
  git tag -f base "$root" >/dev/null
  git checkout -q -B "t" base
  git clean -fdxq
  "$setup"
  git add -A
  git -c user.name=t -c user.email=t@t commit -q -m "t"
  local rc=0
  "$script" base t 800 >out.log 2>&1 || rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $name exited $rc, expected $want" >&2
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

lines_800() { seq 1 800 > f.txt; }
lines_801() { seq 1 801 > f.txt; }
gitattr_hides_sql() {
  echo '* -diff' > .gitattributes
  seq 1 5000 | sed 's/.*/select &;/' > big.sql
}
binary_attr_hides_sql() {
  echo '*.sql binary' > .gitattributes
  seq 1 5000 | sed 's/.*/select &;/' > big.sql
}
nul_sql() { { printf '\0'; seq 1 5000; } > big.sql; }
research_sql() {
  mkdir -p docs/research
  seq 1 5000 | sed 's/.*/select &;/' > docs/research/exp.sql
}
research_md() {
  mkdir -p docs/research
  seq 1 5000 > docs/research/notes.md
}
png() { { printf '\211PNG\0\0'; seq 1 5000; } > logo.png; }
lock_without_manifest() {
  mkdir -p .github/tools
  seq 1 5000 > .github/tools/package-lock.json
}
lock_with_manifest() {
  mkdir -p .github/tools
  seq 1 5000 > .github/tools/package-lock.json
  echo '{}' > .github/tools/package.json
}
uv_lock_without_manifest() { seq 1 5000 > uv.lock; }
uv_lock_with_manifest() {
  seq 1 5000 > uv.lock
  echo '[project]' > pyproject.toml
}
baseline_new() {
  mkdir -p db/migrations
  seq 1 5000 > db/migrations/0001_baseline.sql
}
baseline_edited_with_schema() {
  mkdir -p db/migrations
  seq 1 3 > db/migrations/0001_baseline.sql
  git add -A
  git -c user.name=t -c user.email=t@t commit -q -m seed
  git tag -f base >/dev/null
  seq 1 5000 > db/migrations/0001_baseline.sql
  echo 'create table t();' > db/schema.sql
}
other_migration_with_schema() {
  mkdir -p db/migrations
  seq 1 5000 > db/migrations/0002_big.sql
  echo 'create table t();' > db/schema.sql
}

cr_only_padding() { head -c 600000 /dev/zero | tr '\0' '\r' > f.txt; }
single_line_padding() { head -c 600000 /dev/zero | tr '\0' 'a' > f.txt; }
many_files_total_bytes() {
  for i in 1 2 3 4; do head -c 400000 /dev/zero | tr '\0' 'a' > "f$i.txt"; done
}
small_files_total_ok() {
  for i in 1 2 3 4; do head -c 200000 /dev/zero | tr '\0' 'a' > "f$i.txt"; done
}
chained_md() {
  mkdir -p docs/research
  seq 1 5000 | sed 's/.*/select &;/' > docs/research/exp.sql.md
}
chained_py_md() {
  mkdir -p docs/reviews
  seq 1 5000 > docs/reviews/run.py.md
}
numeric_dotted_md() {
  mkdir -p docs/research/sources
  seq 1 5000 > docs/research/sources/gatemem-2606.18829.md
}
huge_md() {
  mkdir -p docs/research
  head -c 600000 /dev/zero | tr '\0' 'a' > docs/research/huge.md
}
binary_md() {
  mkdir -p docs/research
  { printf '\0'; head -c 100000 /dev/zero; } > docs/research/payload.md
}
late_nul_md() {
  mkdir -p docs/research
  { seq 1 5000; printf '\0'; } > docs/research/late.md
}
invalid_utf8_md() {
  mkdir -p docs/research
  { seq 1 5000; printf '\377\376\n'; } > docs/research/latin.md
}
binary_md_big() {
  mkdir -p docs/research
  for i in 1 2 3 4 5 6; do { printf '\0'; head -c 500000 /dev/zero; } > "docs/research/p$i.md"; done
}
ten_big_md() {
  mkdir -p docs/research
  for i in 1 2 3 4 5 6 7 8 9 10; do head -c 500000 /dev/zero | tr '\0' 'a' | fold -w 100 > "docs/research/n$i.md"; done
}
two_big_md_ok() {
  mkdir -p docs/research
  for i in 1 2; do head -c 400000 /dev/zero | tr '\0' 'a' | fold -w 100 > "docs/research/n$i.md"; done
}
double_dot_md() {
  mkdir -p docs/research
  seq 1 5000 > docs/research/x.sql..md
}
hyphen_ext_md() {
  mkdir -p docs/research
  seq 1 5000 > docs/research/x.s-ql.md
}
digit_ext_md() {
  mkdir -p docs/research
  seq 1 5000 > docs/research/x.1sql.md
}
# text of roughly N bytes, many short lines (a lock file looks like this)
lock_text() { head -c "$1" /dev/zero | tr '\0' 'a' | fold -w 60; }
uv_lock_53mb_scaled() {
  lock_text 3145728 > uv.lock
  echo ' ' >> pyproject.toml
}
uv_lock_binary() {
  { printf '\0'; head -c 300000 /dev/zero; } > uv.lock
  echo ' ' >> pyproject.toml
}
uv_lock_invalid_utf8() {
  { lock_text 100000; printf '\377\376\n'; } > uv.lock
  echo ' ' >> pyproject.toml
}
npm_lock_40mb_scaled() {
  mkdir -p .github/tools
  lock_text 3145728 > .github/tools/package-lock.json
  echo ' ' >> .github/tools/package.json
}
requirements_5mb_scaled() {
  mkdir -p .github/tools
  lock_text 3145728 > .github/tools/requirements.txt
  echo ' ' >> .github/tools/requirements.in
}
three_locks_over_lock_total() {
  mkdir -p .github/tools
  lock_text 1572864 > uv.lock
  lock_text 1572864 > .github/tools/package-lock.json
  lock_text 1572864 > .github/tools/requirements.txt
  echo ' ' >> pyproject.toml
  echo ' ' >> .github/tools/package.json
  echo ' ' >> .github/tools/requirements.in
}
uv_lock_300kb_bump() {
  lock_text 307200 > uv.lock
  echo '[project]' > pyproject.toml
}
lock_bump_beside_900kb_files() {
  lock_text 1572864 > uv.lock
  echo ' ' >> pyproject.toml
  head -c 400000 /dev/zero | tr '\0' 'a' > a.txt
  head -c 400000 /dev/zero | tr '\0' 'a' > b.txt
}
big_png() { { printf '\211PNG\0\0'; head -c 102400 /dev/zero; } > big.png; }
big_png_ok() { { printf '\211PNG\0\0'; head -c 30000 /dev/zero; } > mid.png; }
many_big_pngs() {
  for i in $(seq 1 20); do { printf '\211PNG\0\0'; head -c 102400 /dev/zero; } > "p$i.png"; done
}

case_ "800 lines" 0 lines_800
case_ "801 lines" 1 lines_801 "Split the PR"
case_ ".gitattributes '* -diff' + 5000-line .sql" 1 gitattr_hides_sql "Split the PR"
case_ ".gitattributes '*.sql binary' + 5000-line .sql" 1 binary_attr_hides_sql "Split the PR"
case_ "genuinely binary .sql" 1 nul_sql "binary file not on the allowlist"
case_ "5000-line .sql under docs/research" 1 research_sql "Split the PR"
case_ "5000-line .md under docs/research" 0 research_md
case_ "binary png" 0 png
case_ "5000-line lock file without its manifest" 1 lock_without_manifest "Split the PR"
case_ "5000-line lock file with its manifest" 0 lock_with_manifest
case_ "5000-line uv.lock without pyproject.toml" 1 uv_lock_without_manifest "Split the PR"
case_ "5000-line uv.lock with pyproject.toml" 0 uv_lock_with_manifest
case_ "5000-line 0001_baseline.sql newly added" 1 baseline_new "Split the PR"
case_ "5000-line 0001_baseline.sql edit with schema.sql" 1 baseline_edited_with_schema "Split the PR"
case_ "5000-line 0002 migration with schema.sql" 1 other_migration_with_schema "Split the PR"
case_ "CR-only 600 KB file (one line)" 1 cr_only_padding "file cap"
case_ "single 600 KB line" 1 single_line_padding "file cap"
case_ "four 400 KB files exceed the total cap" 1 many_files_total_bytes "total cap"
case_ "four 200 KB files fit" 0 small_files_total_ok
case_ "5000-line .sql.md under docs/research" 1 chained_md "Split the PR"
case_ "5000-line .py.md under docs/reviews" 1 chained_py_md "Split the PR"
case_ "5000-line numeric-dotted .md stays exempt" 0 numeric_dotted_md
case_ "600 KB .md exceeds the file cap" 1 huge_md "file cap"
case_ "100 KB png counts 550 lines" 0 big_png "lines after exemptions: 550"
case_ "30 KB png counts 150 lines" 0 big_png_ok "lines after exemptions: 150"
case_ "twenty 100 KB pngs exceed the limit" 1 many_big_pngs "Split the PR"
case_ "NUL-byte file renamed .md under docs/research" 1 binary_md "binary file not on the allowlist"
case_ "NUL after 8000 bytes in a .md (git sees text)" 1 late_nul_md "Split the PR"
case_ "invalid UTF-8 .md with 5000 lines" 1 invalid_utf8_md "Split the PR"
case_ "six 500 KB binary .md files" 1 binary_md_big "total cap"
case_ "ten 500 KB .md files exceed the total cap" 1 ten_big_md "total cap"
case_ "two 400 KB .md files fit the total cap" 0 two_big_md_ok
case_ "5000-line x.sql..md" 1 double_dot_md "Split the PR"
case_ "5000-line x.s-ql.md" 1 hyphen_ext_md "Split the PR"
case_ "5000-line x.1sql.md" 1 digit_ext_md "Split the PR"
case_ "3 MiB uv.lock with pyproject.toml (file cap)" 1 uv_lock_53mb_scaled "lock file cap"
case_ "binary uv.lock with pyproject.toml" 1 uv_lock_binary "not UTF-8 text"
case_ "invalid UTF-8 uv.lock with pyproject.toml" 1 uv_lock_invalid_utf8 "not UTF-8 text"
case_ "3 MiB package-lock.json with package.json" 1 npm_lock_40mb_scaled "lock file cap"
case_ "3 MiB requirements.txt with requirements.in" 1 requirements_5mb_scaled "lock file cap"
case_ "three 1.5 MiB lock files exceed the lock total" 1 three_locks_over_lock_total "lock file total cap"
case_ "300 KB uv.lock bump with pyproject.toml" 0 uv_lock_300kb_bump "lines after exemptions: 1"
case_ "1.5 MiB uv.lock beside two 400 KB files" 0 lock_bump_beside_900kb_files
echo "pr-size self-test ok"
