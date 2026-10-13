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

# YAML spellings that would hide a key from the greps below are refused outright: quoted keys
# ("uses": ...), flow mappings and sequences, anchors, aliases and tags.
if grep -qE "^[[:space:]]*(- )?[\"'][^\"']*[\"'][[:space:]]*:" "$file"; then
  err "quoted keys are not allowed; write every key bare"
fi
if grep -qE '^[[:space:]]*(- )?[{[&*!]|:[[:space:]]+[&*!]' "$file" ||
  grep -E ':[[:space:]]+[{[]' "$file" | grep -qvE ':[[:space:]]+(\{\}|\[[A-Za-z_, ]*\])[[:space:]]*$'; then
  err "flow mappings and sequences (other than {} and a list of bare words), anchors, aliases and tags are not allowed"
fi
if grep -qE '^[[:space:]]*(- )?(shell|defaults):' "$file"; then
  err "shell: and defaults: would change how run lines execute and are not allowed"
fi

# The only expressions that may appear anywhere (run, env, with, concurrency, if) are ones
# that carry no pull request head data.
while IFS= read -r expr; do
  [ -n "$expr" ] || continue
  case "$expr" in
    '${{ github.event.pull_request.number }}' | '${{ github.event.pull_request.base.sha }}' | '${{ !cancelled() }}') ;;
    *) err "expression is not on the base-only allowlist: $expr" ;;
  esac
done < <(grep -oE '\$\{\{[^}]*\}\}' "$file" | sort -u)

triggers=$(awk '/^on:/ { on = 1; next } on && /^[^ #]/ { exit } on && /^  [a-z_]+:/ { sub(/:.*/, ""); gsub(/ /, ""); print }' "$file")
[ "$triggers" = pull_request_target ] || err "the only trigger must be pull_request_target, found: ${triggers//$'\n'/ }"

uses=$(grep -E '^[[:space:]]*(- )?uses:' "$file" | sed -E 's/^[[:space:]]*(- )?uses:[[:space:]]*//; s/[[:space:]]*#.*//' || true)
case "$uses" in
  actions/checkout@*) [ "$(wc -l <<<"$uses")" -eq 1 ] || err "exactly one action is allowed (actions/checkout)" ;;
  *) err "exactly one action is allowed (actions/checkout), found: ${uses//$'\n'/ }" ;;
esac

grep -qE '^[[:space:]]+ref: \$\{\{ github\.event\.pull_request\.base\.sha \}\}$' "$file" || err "checkout ref must be github.event.pull_request.base.sha"
grep -qE '^[[:space:]]+persist-credentials: false$' "$file" || err "checkout must set persist-credentials: false"
if grep -qE '^[[:space:]]+(path|repository|working-directory|submodules|token|ssh-key|sparse-checkout|lfs):' "$file"; then
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
# Options that write files (--output), run programs (--upload-pack, --exec, --ext-diff,
# --textconv) or move the repository (--git-dir, --work-tree) turn a read-only command into
# code execution, and git accepts unique abbreviations of them. Only these are allowed.
allowed_git_options='^(--no-tags|--name-only|--name-status|--numstat|--stat|--raw|--no-renames|--no-ext-diff|--no-textconv|--quiet|-q|-z|--diff-filter=[A-Za-z]+|--)$'
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if [[ "$line" == *'${{'* ]]; then
    err "run line interpolates an expression; pass it through env: $line"
  elif [[ "$line" =~ [\;\&\|\`\<\>] || "$line" == *'$('* ]]; then
    err "run line chains or substitutes commands: $line"
  elif [[ "$line" =~ ^git\ ($allowed_git)\  ]]; then
    read -ra words <<<"$line"
    for word in "${words[@]:2}"; do
      if [[ "$word" == -* ]] && ! [[ "$word" =~ $allowed_git_options ]]; then
        err "git option is not on the read-only allowlist: $word in: $line"
      fi
    done
  elif [[ "$line" =~ ^scripts/ci/[a-z0-9-]+\.sh(\ |$) ]]; then
    :
  else
    err "run line is neither read-only git nor a base scripts/ci script: $line"
  fi
done <<<"$runs"

[ "$fail" -eq 0 ] && echo "$file: no step runs code from the pull request head"
exit "$fail"
