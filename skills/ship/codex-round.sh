#!/bin/sh
# Prints how many Codex review rounds a PR has used: the `@codex review` comments on it.
# Usage: codex-round.sh <pr> [owner/repo]
set -eu
pr=$1
slug=${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
gh api --paginate "repos/$slug/issues/$pr/comments" --jq '.[] | select(.body | test("^\\s*@codex review")) | 1' | wc -l | tr -d ' '
