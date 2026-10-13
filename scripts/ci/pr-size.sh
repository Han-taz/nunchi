#!/usr/bin/env bash
# Fail when a change touches more than LIMIT lines outside reference prose.
#
# usage: scripts/ci/pr-size.sh BASE HEAD [LIMIT]
#
# Lines are added + deleted, counted against the merge base, with repository
# attributes ignored so a .gitattributes in the PR cannot hide a file.
#
#   docs/research/** and docs/reviews/**   *.md is exempt from the line budget
#                                          only when it is text: git gives numeric
#                                          counts and the blob is valid UTF-8 with
#                                          no NUL byte. A binary renamed .md is
#                                          sized like any binary. A second
#                                          extension (.sql.md, .py.md, .s-ql.md,
#                                          ..md) is not exempt unless it is all
#                                          digits (gatemem-2606.18829.md).
#   lock files                             exempt from the line budget only, and
#                                          only when the manifest it is generated
#                                          from changed in the same PR (uv.lock
#                                          needs pyproject.toml). They must be
#                                          UTF-8 text without NUL, at most 2 MiB
#                                          each and 4 MiB together. They sit
#                                          outside the 1 MiB general total so a
#                                          real dependency bump is not blocked.
#   png jpg gif svg pdf ico                count as 50 lines per 10 KB (min 50)
#   any other binary file                  fails the job
#
# Line counts alone are bypassed by CR-only files and single huge lines, so
# bytes are capped too, measured from the blob at HEAD:
#   any other file                         at most 512 KB
#   all changed files together             at most 1 MiB, exempt .md included
#                                          (exemption covers the line budget only);
#                                          exempt lock files are counted separately
#
# There is no bypass. A PR over the limit must be split.
set -euo pipefail

base="${1:?base ref required}"
head="${2:?head ref required}"
limit="${3:-800}"
file_byte_cap=524288
total_byte_cap=1048576
lock_file_cap=2097152
lock_total_cap=4194304

# --attr-source=<empty tree> stops git reading .gitattributes from the work tree,
# so `-diff`, `binary` and custom diff drivers cannot turn a file into "- -".
empty_tree="$(git mktree </dev/null)"
export GIT_ATTR_NOSYSTEM=1

git_diff() {
  git -c core.attributesFile=/dev/null --attr-source="$empty_tree" \
    diff --no-ext-diff --no-textconv --no-renames "$@"
}

# "<bytes> <t|b>\t<path>" for every added or modified file, sized from its HEAD
# blob. t marks a blob that is valid UTF-8 without NUL bytes.
sizes="$(mktemp)"
trap 'rm -f "$sizes"' EXIT
git_diff --raw -z --no-abbrev --diff-filter=d "$base...$head" |
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r _ mode _ sha _ <<<"${meta#:}"
    kind=b
    if [ "$mode" = 160000 ]; then
      size=0
    else
      size=$(git cat-file -s "$sha")
      if [ "$(git cat-file blob "$sha" | tr -d '\0' | wc -c)" -eq "$size" ] &&
        git cat-file blob "$sha" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
        kind=t
      fi
    fi
    printf '%s %s\t%s\n' "$size" "$kind" "$path"
  done >"$sizes"

result=$(git_diff --numstat -z "$base...$head" | tr '\0' '\n' |
  awk -v file_cap="$file_byte_cap" -v total_cap="$total_byte_cap" -v lock_cap="$lock_file_cap" -v lock_total_cap="$lock_total_cap" -v sizes="$sizes" '
    BEGIN {
      while ((getline line < sizes) > 0) {
        tab = index(line, "\t")
        split(substr(line, 1, tab - 1), sk, " ")
        bytes[substr(line, tab + 1)] = sk[1] + 0
        kind[substr(line, tab + 1)] = sk[2]
      }
    }
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
        is_lock = 0
        if (path ~ /^\.github\/tools\/[^\/]+$/) {
          name = substr(path, length(".github/tools/") + 1)
          if (name in lock && (".github/tools/" lock[name]) in changed) is_lock = 1
        }
        if (path == "uv.lock" && "pyproject.toml" in changed) is_lock = 1
        if (is_lock) {
          if (path in bytes) {
            size = bytes[path] + 0
            if (kind[path] != "t") { print "BYTES lock file " path " is not UTF-8 text without NUL bytes"; bad = 1; continue }
            if (size > lock_cap) { print "BYTES lock file " path " is " size " bytes (lock file cap " lock_cap ")"; bad = 1; continue }
            lock_bytes += size
          }
          continue
        }
        size = bytes[path] + 0
        if (size > file_cap) { print "BYTES " path " is " size " bytes (file cap " file_cap ")"; bad = 1; continue }
        total_bytes += size
        base = path; sub(/^.*\//, "", base)
        if (path ~ /^docs\/(research|reviews)\/.*\.md$/ && add[i] != "-" && kind[path] == "t" &&
            (base !~ /\.[^.]*\.md$/ || base ~ /\.[0-9]+\.md$/)) continue
        if (add[i] == "-") {
          if (path ~ /\.(png|jpg|gif|svg|pdf|ico)$/) {
            units = int((size + 10239) / 10240); if (units < 1) units = 1
            sum += units * 50
            continue
          }
          print "BINARY " path
          bad = 1
          continue
        }
        sum += add[i] + del[i]
      }
      if (lock_bytes > lock_total_cap) { print "BYTES lock files total " lock_bytes " bytes (lock file total cap " lock_total_cap ")"; bad = 1 }
      if (total_bytes > total_cap) { print "BYTES changed files total " total_bytes " bytes (total cap " total_cap ")"; bad = 1 }
      if (!bad) print "TOTAL " sum + 0
    }')

if grep -q '^BYTES ' <<<"$result"; then
  grep '^BYTES ' <<<"$result" | while IFS= read -r line; do
    echo "::error::${line#BYTES }. Split the PR."
  done
  exit 1
fi

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
