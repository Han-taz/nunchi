#!/usr/bin/env bash
# Prove expectations-guard.sh and gate-files-report.sh on a scratch repository.
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
out="$(mktemp)"
trap 'rm -rf "$tmp" "$out"' EXIT
cd "$tmp"
git init -q
mkdir -p db/tests scripts/ci
printf '# header\nT1\t= 0\tpass\nX1a\tok\tfail\nX1b\tok\tfail\n' >db/tests/expectations.tsv
printf "SELECT 'T1 = 0';\nSELECT 'X1a ok';\nSELECT 'X1b ok';\n" >db/tests/smoke_test.sql
echo hi >README.md
git add -A
git -c user.name=t -c user.email=t@t commit -q -m base
root_sha=$(git rev-parse HEAD)

# case_ NAME EXPECTED_EXIT SCRIPT SETUP_FUNCTION PATTERN
case_() {
  local name="$1" want="$2" script="$3" setup="$4" pattern="$5" rc=0
  git checkout -q -B t "$root_sha"
  "$setup"
  git add -A
  git -c user.name=t -c user.email=t@t commit -q -m t
  "$root/$script" "$root_sha" t >"$out" 2>&1 || rc=$?
  if [ "$rc" -ne "$want" ] || ! grep -q -- "$pattern" "$out"; then
    echo "FAIL: $name exited $rc, expected $want with '$pattern':" >&2
    cat "$out" >&2
    exit 1
  fi
  echo "ok: $name -> exit $want"
}

drop_row_keep_test() { sed -i.bak '/^X1a/d' db/tests/expectations.tsv && rm db/tests/expectations.tsv.bak; }
drop_row_and_test() {
  sed -i.bak '/^X1a/d' db/tests/expectations.tsv && rm db/tests/expectations.tsv.bak
  sed -i.bak "/'X1a /d" db/tests/smoke_test.sql && rm db/tests/smoke_test.sql.bak
}
flip_to_pass() { sed -i.bak 's/^X1b\tok\tfail/X1b\tok\tpass/' db/tests/expectations.tsv && rm db/tests/expectations.tsv.bak; }
add_row() { printf 'T2\t= 1\tpass\n' >>db/tests/expectations.tsv; echo "SELECT 'T2 = 1';" >>db/tests/smoke_test.sql; }
touch_readme() { echo more >>README.md; }
touch_gate_files() { echo x >scripts/ci/pr-size.sh; echo x >db/tests/expectations.tsv.new; echo x >>.sqlfluff; }

case_ "row deleted, test kept" 1 expectations-guard.sh drop_row_keep_test "X1a was deleted from db/tests/expectations.tsv but its test still exists"
case_ "row and test deleted" 0 expectations-guard.sh drop_row_and_test "removed with its test: X1a"
case_ "must-fail flipped to pass" 1 expectations-guard.sh flip_to_pass "X1b on_vulnerable changed from fail to pass"
case_ "row added" 0 expectations-guard.sh add_row "added: T2"
case_ "no gate file touched" 0 gate-files-report.sh touch_readme "gate files changed: none"
case_ "gate files touched" 0 gate-files-report.sh touch_gate_files "- \`scripts/ci/pr-size.sh\`"
