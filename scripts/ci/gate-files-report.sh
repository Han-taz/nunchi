#!/usr/bin/env bash
# Print which CI gate files a change touches. Never fails on that alone.
#
# usage: scripts/ci/gate-files-report.sh BASE HEAD
#
# Reads only git objects (name-only diff), so it is safe to point at an untrusted head.
set -euo pipefail

base="${1:?base ref required}"
head="${2:?head ref required}"

gate_re='^(\.github/|scripts/ci/|scripts/db-test\.sh$|\.sqlfluff(ignore)?$|\.squawk\.toml$|\.semgrep/|\.gitleaks\.toml$|\.typos\.toml$|\.editorconfig$|\.markdownlint-cli2\.jsonc$|pyproject\.toml$|db/tests/expectations\.tsv$|db/migrations/SHA256SUMS$)'

touched=$(git diff --no-ext-diff --no-textconv --no-renames --name-only -z "$base...$head" | tr '\0' '\n' | { grep -E "$gate_re" || true; })

emit() {
  echo "$1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$1" >>"$GITHUB_STEP_SUMMARY"; fi
}

if [ -z "$touched" ]; then
  emit "gate files changed: none"
  exit 0
fi

echo "::warning::this pull request changes CI gate files; the verifier must read each one"
emit "## GATE FILES CHANGED"
emit ""
while IFS= read -r path; do
  emit "- \`$path\`"
done <<<"$touched"
emit ""
emit "These run from the PR head in ci.yml. gate-integrity ran the BASE versions of the size, migration, commit and registry gates."
