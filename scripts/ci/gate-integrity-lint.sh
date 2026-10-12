#!/usr/bin/env bash
# shellcheck disable=SC2016
# Prove a pull_request_target workflow never executes code from the PR head.
#
# usage: scripts/ci/gate-integrity-lint.sh [WORKFLOW]   (default .github/workflows/gate-integrity.yml)
#
# The head tree is never checked out, so the only way to run head code would be a second
# checkout, another action, or a command that is not read-only git or a base script.
# Every rule below closes one of those doors.
set -euo pipefail

file="${1:-.github/workflows/gate-integrity.yml}"
fail=0
err() { echo "::error file=$file::$*"; fail=1; }

triggers=$(awk '/^on:/ { on = 1; next } on && /^[^ #]/ { exit } on && /^  [a-z_]+:/ { sub(/:.*/, ""); gsub(/ /, ""); print }' "$file")
[ "$triggers" = pull_request_target ] || err "the only trigger must be pull_request_target, found: ${triggers//$'\n'/ }"

uses=$(grep -E '^[[:space:]]*(- )?uses:' "$file" | sed -E 's/^[[:space:]]*(- )?uses:[[:space:]]*//; s/[[:space:]]*#.*//' || true)
case "$uses" in
  actions/checkout@*) [ "$(wc -l <<<"$uses")" -eq 1 ] || err "exactly one action is allowed (actions/checkout)" ;;
  *) err "exactly one action is allowed (actions/checkout), found: ${uses//$'\n'/ }" ;;
esac

grep -qE '^[[:space:]]+ref: \$\{\{ github\.event\.pull_request\.base\.sha \}\}$' "$file" || err "checkout ref must be github.event.pull_request.base.sha"
grep -qE '^[[:space:]]+persist-credentials: false$' "$file" || err "checkout must set persist-credentials: false"
if grep -qE '^[[:space:]]+(path|repository|working-directory|submodules):' "$file"; then
  err "checkout must not set path, repository or submodules, and no step may set working-directory"
fi

runs=$(awk '
  match($0, /^ *(- )?run: */) {
    key_indent = index($0, "run:") - 1
    rest = substr($0, RSTART + RLENGTH)
    if (rest ~ /^[|>][-+]?$/) { block = 1; next }
    print rest; block = 0; next
  }
  block {
    if ($0 ~ /^[[:space:]]*$/) next
    match($0, /^ */)
    if (RLENGTH > key_indent) { sub(/^ +/, ""); print; next }
    block = 0
  }' "$file")

allowed_git='fetch|diff|ls-tree|cat-file|log|rev-parse|show|rev-list|merge-base'
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if [[ "$line" == *'${{'* ]]; then
    err "run line interpolates an expression; pass it through env: $line"
  elif [[ "$line" =~ [\;\&\|\`\<\>] || "$line" == *'$('* ]]; then
    err "run line chains or substitutes commands: $line"
  elif [[ "$line" =~ ^git\ ($allowed_git)\  ]]; then
    :
  elif [[ "$line" =~ ^scripts/ci/[a-z0-9-]+\.sh(\ |$) ]]; then
    :
  else
    err "run line is neither read-only git nor a base scripts/ci script: $line"
  fi
done <<<"$runs"

[ "$fail" -eq 0 ] && echo "$file: no step runs code from the pull request head"
exit "$fail"
