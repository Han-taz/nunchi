#!/usr/bin/env bash
# shellcheck disable=SC2016
# Prove gate-integrity-lint.sh accepts the real workflow and rejects each way to run head code.
set -euo pipefail


root="$(cd "$(dirname "$0")/../.." && pwd)"
lint="$root/scripts/ci/gate-integrity-lint.sh"
real="$root/.github/workflows/gate-integrity.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$lint" "$real" >/dev/null || { echo "FAIL: the real workflow was rejected" >&2; exit 1; }
echo "ok: real workflow -> exit 0"

# case_ NAME SED_EXPRESSION
case_() {
  local name="$1" expr="$2" rc=0
  sed -E "$expr" "$real" >"$tmp/w.yml"
  if cmp -s "$real" "$tmp/w.yml"; then echo "FAIL: $name did not change the workflow" >&2; exit 1; fi
  "$lint" "$tmp/w.yml" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then echo "FAIL: $name was accepted" >&2; exit 1; fi
  echo "ok: $name -> exit $rc"
}

case_ "bash on the head ref" 's|^( +)run: scripts/ci/pr-size.sh .*|\1run: bash head/scripts/ci/pr-size.sh|'
case_ "head script path" 's|^( +)run: scripts/ci/pr-size.sh .*|\1run: head/scripts/ci/pr-size.sh a b|'
case_ "chained command" 's|^( +)run: (scripts/ci/pr-size.sh .*)|\1run: \2; bash x.sh|'
case_ "command substitution" 's|^( +)run: (scripts/ci/pr-size.sh) .*|\1run: \2 "$(curl x)"|'
case_ "expression in run" 's|^( +)run: (scripts/ci/pr-size.sh) .*|\1run: \2 ${{ github.event.pull_request.head.ref }}|'
case_ "git checkout" 's|^( +)run: git fetch .*|\1run: git checkout refs/remotes/pr/head|'
case_ "second action" 's|^( +)- uses: actions/checkout@.*|&\n\1- uses: actions/setup-python@v5|'
case_ "checkout of the head" 's|^( +)ref: .*|\1ref: ${{ github.event.pull_request.head.sha }}|'
case_ "checkout into a path" 's|^( +)fetch-depth: 0|&\n\1path: head|'
case_ "persisted credentials" 's|persist-credentials: false|persist-credentials: true|'
case_ "extra trigger" 's|^on:|on:\n  pull_request:|'
case_ "working-directory" 's|^( +)run: scripts/ci/pr-size.sh .*|&\n\1working-directory: head|'
