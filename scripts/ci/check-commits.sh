#!/usr/bin/env bash
# Check every commit in BASE..HEAD for the commit policy.
#
# usage: scripts/ci/check-commits.sh BASE HEAD
#
# Rules: conventional-commit subject (max 100 chars), no merge commits (develop
# keeps a linear history), and no AI attribution in the message.
set -euo pipefail

base="${1:?base ref required}"
head="${2:?head ref required}"

subject_re='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?: .+'
attribution_re='co-authored-by:.*(claude|anthropic|openai|chatgpt|copilot|gemini)|generated (with|by).*(claude|anthropic|chatgpt|copilot|gemini)|noreply@anthropic\.com'

failed=0
count=0
while read -r sha; do
  count=$((count + 1))
  subject=$(git log -1 --format=%s "$sha")
  message=$(git log -1 --format=%B "$sha")
  parents=$(git log -1 --format=%p "$sha" | wc -w)

  if ! [[ "$subject" =~ $subject_re ]]; then
    echo "::error::$sha: subject is not a conventional commit: $subject"
    failed=1
  fi
  if [ "${#subject}" -gt 100 ]; then
    echo "::error::$sha: subject is longer than 100 characters"
    failed=1
  fi
  if [ "$parents" -gt 1 ]; then
    echo "::error::$sha: merge commit; rebase instead (linear history)"
    failed=1
  fi
  if grep -qiE "$attribution_re" <<<"$message"; then
    echo "::error::$sha: commit message carries AI attribution"
    failed=1
  fi
done < <(git rev-list --reverse "$base..$head")

if [ "$count" -eq 0 ]; then
  echo "::error::no commits in $base..$head; the range is wrong"
  exit 1
fi
echo "checked $count commit(s)"
exit "$failed"
