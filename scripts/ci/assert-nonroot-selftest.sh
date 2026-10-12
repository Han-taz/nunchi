#!/usr/bin/env bash
# Prove assert-nonroot.sh rejects root images (including one with a fake `id`) and accepts a
# non-root one.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
base="$(grep -m1 '^FROM python@' "$here/../../Dockerfile" | awk '{print $2}')"
tmp="$(mktemp -d)"
tag="nunchi-nonroot-selftest-$$"
variants=(root user fakeid rootname uidzero alias)
trap 'for v in "${variants[@]}"; do docker rmi -f "$tag-$v" >/dev/null 2>&1 || true; done; rm -rf "$tmp"' EXIT

fake_id='RUN printf "#!/bin/sh\necho uid=10001(app) gid=10001(app)\n" >/usr/local/bin/id && chmod +x /usr/local/bin/id'
adduser='RUN useradd --system --uid 10001 --no-create-home t'
printf 'FROM %s\n' "$base" >"$tmp/root"
printf 'FROM %s\n%s\nUSER 10001\n' "$base" "$adduser" >"$tmp/user"
printf 'FROM %s\n%s\nUSER root\n' "$base" "$fake_id" >"$tmp/fakeid"
printf 'FROM %s\n%s\nUSER root:root\n' "$base" "$adduser" >"$tmp/rootname"
printf 'FROM %s\nUSER 0:0\n' "$base" >"$tmp/uidzero"
printf 'FROM %s\nRUN useradd --non-unique --uid 0 --gid 0 --no-create-home app\nUSER app\n' "$base" >"$tmp/alias"
for v in "${variants[@]}"; do
  docker build -q -t "$tag-$v" -f "$tmp/$v" "$tmp" >/dev/null
done

for v in root fakeid rootname uidzero alias; do
  if "$here/assert-nonroot.sh" "$tag-$v" >"$tmp/$v.log" 2>&1; then
    echo "FAIL: $v image was accepted" >&2
    exit 1
  fi
  grep -q 'runs as root' "$tmp/$v.log" || { echo "FAIL: $v image rejected without the root message" >&2; cat "$tmp/$v.log" >&2; exit 1; }
  echo "ok: $v image rejected"
done

"$here/assert-nonroot.sh" "$tag-user" | grep -q 'uid=10001'
echo "ok: non-root image accepted"
echo "assert-nonroot self-test ok"
