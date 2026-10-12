#!/usr/bin/env bash
# Prove pr-size.sh passes at the limit and fails one line over.
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/pr-size.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
git init -q
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git tag base

run() { # lines expected_exit
  git checkout -q -B "t$1" base
  seq 1 "$1" > f.txt
  git add f.txt
  git -c user.name=t -c user.email=t@t commit -q -m "t$1"
  local rc=0
  "$script" base "t$1" 800 || rc=$?
  if [ "$rc" -ne "$2" ]; then
    echo "FAIL: $1 lines exited $rc, expected $2" >&2
    exit 1
  fi
}

run 800 0
run 801 1
echo "pr-size self-test ok: 800 passes, 801 fails"
