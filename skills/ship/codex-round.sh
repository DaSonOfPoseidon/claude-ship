#!/bin/sh
# Prints how many Codex review rounds a PR has used: the `@codex review` comments on it from the owner
# and collaborators (anyone can comment, and an outsider must not use up the rounds). A request whose
# review stalled doesn't count: Codex's own 👀 is still on it after CODEX_STALL_SECS (default 900), since
# Codex removes it when a review finishes (openai/codex#55890, claude-ship #61).
# Usage: codex-round.sh <pr> [owner/repo]
set -eu
# A missing PR number exits 2 (usage), so a caller never reads it as a result or a timeout.
if [ -z "${1:-}" ]; then
	echo "usage: codex-round.sh <pr> [owner/repo]" >&2
	exit 2
fi
pr=$1
slug=${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
bot='chatgpt-codex-connector[bot]'
stall_secs=${CODEX_STALL_SECS:-900}
now=$(date +%s)
# Each call is its own assignment, so `set -e` stops on a failure instead of counting it as 0 rounds.
# One line per request: `<id> <created_at> <👀 count>`.
requests=$(gh api --paginate "repos/$slug/issues/$pr/comments" --jq '.[] | select(.author_association == "OWNER" or .author_association == "COLLABORATOR") | select(.body | test("^\\s*@codex review")) | "\(.id) \(.created_at) \(.reactions.eyes // 0)"')
rounds=0
while read -r id created eyes; do
	[ -n "$id" ] || continue
	if [ "$eyes" -gt 0 ]; then
		at=$(jq -rn --arg t "$(echo "$created" | cut -c1-19)Z" '$t | fromdateiso8601')
		if [ $((now - at)) -ge "$stall_secs" ]; then
			# Anyone can react, so only the bot's own 👀 marks a stall.
			mine=$(gh api --paginate "repos/$slug/issues/comments/$id/reactions" \
				--jq ".[] | select(.content == \"eyes\") | select(.user.login == \"$bot\") | 1")
			[ -z "$mine" ] || continue
		fi
	fi
	rounds=$((rounds + 1))
done <<EOF
$requests
EOF
echo "$rounds"
