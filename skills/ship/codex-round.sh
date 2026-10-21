#!/bin/sh
# Prints how many Codex review rounds a PR has used: the `@codex review` comments on it from the owner
# and collaborators (anyone can comment, and an outsider must not use up the rounds).
# Usage: codex-round.sh <pr> [owner/repo]
set -eu
# A missing PR number exits 2 (usage), so a caller never reads it as a result or a timeout.
if [ -z "${1:-}" ]; then
	echo "usage: codex-round.sh <pr> [owner/repo]" >&2
	exit 2
fi
pr=$1
slug=${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
# The call is its own assignment, so `set -e` stops on a failure instead of counting it as 0 rounds.
requests=$(gh api --paginate "repos/$slug/issues/$pr/comments" --jq '.[] | select(.author_association == "OWNER" or .author_association == "COLLABORATOR") | select(.body | test("^\\s*@codex review")) | 1')
printf '%s' "$requests" | grep -c . || true
