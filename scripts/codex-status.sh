#!/bin/sh
# Sets the `codex-review` commit status on a PR's head commit: success (Codex reviewed the head after it was
# pushed and every Codex thread is resolved), failure (a thread is unresolved, or the review failed) or pending.
# On a fork PR, which Codex can't review (openai/codex#47577), the repo owner can also approve the head by commenting
# one of the phrases below after it was pushed.
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
# The owner's approval of a fork PR: a comment that is, after trimming whitespace and one trailing . or !, and
# ignoring case, exactly one of these (jq string literals, lower case). Whole-comment only, so conversation
# doesn't trigger it. approval_hint is the one the failure message names.
approval_phrases='"okay to merge", "approved for merge", "ready for prod", "owner approved"'
approval_hint='Okay to merge'

# The bot's pull request reviews, read the first time a path needs them and kept (#111): one line each,
# `<submitted_at> <commit_id>` (an unsubmitted review has a null submitted_at, printed as null). Call it as a
# statement, not inside $(...), which would lose the cache; a failed read stops the script (set -e).
bot_reviews=
reviews_read=
read_reviews() {
	[ -z "$reviews_read" ] || return 0
	bot_reviews=$(gh api --paginate "repos/$repo/pulls/$pr/reviews" \
		--jq '.[] | select(.user.login == "'"$bot"'") | "\(.submitted_at) \(.commit_id)"')
	reviews_read=1
}

# Each endpoint is read once, and every value below comes from that one read (#111): two reads are not one snapshot,
# so a push or an edit between them would pair values from different moments. The filters stay in gh's `--jq`
# (gojq), which decides which comments are trusted; local jq only decodes a JSON string. Each read is its own
# assignment, so `set -e` stops on a failed call before anything is posted.
# The PR's head: <sha>, <repo>, <ref> separated by tabs (a deleted fork's repo reads null, as gh prints it).
pr_line=$(gh api "repos/$repo/pulls/$pr" --jq '[.head.sha, (.head.repo.full_name // "null"), .head.ref] | join("\t")')
# HEAD_SHA checks another commit instead, for testing against past reviews with DRY_RUN=1.
head=${HEAD_SHA:-$(printf '%s\n' "$pr_line" | cut -f1)}
short=$(echo "$head" | cut -c1-7)
head_repo=$(printf '%s\n' "$pr_line" | cut -f2)
# A fork PR has another head repository; a deleted fork has none (null, or empty from another tool's output).
fork=
case $head_repo in
'' | null) fork=1 ;;
*) [ "$(echo "$head_repo" | tr A-Z a-z)" = "$(echo "$repo" | tr A-Z a-z)" ] || fork=1 ;;
esac
head_ref=$(printf '%s\n' "$pr_line" | cut -f3)

# When this exact commit was last pushed to the PR's branch: a review counts only if it finished after, since
# Codex's summary names commits by a 7-character SHA that could be forged. A new branch's first push is
# recorded as `branch_creation`, not `push`.
ref=$(jq -rn --arg r "refs/heads/$head_ref" '$r | @uri')
# A deleted fork has no activity to read, so nothing counts as after the push.
pushes=
case $head_repo in
'' | null) ;;
*)
	pushes=$(gh api --paginate "repos/$head_repo/activity?ref=$ref" \
		--jq ".[] | select(.activity_type == \"push\" or .activity_type == \"force_push\" or .activity_type == \"branch_creation\") | select(.after == \"$head\") | .timestamp")
	;;
esac
pushed_at=$(printf '%s\n' "$pushes" | sort | tail -1 | cut -c1-19)

