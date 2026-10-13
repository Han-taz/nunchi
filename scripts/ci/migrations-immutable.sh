#!/usr/bin/env bash
# Fail when an applied migration could have been rewritten.
#
# usage: scripts/ci/migrations-immutable.sh [BASE HEAD]
#
# Run from inside the checkout. Two checks:
#   1. db/migrations/SHA256SUMS is exactly the sha256 of every db/migrations/*.sql, in
#      byte order. The runner (python -m nunchi.migrate) verifies the same manifest, so an
#      edited file cannot apply on a fresh database without an edited manifest too.
#   2. With BASE and HEAD, every path under db/migrations/ in BASE is present in HEAD with the
#      same mode and blob hash. Edited, deleted and renamed migrations all fail. SHA256SUMS is
#      the one file that grows: each BASE line must still be in HEAD's copy.
#   3. Every migration HEAD adds has a version strictly greater than the highest version in
#      BASE, so two open PRs cannot slip a migration in before one that already merged.
#   4. No dotfile exists under db/migrations in HEAD (or the checkout). The shell glob that
#      seals SHA256SUMS skips dotfiles, so one would escape the manifest.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
dir=db/migrations
manifest=$dir/SHA256SUMS
fail=0
err() { echo "::error::$*"; fail=1; }

sums() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

tree_names() { git ls-tree -r --name-only -z "$1" -- "$dir" | tr '\0' '\n'; }

while IFS= read -r path; do
  case "/${path#"$dir"/}" in
    */.*) err "$path is a dotfile: dotfiles are skipped by the manifest glob, so they are not allowed in $dir" ;;
    *) ;;
  esac
done < <(tree_names "${2:-HEAD}")

[ -f "$manifest" ] || { echo "::error::$manifest is missing"; exit 1; }
expected=$(cd "$dir" && LC_ALL=C sums -- *.sql)
if ! diff -u <(echo "$expected") "$manifest"; then
  err "$manifest does not match the sha256 of the migration files (regenerate: cd $dir && sha256sum *.sql > SHA256SUMS)"
fi

if [ $# -ge 2 ]; then
  base="$1"
  head="$2"
  while IFS= read -r -d '' record; do
    path=${record#*$'\t'}
    [ "$path" != "$manifest" ] || continue
    want=${record%%$'\t'*}
    got=$(git ls-tree -z "$head" -- "$path" | tr -d '\0')
    if [ "${got%%$'\t'*}" != "$want" ]; then
      verb="deleted or renamed"
      [ -z "$got" ] || verb="changed"
      err "$path is frozen: it was $verb in the head (migrations are never edited after they merge; add a new one)"
    fi
  done < <(git ls-tree -r -z "$base" -- "$dir")

  base_max=$(tree_names "$base" | sed -n "s|^$dir/\([0-9]\{4\}\)_[^/]*\.sql\$|\1|p" | sort | tail -n 1)
  while IFS= read -r path; do
    version=$(basename "$path" | sed -n 's|^\([0-9]\{4\}\)_.*\.sql$|\1|p')
    [ -n "$version" ] || continue
    if [ -n "$base_max" ] && [ "$((10#$version))" -le "$((10#$base_max))" ]; then
      err "$path: new migration versions must be greater than the highest version in the base ($base_max)"
    fi
  done < <(comm -13 <(tree_names "$base" | sort) <(tree_names "$head" | sort))

  if git cat-file -e "$base:$manifest" 2>/dev/null; then
    lost=$(comm -23 <(git show "$base:$manifest" | sort) <(git show "$head:$manifest" 2>/dev/null | sort) || true)
    [ -z "$lost" ] || err "SHA256SUMS lost or changed lines from the base: $lost"
  fi
fi

[ "$fail" -eq 0 ] && echo "migrations are immutable and match $manifest"
exit "$fail"
