#!/usr/bin/env bash
# Fail when a container image runs as root.
#
# usage: scripts/ci/assert-nonroot.sh IMAGE
#
# Two checks that do not trust anything inside the image's PATH:
#   1. The configured user (`docker image inspect` Config.User) must be set and must not be
#      0, root, 0:*, root:*, or a numeric form such as 00 or 0:0.
#   2. The real process uid, read by /usr/bin/env launching python3 with the image's own USER,
#      must not be 0. A fake `id` on PATH cannot influence it.
set -euo pipefail

image="${1:?image required}"

user="$(docker image inspect --format '{{.Config.User}}' "$image")"
echo "$image configured user: '${user}'"
name="${user%%:*}"
if [[ -z "$user" || -z "$name" || "$name" == "root" || "$name" =~ ^0+$ ]]; then
  echo "::error::image $image runs as root (Config.User='${user}')"
  exit 1
fi

if ! docker run --rm --entrypoint /usr/bin/env "$image" \
  python3 -c 'import os,sys; print("uid=%d" % os.getuid()); sys.exit(os.getuid()==0)'; then
  echo "::error::image $image runs as root or its uid could not be read"
  exit 1
fi
