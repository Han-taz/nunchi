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

# case_ NAME SED_EXPRESSION [EXPECTED_MESSAGE_PATTERN]
case_() {
  local name="$1" expr="$2" pattern="${3:-}" rc=0
  sed -E "$expr" "$real" >"$tmp/w.yml"
  if cmp -s "$real" "$tmp/w.yml"; then echo "FAIL: $name did not change the workflow" >&2; exit 1; fi
  "$lint" "$tmp/w.yml" >"$tmp/out.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then echo "FAIL: $name was accepted" >&2; exit 1; fi
  if [ -n "$pattern" ] && ! grep -q -- "$pattern" "$tmp/out.log"; then
    echo "FAIL: $name was rejected for another reason:" >&2
    cat "$tmp/out.log" >&2
    exit 1
  fi
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
case_ "quoted uses key" 's|^( +)- uses: actions/checkout@.*|&\n\1- "uses": ./head-action|' 'quoted keys'
case_ "single-quoted uses key" "s|^( +)- uses: actions/checkout@.*|&\n\1- 'uses': ./head-action|" 'quoted keys'
case_ "flow mapping step" 's|^( +)- uses: actions/checkout@.*|&\n\1- { uses: ./head-action }|' 'flow mappings'
case_ "yaml anchor" 's|^( +)persist-credentials: false|\1persist-credentials: \&nocreds false|' 'anchors'
case_ "shell override" 's|^( +)run: scripts/ci/pr-size.sh .*|&\n\1shell: python {0}|' 'shell: and defaults:'
case_ "defaults block" 's|^permissions: \{\}|&\ndefaults:\n  run:\n    shell: bash|' 'shell: and defaults:'
case_ "head ref in env" 's|^( +)PR_NUMBER: .*|&\n\1HEAD_BRANCH: ${{ github.event.pull_request.head.ref }}|' 'allowlist: \${{ github.event.pull_request.head.ref'
case_ "head sha in env" 's|^( +)PR_NUMBER: .*|&\n\1HEAD_SHA: ${{ github.event.pull_request.head.sha }}|' 'allowlist: \${{ github.event.pull_request.head.sha'
case_ "git show --output overwrites a base script" 's|^( +)run: git fetch .*|\1run: git show refs/remotes/pr/head:scripts/ci/pr-size.sh --output=scripts/ci/pr-size.sh|' 'allowlist: --output'
case_ "git diff abbreviated --out" 's|^( +)run: git fetch .*|\1run: git diff --out=scripts/ci/pr-size.sh a b|' 'allowlist: --out='
case_ "git fetch --upload-pack" 's|^( +)run: git fetch .*|\1run: git fetch --upload-pack=./head/x origin|' 'allowlist: --upload-pack'
case_ "git log --ext-diff" 's|^( +)run: git fetch .*|\1run: git log -p --ext-diff|' 'allowlist: --ext-diff'
echo "gate-integrity-lint self-test ok"
