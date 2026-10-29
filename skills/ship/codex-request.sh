#!/bin/sh
# Asks Codex to review a PR once GitHub shows the wanted commit as the PR's head. Right after a push
# GitHub's PR API can still report the previous head, and an `@codex review` posted then reviews that one.
# The wanted commit is <sha> (the full SHA of the commit pushed, so this works from any checkout), else this
# checkout's HEAD. If a request for that head is already out (the latest one from the owner or a collaborator
# came after the head's push, nothing from Codex followed it, and it is younger than CODEX_STALL_SECS, default
# 900), it posts nothing and exits 0, so repeating the call is safe; a stalled or answered request may be asked
# again (docs/scripts.md).
# Usage: codex-request.sh <pr> [owner/repo] [sha]   (CODEX_REQUEST_TRIES sets how many 10s checks to make,
# default 18)
set -eu
# A missing PR number exits 2 (usage), so a caller never reads it as a result or a timeout.
if [ -z "${1:-}" ]; then
	echo "usage: codex-request.sh <pr> [owner/repo] [sha]" >&2
	exit 2
fi
pr=$1
slug=${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
if [ -n "${3:-}" ]; then
	want=$3
	# The PR's head is a full SHA, so a short or malformed one could only time out.
	case $want in
	*[!0-9a-f]*) want= ;;
	esac
	if [ "${#want}" -ne 40 ]; then
		echo "codex-request: sha must be a full 40-character lowercase hex SHA" >&2
		exit 2
	fi
else
	want=$(git rev-parse HEAD)
fi
tries=${CODEX_REQUEST_TRIES:-18}
while :; do
	got=$(gh pr view "$pr" -R "$slug" --json headRefOid --jq .headRefOid)
	[ "$got" = "$want" ] && break
	tries=$((tries - 1))
	if [ "$tries" -le 0 ]; then
		echo "PR #$pr's head is still $got, not the wanted commit ($want). Did the push land on the PR's branch?" >&2
		exit 1
	fi
	sleep 10
done

# Each call is its own assignment, so `set -e` stops on a failed call instead of reading it as "no request".
# When the wanted commit was last pushed to the PR's branch, as codex-status.sh finds it. With no push on
# record there is no way to tie a request to this head, so it asks.
branch=$(gh api "repos/$slug/pulls/$pr" --jq '"\(.head.repo.full_name // "-") \(.head.ref)"')
head_repo=${branch%% *}
if [ "$head_repo" != - ]; then
	ref=$(jq -rn --arg r "refs/heads/${branch#* }" '$r | @uri')
	pushes=$(gh api --paginate "repos/$head_repo/activity?ref=$ref" \
		--jq ".[] | select(.activity_type == \"push\" or .activity_type == \"force_push\" or .activity_type == \"branch_creation\") | select(.after == \"$want\") | .timestamp")
	pushed_at=$(printf '%s\n' "$pushes" | sort | tail -1 | cut -c1-19)
	if [ -n "$pushed_at" ]; then
		# Only the owner and collaborators can request a review. ISO 8601 times to the second compare as text.
		requests=$(gh api --paginate "repos/$slug/issues/$pr/comments" \
			--jq '.[] | select(.user.type != "Bot") | select(.author_association == "OWNER" or .author_association == "COLLABORATOR") | select(.body | test("^\\s*@codex review\\b")) | .created_at')
		requested_at=$(printf '%s\n' "$requests" | cut -c1-19 | sort | tail -1)
		# A request from before the push was for an earlier head.
		if [ -n "$requested_at" ] && [ "$(printf '%s\n%s\n' "$pushed_at" "$requested_at" | sort | tail -1)" != "$requested_at" ]; then
			requested_at=
		fi
		if [ -n "$requested_at" ]; then
			bot='chatgpt-codex-connector[bot]'
			receipts=$(gh api --paginate "repos/$slug/issues/$pr/comments" \
				--jq ".[] | select(.user.login == \"$bot\") | select(.body | contains(\"codex-review-receipt\")) | .created_at")
			reviews=$(gh api --paginate "repos/$slug/pulls/$pr/reviews" \
				--jq ".[] | select(.user.login == \"$bot\") | .submitted_at")
			answers=$(printf '%s\n%s\n' "$receipts" "$reviews" | grep . | cut -c1-19 |
				awk -v r="$requested_at" '$0 > r' | grep -c . || true)
			at=$(jq -rn --arg t "${requested_at}Z" '$t | fromdateiso8601')
			if [ "$answers" -eq 0 ] && [ $(($(date +%s) - at)) -lt "${CODEX_STALL_SECS:-900}" ]; then
				echo "A review of $want is already requested (since ${requested_at}Z); not asking again."
				exit 0
			fi
		fi
	fi
fi
gh pr comment "$pr" -R "$slug" -b "@codex review"
