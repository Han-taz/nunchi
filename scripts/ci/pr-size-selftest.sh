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

# case_ NAME EXPECTED_EXIT SETUP_FUNCTION [EXPECTED_OUTPUT_PATTERN]
case_() {
  local name="$1" want="$2" setup="$3" pattern="${4:-}"
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
echo "pr-size self-test ok"
