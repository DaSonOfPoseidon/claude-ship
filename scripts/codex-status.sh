#!/bin/sh
# Sets the `codex-review` commit status on a PR's head commit:
#   success  Codex completed a review of the head commit after it was pushed, and every Codex review thread is
#            resolved. When its summary names no commit, every trusted request must be matched, in time order,
#            by a completion marker, and the latest request must have come after the push.
#   failure  a Codex thread is unresolved, or Codex's review failed
#   pending  no completed review of the head commit yet
# Resolve a thread once its finding is fixed, or answered with why it doesn't apply.
# This is the only copy: repos run it through this repo's action (action.yml, called @v1), and install.sh
# deploys it into the ship skill for local checks.
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

# Each GitHub call is its own assignment, so `set -e` stops on a failed call instead of reading
# a pipeline's last exit status (an empty result would look like "no findings").
# When this exact commit was last pushed to the PR's branch, from GitHub's own push records.
# Codex's summary names commits by a 7-character SHA, which someone could forge a collision
# for, so a review only counts if it finished after this push. A new branch's first push is
# recorded as `branch_creation`, not `push`.
ref=$(jq -rn --arg r "refs/heads/$head_ref" '$r | @uri')
pushes=$(gh api --paginate "repos/$head_repo/activity?ref=$ref" \
	--jq ".[] | select(.activity_type == \"push\" or .activity_type == \"force_push\" or .activity_type == \"branch_creation\") | select(.after == \"$head\") | .timestamp")
pushed_at=$(printf '%s\n' "$pushes" | sort | tail -1 | cut -c1-19)

# Codex keeps one summary comment per PR and edits it as reviews run. Its Code Review row names
# the commit it reviewed and the status.
summaries=$(gh api --paginate "repos/$repo/issues/$pr/comments" \
	--jq ".[] | select(.user.login == \"$bot\") | select(.body | contains(\"codex-pull-request-review-summary\")) | .body")
row=$(printf '%s\n' "$summaries" | grep 'Code Review' | grep -F "\`$short\`" || true)
# A clean review's row can name no commit (`—`, #30). Nothing ties that completion to a request (neither
# the summary's edit history nor Codex's reactions say which request it answers), so fail closed and match
# them in time order: each completion marker closes the oldest open trusted request, the current one
# included, so none is still running. Equal counts aren't enough: a marker nobody requested (an automatic
# review) would balance a request still running (#49), so a marker with no open request fails too. The
# latest request must also have come after this push, and the review finished after it. A failed review
# leaves no marker, so its request stays open and the status stays pending (the stuck state
# docs/pitfalls.md describes).
requested_at=
ambiguous=
if [ -z "$row" ]; then
	row=$(printf '%s\n' "$summaries" | grep 'Code Review' | grep -F '| — |' || true)
	completed=$(echo "$row" | grep -o 'datetime="[^"]*"' | head -1 | cut -d'"' -f2 | cut -c1-19)
	row_ok=
	if [ -n "$completed" ]; then
		# Anyone can comment `@codex review`, so only the owner and collaborators count (an org member
		# needn't have access to this repository).
		requests=$(gh api --paginate "repos/$repo/issues/$pr/comments" \
			--jq '.[] | select(.user.type != "Bot") | select(.author_association == "OWNER" or .author_association == "COLLABORATOR") | select(.body | test("^\\s*@codex review\\b")) | .created_at')
		# Earlier completions leave a receipt comment (clean) or a pull request review (findings). Codex
		# posts the receipt as a comment whose body starts `<!-- codex-review-receipt:v1 -->`, a few seconds
		# before it edits the summary (seen on OBDCracker #145 and claude-ship #28).
		receipts=$(gh api --paginate "repos/$repo/issues/$pr/comments" \
			--jq ".[] | select(.user.login == \"$bot\") | select(.body | contains(\"codex-review-receipt\")) | .created_at")
		reviews=$(gh api --paginate "repos/$repo/pulls/$pr/reviews" \
			--jq ".[] | select(.user.login == \"$bot\") | .submitted_at")
		requested_at=$(printf '%s\n' "$requests" | cut -c1-19 | sort | tail -1)
		if [ -n "$requested_at" ]; then
			# One line per event, `<time> R` or `<time> M`, sorted as text. At the same second `M` sorts
			# before `R`, so a tie fails closed.
			matched=$({
				printf '%s\n' "$requests" | grep . | cut -c1-19 | sed 's/$/ R/'
				printf '%s\n%s\n' "$receipts" "$reviews" | grep . | cut -c1-19 | sed 's/$/ M/'
			} | sort | awk '$2 == "R" { open++ } $2 == "M" { if (open == 0) bad = 1; else open-- }
				END { print (bad || open) ? "no" : "yes" }')
			if [ "$matched" = yes ]; then
				row_ok=1
			else
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

if [ "$findings" -gt 0 ]; then
	state=failure
	description="$findings unresolved Codex thread(s); fix or answer each, then resolve it"
elif echo "$row" | grep -q 'Completed' && after_push; then
	state=success
	description="Codex reviewed $short with no findings"
elif echo "$row" | grep -qiE 'Failed|Error'; then
	state=failure
	description="Codex's review of $short failed; ask for another with @codex review"
elif [ -n "$ambiguous" ]; then
	state=pending
	description="Review of $short not tied to one request: let running reviews finish; if one failed, delete its request and rerun"
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
