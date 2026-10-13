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
drop_row_test_id_before_tab() {
  sed -i.bak '/^X1a/d' db/tests/expectations.tsv && rm db/tests/expectations.tsv.bak
  sed -i.bak "s/'X1a ok'/'X1a'||E'\\tok'/" db/tests/smoke_test.sql && rm db/tests/smoke_test.sql.bak
}
drop_row_longer_id_remains() {
  sed -i.bak '/^X1a/d' db/tests/expectations.tsv && rm db/tests/expectations.tsv.bak
  sed -i.bak "s/'X1a ok'/'X1ab ok'/" db/tests/smoke_test.sql && rm db/tests/smoke_test.sql.bak
}
drop_row_comment_mentions_id() {
  sed -i.bak '/^X1a/d' db/tests/expectations.tsv && rm db/tests/expectations.tsv.bak
  sed -i.bak "s/^SELECT 'X1a ok';/-- SELECT 'X1a ok'; was removed/" db/tests/smoke_test.sql && rm db/tests/smoke_test.sql.bak
}
add_malformed_id() { printf 'T 2\t= 1\tpass\n' >>db/tests/expectations.tsv; }
add_id_G3n() { printf 'G3n\t= 1\tfail\nB6a\t= 1\tfail\n' >>db/tests/expectations.tsv; printf "SELECT 'G3n = 1';\nSELECT 'B6a = 1';\n" >>db/tests/smoke_test.sql; }
add_id_lower() { printf 'g3n\t= 1\tpass\n' >>db/tests/expectations.tsv; }
add_id_letter_only() { printf 'G\t= 1\tpass\n' >>db/tests/expectations.tsv; }
add_id_digit_only() { printf '3n\t= 1\tpass\n' >>db/tests/expectations.tsv; }
add_id_two_letter() { printf 'GG3n\t= 1\tpass\n' >>db/tests/expectations.tsv; }
add_id_two_suffix() { printf 'X1ab\t= 1\tpass\n' >>db/tests/expectations.tsv; }
drop_G3n_keep_test() { add_id_G3n; git add -A; git -c user.name=t -c user.email=t@t commit -q -m g; root_sha=$(git rev-parse HEAD); sed -i.bak '/^G3n/d' db/tests/expectations.tsv && rm db/tests/expectations.tsv.bak; }
add_duplicate_id() { printf 'T1\t= 0\tpass\n' >>db/tests/expectations.tsv; }
delete_registry() { git rm -q db/tests/expectations.tsv; }
touch_readme() { echo more >>README.md; }
touch_gate_files() { echo x >scripts/ci/pr-size.sh; echo x >db/tests/expectations.tsv.new; echo x >>.sqlfluff; }

case_ "row deleted, test kept" 1 expectations-guard.sh drop_row_keep_test "X1a was deleted from db/tests/expectations.tsv but its test still exists"
case_ "row and test deleted" 0 expectations-guard.sh drop_row_and_test "removed with its test: X1a"
case_ "must-fail flipped to pass" 1 expectations-guard.sh flip_to_pass "X1b on_vulnerable changed from fail to pass"
case_ "row added" 0 expectations-guard.sh add_row "added: T2"
case_ "row deleted, test id now followed by a tab" 1 expectations-guard.sh drop_row_test_id_before_tab "X1a was deleted from db/tests/expectations.tsv but its test still exists"
case_ "row deleted, only a longer id X1ab remains" 0 expectations-guard.sh drop_row_longer_id_remains "removed with its test: X1a"
case_ "row deleted, only a comment mentions the id" 0 expectations-guard.sh drop_row_comment_mentions_id "removed with its test: X1a"
case_ "malformed id in the registry" 1 expectations-guard.sh add_malformed_id "malformed id: 'T 2'"
case_ "G and B prefixed ids accepted" 0 expectations-guard.sh add_id_G3n "added: B6a G3n"
case_ "lowercase prefix g3n rejected" 1 expectations-guard.sh add_id_lower "malformed id: 'g3n'"
case_ "bare letter G rejected" 1 expectations-guard.sh add_id_letter_only "malformed id: 'G'"
case_ "digits and suffix only 3n rejected" 1 expectations-guard.sh add_id_digit_only "malformed id: '3n'"
case_ "two-letter prefix GG3n rejected" 1 expectations-guard.sh add_id_two_letter "malformed id: 'GG3n'"
case_ "two-letter suffix X1ab rejected" 1 expectations-guard.sh add_id_two_suffix "malformed id: 'X1ab'"
case_ "G3n row deleted, test kept" 1 expectations-guard.sh drop_G3n_keep_test "G3n was deleted from db/tests/expectations.tsv but its test still exists"
case_ "duplicate id in the registry" 1 expectations-guard.sh add_duplicate_id "more than once: T1"
case_ "registry deleted" 1 expectations-guard.sh delete_registry "expectations.tsv is missing in the head"
case_ "no gate file touched" 0 gate-files-report.sh touch_readme "gate files changed: none"
case_ "gate files touched" 0 gate-files-report.sh touch_gate_files "- \`scripts/ci/pr-size.sh\`"
