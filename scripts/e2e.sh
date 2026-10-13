#!/usr/bin/env bash
# Memory story end to end against docker compose. Exits non-zero on the first failed step.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export POSTGRES_PASSWORD=e2e-postgres APP_RW_PASSWORD=e2e-app-rw DEV_ISSUER=https://dev-idp.test
export MCP_PORT="${MCP_PORT:-18000}" API_PORT="${API_PORT:-18080}"
compose=(docker compose -f deploy/compose.yml -f deploy/compose.e2e.yml)

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then "${compose[@]}" logs --no-color --tail 40 || true; fi
  "${compose[@]}" down -v --remove-orphans || true
  rm -rf deploy/.dev
  exit "$status"
}
trap cleanup EXIT

mkdir -p deploy/.dev
openssl genrsa -out deploy/.dev/private.pem 2048 2>/dev/null
uv run --locked python scripts/e2e/story.py keys deploy/.dev
"${compose[@]}" up -d --build --wait
uv run --locked python scripts/e2e/story.py run deploy/.dev "http://127.0.0.1:${MCP_PORT}/mcp"
"${compose[@]}" logs worker | grep -q "worker: expired 0, stale 0"
echo "worker pass: ok"
echo "e2e: all steps passed"
