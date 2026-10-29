#!/bin/sh
# Sets the `codex-review` commit status on a PR's head commit: success (Codex reviewed the head after it was
# pushed and every Codex thread is resolved), failure (a thread is unresolved, or the review failed) or pending.
# The rules and design notes are in docs/scripts.md. Repos run this one copy through the action (action.yml,
# @v1); install.sh deploys it into the ship skill for local checks.
# Usage: codex-status.sh <pr>. With DRY_RUN=1 it prints the status instead of setting it.
# Needs `gh` (authenticated, or GH_TOKEN) and REPO (defaults to this repository).
set -eu
pr=${1:-}
case $pr in
'' | *[!0-9]*)
	echo "usage: $0 <pr number>" >&2
	exit 2
	;;
esac
repo=${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
bot='chatgpt-codex-connector[bot]'
owner=${repo%/*}
name=${repo#*/}

# HEAD_SHA checks another commit instead, for testing against past reviews with DRY_RUN=1.
head=${HEAD_SHA:-$(gh api "repos/$repo/pulls/$pr" --jq .head.sha)}
short=$(echo "$head" | cut -c1-7)
head_repo=$(gh api "repos/$repo/pulls/$pr" --jq .head.repo.full_name)
head_ref=$(gh api "repos/$repo/pulls/$pr" --jq .head.ref)

# Each GitHub call is its own assignment, so `set -e` stops on a failed call.
# When this exact commit was last pushed to the PR's branch: a review counts only if it finished after, since
# Codex's summary names commits by a 7-character SHA that could be forged. A new branch's first push is
# recorded as `branch_creation`, not `push`.
ref=$(jq -rn --arg r "refs/heads/$head_ref" '$r | @uri')
pushes=$(gh api --paginate "repos/$head_repo/activity?ref=$ref" \
	--jq ".[] | select(.activity_type == \"push\" or .activity_type == \"force_push\" or .activity_type == \"branch_creation\") | select(.after == \"$head\") | .timestamp")
pushed_at=$(printf '%s\n' "$pushes" | sort | tail -1 | cut -c1-19)

# Codex keeps one summary comment per PR; its Code Review row names the commit it reviewed and the status.
summaries=$(gh api --paginate "repos/$repo/issues/$pr/comments" \
	--jq ".[] | select(.user.login == \"$bot\") | select(.body | contains(\"codex-pull-request-review-summary\")) | .body")
row=$(printf '%s\n' "$summaries" | grep 'Code Review' | grep -F "\`$short\`" || true)
# Stalled: Codex says running, but the summary, the latest trusted request and the push are all older than
# CODEX_STALL_SECS (openai/codex#55890, claude-ship #61). It stays pending, but says so. Another commit's state,
# or one that isn't JSON, isn't a stall.
summary_at=$(gh api --paginate "repos/$repo/issues/$pr/comments" \
	--jq ".[] | select(.user.login == \"$bot\") | select(.body | contains(\"codex-pull-request-review-summary\")) | .updated_at")
# One line per trusted request: `<created_at> <id> <👀 count>`. The latest one counts.
request_lines=$(gh api --paginate "repos/$repo/issues/$pr/comments" \
	--jq '.[] | select(.user.type != "Bot") | select(.author_association == "OWNER" or .author_association == "COLLABORATOR") | select(.body | test("^\\s*@codex review\\b")) | "\(.created_at) \(.id) \(.reactions.eyes // 0)"')
latest=$(printf '%s\n' "$request_lines" | grep . | sort | tail -1)
latest_request=${latest%% *}
latest_rest=${latest#* }
latest_id=${latest_rest%% *}
latest_eyes=${latest_rest##* }
since=$(printf '%s\n%s\n%s\n' "$summary_at" "$latest_request" "$pushed_at" | grep . | cut -c1-19 | sort | tail -1)
review_state=$(printf '%s\n' "$summaries" | sed -n 's/^<!-- codex-review-state:v1 \(.*\) -->$/\1/p' | tail -1 |
	jq -r --arg h "$head" '.code_review | select(.commit_sha == null or .commit_sha == $h) | .status // empty' 2>/dev/null || true)
stall_secs=${CODEX_STALL_SECS:-900}
stalled=
if [ "$review_state" = running ] && [ -n "$summary_at" ]; then
	quiet_since=$(jq -rn --arg t "${since}Z" '$t | fromdateiso8601')
	if [ $(($(date +%s) - quiet_since)) -ge "$stall_secs" ]; then
		stalled=1
	fi
fi
# A row naming no commit (`—`, #30) counts only if the latest trusted request came after the push and exactly
# one completion marker follows it; more than one fails closed (docs/scripts.md).
requested_at=
ambiguous=
if [ -z "$row" ]; then
	row=$(printf '%s\n' "$summaries" | grep 'Code Review' | grep -F '| — |' || true)
	completed=$(echo "$row" | grep -o 'datetime="[^"]*"' | head -1 | cut -d'"' -f2 | cut -c1-19)
	row_ok=
	if [ -n "$completed" ]; then
# Only the owner and collaborators can request a review.
		requests=$(gh api --paginate "repos/$repo/issues/$pr/comments" \
			--jq '.[] | select(.user.type != "Bot") | select(.author_association == "OWNER" or .author_association == "COLLABORATOR") | select(.body | test("^\\s*@codex review\\b")) | .created_at')
# Earlier completions leave a receipt comment (clean) or a pull request review (findings).
		receipts=$(gh api --paginate "repos/$repo/issues/$pr/comments" \
			--jq ".[] | select(.user.login == \"$bot\") | select(.body | contains(\"codex-review-receipt\")) | .created_at")
		reviews=$(gh api --paginate "repos/$repo/pulls/$pr/reviews" \
			--jq ".[] | select(.user.login == \"$bot\") | .submitted_at")
		requested_at=$(printf '%s\n' "$requests" | cut -c1-19 | sort | tail -1)
		if [ -n "$requested_at" ]; then
			# ISO 8601 times to the second compare as text.
			answers=$(printf '%s\n%s\n' "$receipts" "$reviews" | grep . | cut -c1-19 |
				awk -v r="$requested_at" '$0 > r' | grep -c . || true)
			if [ "$answers" -eq 1 ]; then
				row_ok=1
			elif [ "$answers" -gt 1 ]; then
				ambiguous=1
			fi
		fi
	fi
	[ -n "$row_ok" ] || row=
fi

# Unresolved review threads Codex started, on any commit. GraphQL drops the [bot] suffix.
threads=$(gh api graphql --paginate -F owner="$owner" -F name="$name" -F pr="$pr" -f query='
	query($owner: String!, $name: String!, $pr: Int!, $endCursor: String) {
		repository(owner: $owner, name: $name) {
			pullRequest(number: $pr) {
				reviewThreads(first: 100, after: $endCursor) {
					pageInfo { hasNextPage endCursor }
					nodes { isResolved comments(first: 1) { nodes { author { login } } } }
				}
			}
		}
	}' --jq '.data.repository.pullRequest.reviewThreads.nodes[]
		| select(.isResolved | not)
		| select(.comments.nodes[0].author.login == "chatgpt-codex-connector")
		| 1')
findings=$(printf '%s' "$threads" | grep -c . || true)

# The time Codex finished, from its row: <relative-time datetime="...">, to the second.
completed_at=$(echo "$row" | grep -o 'datetime="[^"]*"' | head -1 | cut -d'"' -f2 | cut -c1-19)
# later <a> <b>: a is strictly after b. ISO 8601 times to the second sort as text, so the later one sorts last.
later() {
	[ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] &&
		[ "$(printf '%s\n%s\n' "$2" "$1" | sort | tail -1)" = "$1" ]
}
after_push() {
	later "$completed_at" "$pushed_at" &&
		{ [ -z "$requested_at" ] || { later "$requested_at" "$pushed_at" && later "$completed_at" "$requested_at"; }; }
}

# Not acknowledged (#133): the latest trusted request, made after the head's push, is CODEX_ACK_SECS old and Codex
# has shown no sign of it: no summary edit, no 👀 of its own on the request, no receipt or review after it. Codex
# removes its 👀 when a review finishes, so any bot activity after the request counts, not the 👀 alone. The
# calls beyond the summary are made only for a request this old.
ack_secs=${CODEX_ACK_SECS:-300}
unacked=
req=$(echo "$latest_request" | cut -c1-19)
if later "$req" "$pushed_at"; then
	req_epoch=$(jq -rn --arg t "${req}Z" '$t | fromdateiso8601')
	if [ $(($(date +%s) - req_epoch)) -ge "$ack_secs" ]; then
		# Not before the request: a tie counts as a sign of life (times compare as text, to the second).
		since_request() { [ -n "$1" ] && { [ "$1" = "$req" ] || later "$1" "$req"; }; }
		last_summary=$(printf '%s\n' "$summary_at" | grep . | cut -c1-19 | sort | tail -1)
		unacked=1
		if since_request "$last_summary"; then
			unacked=
		elif [ "$latest_eyes" -gt 0 ]; then
			# The list shows only a count, and anyone can react, so only the bot's own 👀 counts.
			mine=$(gh api --paginate "repos/$repo/issues/comments/$latest_id/reactions" \
				--jq ".[] | select(.content == \"eyes\") | select(.user.login == \"$bot\") | 1")
			[ -z "$mine" ] || unacked=
		fi
		if [ -n "$unacked" ]; then
			receipts=$(gh api --paginate "repos/$repo/issues/$pr/comments" \
				--jq ".[] | select(.user.login == \"$bot\") | select(.body | contains(\"codex-review-receipt\")) | .created_at")
			reviews=$(gh api --paginate "repos/$repo/pulls/$pr/reviews" \
				--jq ".[] | select(.user.login == \"$bot\") | .submitted_at")
			for t in $(printf '%s\n%s\n' "$receipts" "$reviews" | grep . | cut -c1-19); do
				if since_request "$t"; then
					unacked=
				fi
			done
		fi
	fi
fi

if [ "$findings" -gt 0 ]; then
	state=failure
	description="$findings unresolved Codex thread(s); fix or answer each, then resolve it"
elif echo "$row" | grep -q 'Completed' && after_push; then
	state=success
	description="Codex reviewed $short with no findings"
elif echo "$row" | grep -qiE 'Failed|Error'; then
	state=failure
	description="Codex's review of $short failed; ask for another with @codex review"
elif [ -n "$stalled" ]; then
	state=pending
	description="Codex's review of $short stalled (no update in $((stall_secs / 60)) min, openai/codex#55890); ask again with @codex review"
elif [ -n "$ambiguous" ]; then
	state=pending
	description="Codex finished more than once since the last request for $short, so neither is tied to it; ask again with @codex review"
elif [ -n "$unacked" ]; then
	state=pending
	description="Codex hasn't acknowledged the request for $short in $((ack_secs / 60)) min; ask again with @codex review"
else
	state=pending
	description="Waiting for Codex to review $short"
fi

if [ "${DRY_RUN:-}" = 1 ]; then
	echo "$state: $description ($head)"
	exit 0
fi
gh api --silent "repos/$repo/statuses/$head" \
	-f state="$state" -f context=codex-review -f description="$description" \
	-f target_url="https://github.com/$repo/pull/$pr"
echo "$state: $description"
