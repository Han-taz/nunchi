#!/usr/bin/env bash
# Fail when a change touches more than LIMIT lines outside reference prose.
#
# usage: scripts/ci/pr-size.sh BASE HEAD [LIMIT]
#
# Lines are added + deleted, counted against the merge base. docs/research/**
# and docs/reviews/** are excluded because they are reference prose and
# experiment output, and the tool lock files because they are generated. Set SIZE_OVERRIDE=true
# (the workflow does this when the PR carries the size-override label) to
# report the size without failing.
set -euo pipefail

base="${1:?base ref required}"
head="${2:?head ref required}"
limit="${3:-800}"

total=$(git diff --numstat "$base...$head" -- . ':(exclude)docs/research/**' ':(exclude)docs/reviews/**' \
  ':(exclude).github/tools/package-lock.json' ':(exclude).github/tools/requirements.txt' \
  | awk '$1 != "-" { sum += $1 + $2 } END { print sum + 0 }')

echo "changed lines outside docs/research and docs/reviews: $total (limit $limit)"
if [ "$total" -gt "$limit" ]; then
  if [ "${SIZE_OVERRIDE:-false}" = "true" ]; then
    echo "::warning::over the limit, allowed by the size-override label"
    exit 0
  fi
  echo "::error::PR changes $total lines (limit $limit). Split it, or ask the owner for the size-override label."
  exit 1
fi
