#!/usr/bin/env bash
# Fail when a change touches more than LIMIT lines outside reference prose.
#
# usage: scripts/ci/pr-size.sh BASE HEAD [LIMIT]
#
# Lines are added + deleted, counted against the merge base, with repository
# attributes ignored so a .gitattributes in the PR cannot hide a file.
#
#   docs/research/** and docs/reviews/**   *.md only is exempt (reference prose)
#   lock files                             exempt only when the manifest it is
#                                          generated from changed in the same PR
#   png jpg gif svg pdf ico                count as BINARY_LINES each
#   any other binary file                  fails the job
#
# There is no bypass. A PR over the limit must be split.
set -euo pipefail

base="${1:?base ref required}"
head="${2:?head ref required}"
limit="${3:-800}"

# --attr-source=<empty tree> stops git reading .gitattributes from the work tree,
# so `-diff`, `binary` and custom diff drivers cannot turn a file into "- -".
empty_tree="$(git mktree </dev/null)"
export GIT_ATTR_NOSYSTEM=1

result=$(git -c core.attributesFile=/dev/null --attr-source="$empty_tree" \
  diff --no-ext-diff --no-textconv --no-renames --numstat -z "$base...$head" | tr '\0' '\n' |
  awk -v binary_lines=50 '
    $0 !~ /^([0-9]+|-)\t([0-9]+|-)\t/ { print "BINARY malformed numstat record: " $0; bad = 1; next }
    {
      split($0, f, "\t")
      path = f[3]
      for (i = 4; i in f; i++) path = path "\t" f[i]
      add[NR] = f[1]; del[NR] = f[2]; p[NR] = path
      changed[path] = 1
    }
    END {
      lock["package-lock.json"] = "package.json"
      lock["requirements.txt"] = "requirements.in"
      for (i = 1; i <= NR; i++) {
        path = p[i]
        if (path ~ /^docs\/(research|reviews)\/.*\.md$/) continue
        if (path ~ /^\.github\/tools\/[^\/]+$/) {
          name = substr(path, length(".github/tools/") + 1)
          if (name in lock && (".github/tools/" lock[name]) in changed) continue
        }
        if (add[i] == "-") {
          if (path ~ /\.(png|jpg|gif|svg|pdf|ico)$/) { sum += binary_lines; continue }
          print "BINARY " path
          bad = 1
          continue
        }
        sum += add[i] + del[i]
      }
      if (!bad) print "TOTAL " sum + 0
    }')

if grep -q '^BINARY ' <<<"$result"; then
  grep '^BINARY ' <<<"$result" | while IFS= read -r line; do
    echo "::error::binary file not on the allowlist (png jpg gif svg pdf ico): ${line#BINARY }"
  done
  exit 1
fi

total="${result#TOTAL }"
echo "changed lines after exemptions: $total (limit $limit)"
if [ "$total" -gt "$limit" ]; then
  echo "::error::PR changes $total lines (limit $limit). Split the PR."
  exit 1
fi
