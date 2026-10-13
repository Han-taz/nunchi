#!/usr/bin/env bash
# Prove a pull_request_target workflow never executes code from the PR head.
# usage: scripts/ci/gate-integrity-lint.sh [WORKFLOW]   (default .github/workflows/gate-integrity.yml)
# The check parses the YAML; see gate-integrity-lint.py. -I ignores PYTHON* variables and the cwd.
set -euo pipefail
exec python3 -I "$(dirname "$0")/gate-integrity-lint.py" "$@"