# The PR's comments, read once: one tagged line per match of each filter (a comment can match several). The
# filters are the ones the separate reads used, in this order per comment:
#   S <updated_at> <body as JSON>   Codex's summary comments (the body is one line of JSON, so it can't forge a tag)
#   R <created_at> <id> <eyes>      requests from the owner and collaborators; anyone can comment `@codex review`
#   C <created_at>                  Codex's receipts, the markers of a clean review
#   A <created_at>                  the owner's fork approvals (used below only for a fork PR)
comment_lines=$(gh api --paginate "repos/$repo/issues/$pr/comments" --jq '.[]
	| (select(.user.login == "'"$bot"'") | select(.body | contains("codex-pull-request-review-summary")) | "S \(.updated_at) \(.body | @json)"),
	(select(.user.type != "Bot") | select(.author_association == "OWNER" or .author_association == "COLLABORATOR") | select(.body | test("^\\s*@codex review\\b")) | "R \(.created_at) \(.id) \(.reactions.eyes // 0)"),
	(select(.user.login == "'"$bot"'") | select(.body | contains("codex-review-receipt")) | "C \(.created_at)"),
	(select(.user.type != "Bot") | select(.author_association == "OWNER")
		| select(.body | gsub("^\\s+|\\s+$"; "") | sub("[.!]$"; "") | gsub("\\s+$"; "") | ascii_downcase | IN('"$approval_phrases"'))
		| "A \(.created_at)")')
# Codex keeps one summary comment per PR; its Code Review row names the commit it reviewed and the status.
summaries=$(printf '%s\n' "$comment_lines" | sed -n 's/^S [^ ]* //p' | jq -r .)
row=$(printf '%s\n' "$summaries" | grep 'Code Review' | grep -F "\`$short\`" || true)
# Stalled: Codex says running, but the summary, the latest trusted request and the push are all older than
# CODEX_STALL_SECS (openai/codex#55890, claude-ship #61). It stays pending, but says so. Another commit's state,
# or one that isn't JSON, isn't a stall.
summary_at=$(printf '%s\n' "$comment_lines" | sed -n 's/^S \([^ ]*\) .*/\1/p')
# One line per trusted request: `<created_at> <id> <👀 count>`. The latest one counts.
request_lines=$(printf '%s\n' "$comment_lines" | sed -n 's/^R //p')
latest=$(printf '%s\n' "$request_lines" | grep . | sort | tail -1)
latest_request=${latest%% *}
latest_rest=${latest#* }
latest_id=${latest_rest%% *}
latest_eyes=${latest_rest##* }
since=$(printf '%s\n%s\n%s\n' "$summary_at" "$latest_request" "$pushed_at" | grep . | cut -c1-19 | sort | tail -1)
review_state=$(printf '%s\n' "$summaries" | sed -n 's/^<!-- codex-review-state:v1 \(.*\) -->$/\1/p' | tail -1 |
	jq -r --arg h "$head" '.code_review | select(.commit_sha == null or .commit_sha == $h) | .status // empty' 2>/dev/null || true)
# Findings reported (#229): the state says the head's review completed with findings (has_any_findings, true only
# when the JSON names the head), though the review that carries them may not have posted yet.
review_any=$(printf '%s\n' "$summaries" | sed -n 's/^<!-- codex-review-state:v1 \(.*\) -->$/\1/p' | tail -1 |
	jq -r --arg h "$head" '.code_review | select(.commit_sha == $h) | .has_any_findings // empty' 2>/dev/null || true)
stall_secs=${CODEX_STALL_SECS:-900}
# quiet: the summary, the latest trusted request and the push are all at least CODEX_STALL_SECS old.
quiet() {
	[ -n "$summary_at" ] || return 1
	quiet_since=$(jq -rn --arg t "${since}Z" '$t | fromdateiso8601')
	[ $(($(date +%s) - quiet_since)) -ge "$stall_secs" ]
}
stalled=
if [ "$review_state" = running ] && quiet; then
	stalled=1
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
# Only requests from the owner and collaborators count (anyone can comment `@codex review`).
		requests=$(printf '%s\n' "$request_lines" | cut -d' ' -f1)
# Earlier completions leave a receipt comment (clean) or a pull request review (findings).
		receipts=$(printf '%s\n' "$comment_lines" | sed -n 's/^C //p')
		read_reviews
		reviews=$(printf '%s\n' "$bot_reviews" | cut -d' ' -f1)
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

# Owner approval of a fork PR (#126): only the repo owner counts (not a bot with the owner's association), and only
# a comment created after the head's push, so an approval of an older head doesn't carry over. Same-repo PRs never
# read the comments for it. created_at, not updated_at: an edit doesn't move an approval past a push.
approved=
if [ -n "$fork" ]; then
	approvals=$(printf '%s\n' "$comment_lines" | sed -n 's/^A //p')
	approved_at=$(printf '%s\n' "$approvals" | grep . | cut -c1-19 | sort | tail -1)
	if later "$approved_at" "$pushed_at"; then
		approved=1
	fi
fi

# Not acknowledged (#133): the latest trusted request, made after the head's push, is CODEX_ACK_SECS old and Codex
# has shown no sign of it: no summary edit, no 👀 of its own on the request, no receipt or review after it. Codex
# removes its 👀 when a review finishes, so any bot activity after the request counts, not the 👀 alone. The
# calls beyond the summary are made only for a request this old.
ack_secs=${CODEX_ACK_SECS:-300}
unacked=
req=$(echo "$latest_request" | cut -c1-19)
# A request in the push's own second belongs to this head, as codex-request.sh counts it (>=); otherwise a
# request tied with the push could never be retried.
if [ -n "$req" ] && [ -n "$pushed_at" ] && { [ "$req" = "$pushed_at" ] || later "$req" "$pushed_at"; }; then
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
			receipts=$(printf '%s\n' "$comment_lines" | sed -n 's/^C //p')
			read_reviews
			reviews=$(printf '%s\n' "$bot_reviews" | cut -d' ' -f1)
			for t in $(printf '%s\n%s\n' "$receipts" "$reviews" | grep . | cut -c1-19); do
				if since_request "$t"; then
					unacked=
				fi
			done
		fi
	fi
fi

# A failed review stands only until a trusted request newer than it (#184): the retry is running, and Codex edits
# the summary only when it picks the request up. The failure's time is the summary's last edit; a request in the
# same second counts as before it, as everywhere (times compare as text, to the second).
failed=
if echo "$row" | grep -qiE 'Failed|Error'; then
	failed=1
	failed_at=$(printf '%s\n' "$summary_at" | grep . | cut -c1-19 | sort | tail -1)
	if later "$req" "$failed_at"; then
		failed=
	fi
fi

# Posting (#229): Codex can mark its summary completed with findings before the review that carries them is
# posted, and a success then would read "no findings" with the threads still to come. Only when the success
# branch below would fire: it needs a Codex review of the head, submitted at or after the later of the latest
# trusted request and the push (to the second, as text), so a re-review of the same head waits for its own.
# The reviews are read only in that case.
posting=
if [ "$review_state" = completed ] && [ "$review_any" = true ] && echo "$row" | grep -q 'Completed' && after_push; then
	posting=1
	floor=$(printf '%s\n%s\n' "$latest_request" "$pushed_at" | grep . | cut -c1-19 | sort | tail -1)
	# An unsubmitted review has no submitted_at, and "null" would sort after every date.
	read_reviews
	posted_reviews=$(printf '%s\n' "$bot_reviews" | awk -v h="$head" '$2 == h && $1 != "null" { print $1 }')
	posted=$(printf '%s\n' "$posted_reviews" | grep . | cut -c1-19 | awk -v f="$floor" '$0 >= f' | grep -c . || true)
	if [ "$posted" -gt 0 ]; then
		posting=
	elif quiet; then
		# #231: the review never posted; the status stays pending but says so (codex-wait.sh exits 3 on "stalled").
		posting=stalled
	fi
fi

# An unanswered request for the head (#282): the latest trusted request came at or after the head's push and no
# receipt or review of Codex's follows it. Open threads from an earlier review would hide it behind a failure, and
# codex-request.sh would then ask again (a second review of the same head) instead of waiting. Read only with
# threads open: without them the verdicts below already say pending. `req` is the request's time, from above.
open_request=
if [ "$findings" -gt 0 ] && [ -n "$req" ] && [ -n "$pushed_at" ] && { [ "$req" = "$pushed_at" ] || later "$req" "$pushed_at"; }; then
	req_receipts=$(printf '%s\n' "$comment_lines" | sed -n 's/^C //p')
	read_reviews
	req_reviews=$(printf '%s\n' "$bot_reviews" | cut -d' ' -f1)
	# Strictly after, as codex-request.sh counts (times compare as text, to the second).
	req_answers=$(printf '%s\n%s\n' "$req_receipts" "$req_reviews" | grep . | cut -c1-19 |
		awk -v r="$req" '$0 > r' | grep -c . || true)
	if [ "$req_answers" -eq 0 ]; then
		open_request=1
	fi
fi

if [ -n "$open_request" ]; then
	# The pending verdicts below, in their usual order; the threads wait until Codex answers the request.
	state=pending
	if [ "$posting" = stalled ]; then
		description="Codex finished $short with findings but its review never posted (stalled, no update in $((stall_secs / 60)) min); ask again with @codex review"
	elif [ -n "$posting" ]; then
		description="Codex finished $short with findings; waiting for its review to post"
	elif [ -n "$failed" ] && [ -n "$fork" ]; then
		# A confirmed failed review (#282): the request got its answer, a failure, so it can be retried.
		state=failure
		description="Codex can't review fork PRs (openai/codex#47577); owner: comment '$approval_hint' to approve $short"
	elif [ -n "$failed" ]; then
		state=failure
		description="Codex's review of $short failed; ask for another with @codex review"
	elif [ -n "$stalled" ]; then
		description="Codex's review of $short stalled (no update in $((stall_secs / 60)) min, openai/codex#55890); ask again with @codex review"
	elif [ -n "$unacked" ]; then
		description="Codex hasn't acknowledged the request for $short in $((ack_secs / 60)) min; ask again with @codex review"
	else
		description="Waiting for Codex to review $short"
	fi
elif [ "$findings" -gt 0 ]; then
	state=failure
	description="$findings unresolved Codex thread(s); fix or answer each, then resolve it"
elif [ -n "$approved" ]; then
	state=success
	description="Owner approved $short for merge (fork PR)"
elif [ "$posting" = stalled ]; then
	state=pending
	description="Codex finished $short with findings but its review never posted (stalled, no update in $((stall_secs / 60)) min); ask again with @codex review"
elif [ -n "$posting" ]; then
	state=pending
	description="Codex finished $short with findings; waiting for its review to post"
elif echo "$row" | grep -q 'Completed' && after_push; then
	state=success
	description="Codex reviewed $short with no findings"
elif [ -n "$failed" ] && [ -n "$fork" ]; then
	state=failure
	description="Codex can't review fork PRs (openai/codex#47577); owner: comment '$approval_hint' to approve $short"
elif [ -n "$failed" ]; then
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
