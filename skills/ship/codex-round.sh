#!/bin/sh
# Prints how many Codex review rounds a PR has used: the `@codex review` comments from the owner and
# collaborators, counted as codex-status.sh does. A request whose review stalled (Codex's own 👀 still on it
# after CODEX_STALL_SECS, default 900) doesn't count, and neither does one Codex never acknowledged (at least
# CODEX_ACK_SECS old, default 300, with no bot 👀 now and no bot summary edit, receipt or review between it and
# the next request); docs/scripts.md has the reasons.
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
ack_secs=${CODEX_ACK_SECS:-300}
now=$(date +%s)
# Each call is its own assignment, so `set -e` stops on a failure instead of counting it as 0 rounds.
# One line per request: `<id> <created_at> <👀 count>`.
requests=$(gh api --paginate "repos/$slug/issues/$pr/comments" --jq '.[] | select(.user.type != "Bot") | select(.author_association == "OWNER" or .author_association == "COLLABORATOR") | select(.body | test("^\\s*@codex review\\b")) | "\(.id) \(.created_at) \(.reactions.eyes // 0)"')
# What the bot has done: the summary's last edit, the receipts and the reviews. The summary keeps only its latest
# edit time, so it can vouch only for the latest request; a receipt or a review stays and vouches for its own.
summaries=$(gh api --paginate "repos/$slug/issues/$pr/comments" \
	--jq ".[] | select(.user.login == \"$bot\") | if (.body | contains(\"codex-pull-request-review-summary\")) then .updated_at elif (.body | contains(\"codex-review-receipt\")) then .created_at else empty end")
reviews=$(gh api --paginate "repos/$slug/pulls/$pr/reviews" \
	--jq ".[] | select(.user.login == \"$bot\") | .submitted_at")
bot_times=$(printf '%s\n%s\n' "$summaries" "$reviews" | grep . | cut -c1-19 | sort)
# Each request with the time of the next one (`-` for the latest), which ends the window its answer must fall in.
requests=$(printf '%s\n' "$requests" | grep . | sort -k2,2 |
	awk '{ line[NR] = $0; t[NR] = $2 } END { for (i = 1; i <= NR; i++) print line[i], (i < NR ? substr(t[i + 1], 1, 19) : "-") }')
rounds=0
while read -r id created eyes next; do
	[ -n "$id" ] || continue
	created=$(echo "$created" | cut -c1-19)
	at=$(jq -rn --arg t "${created}Z" '$t | fromdateiso8601')
	age=$((now - at))
	# Anyone can react, so only the bot's own 👀 counts, either way. The list shows only a count, so a request
	# without any 👀 needs no call.
	mine=
	if [ "$eyes" -gt 0 ] && { [ "$age" -ge "$stall_secs" ] || [ "$age" -ge "$ack_secs" ]; }; then
		mine=$(gh api --paginate "repos/$slug/issues/comments/$id/reactions" \
			--jq ".[] | select(.content == \"eyes\") | select(.user.login == \"$bot\") | 1")
	fi
	# Stalled: the 👀 is still on it after the stall time.
	if [ "$age" -ge "$stall_secs" ] && [ -n "$mine" ]; then
		continue
	fi
	# Never acknowledged: old enough to have been picked up, no 👀 now, and nothing from the bot since. Codex
	# removes its 👀 when a review finishes, so no 👀 alone doesn't mean the request was dropped: the receipt, the
	# review or the summary edit it left show that it ran. Times compare as text, to the second; a tie counts as
	# a sign of life.
	if [ "$age" -ge "$ack_secs" ] && [ -z "$mine" ]; then
		active=$(printf '%s\n' "$bot_times" | awk -v c="$created" -v n="$next" '$0 >= c && (n == "-" || $0 <= n)' | grep -c . || true)
		[ "$active" -gt 0 ] || continue
	fi
	rounds=$((rounds + 1))
done <<EOF
$requests
EOF
echo "$rounds"
