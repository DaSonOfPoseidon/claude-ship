#!/bin/sh
# Sets the `codex-review` commit status on a PR's head commit:
#   success  Codex completed a review of the head commit after it was pushed (when its summary names no
#            commit, one asked for after the push), and every Codex review thread is resolved
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
# A clean review's row can name no commit (`—`, #30). It then counts only if the latest `@codex review`
# came after this push, so the commit Codex reviewed can only be this one.
requested_at=
if [ -z "$row" ]; then
	row=$(printf '%s\n' "$summaries" | grep 'Code Review' | grep -F '| — |' || true)
	requests=$(gh api --paginate "repos/$repo/issues/$pr/comments" \
		--jq '.[] | select(.user.type != "Bot") | select(.body | test("^\\s*@codex review\\b")) | .created_at')
	requested_at=$(printf '%s\n' "$requests" | sort | tail -1 | cut -c1-19)
	[ -n "$requested_at" ] || row=
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
