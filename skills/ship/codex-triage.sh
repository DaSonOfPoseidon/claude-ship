#!/bin/sh
# Applies a Codex round's triage in one call: for each thread, files the issue (outcome "issue"), posts the reply
# and resolves the thread. Run it from the checkout of the PR's branch (p3-issue.sh reads the branch), by whoever
# triages: in orchestrated mode that is the orchestrator, since subagents can't resolve threads (#100).
# Usage: codex-triage.sh <pr> <triage.json> [owner/repo]   (repo defaults to the current checkout's)
# triage.json is a non-empty array of
#   {"thread": "<id from codex-findings.sh>", "outcome": "not-valid" | "issue" | "fixed" | "resolve",
#    "reply": "<text>", "issue": {"file": "<path>", "title": "<title>", "body": "<finding>"}}
# reply is required except for "resolve" (a thread already replied to: only resolved, any reply is ignored);
# issue is for "issue" only.
# When no entry is "fixed" (no new push will recheck the status), it ends by running the codex-review workflow.
# A "resolve" entry's push is already done, and it ran while the thread was open.
# Exits 2 on bad arguments or an invalid file, before any call; 1 at the first failed call.
set -eu
if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
	echo "usage: codex-triage.sh <pr> <triage.json> [owner/repo]" >&2
	exit 2
fi
pr=$1
file=$2
# jq -e exits 1 on a false result and 5 on none, so any non-zero is "invalid".
# shellcheck disable=SC2016 # jq's own variables, not shell ones
if ! jq -e '
	def nonempty: type == "string" and length > 0;
	type == "array" and length > 0 and all(.[];
		type == "object" and (.thread | nonempty)
		and (.outcome | IN("not-valid", "issue", "fixed", "resolve"))
		and (if .outcome == "resolve" then (.reply == null or (.reply | type == "string")) else (.reply | nonempty) end)
		and ((.outcome == "issue") == (.issue != null))
		and (.issue == null or (.issue | type == "object" and all(.file, .title, .body; nonempty))))' "$file" >/dev/null 2>&1; then
	echo "codex-triage: $file must be a non-empty array of {thread, outcome (not-valid|issue|fixed|resolve), reply (not needed for resolve), issue (only for outcome issue: file, title, body)}" >&2
	exit 2
fi
slug=${3:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
# Next to the hooks directory in both the repo and the installed ~/.claude layout; the variable is for tests.
p3=${CLAUDE_P3_ISSUE:-$(dirname "$0")/../../hooks/p3-issue.sh}
[ -f "$p3" ] || p3=$HOME/.claude/hooks/p3-issue.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
done_ids=
fixed=0

# Stops the run at a failed call. The failed call may still have done part of its work (a reply posted before
# gh failed, an issue filed before the reply), so check the thread and the issue list before redoing it.
stop() {
	echo "done:${done_ids:- (none)}" >&2
	echo "failed: $1 ($2)" >&2
	echo "A failed call may have done part of its work: check the thread's replies and the issue list, then rerun with the done threads removed from $file." >&2
	exit 1
}

n=$(jq length "$file")
i=0
while [ "$i" -lt "$n" ]; do
	id=$(jq -j ".[$i].thread" "$file")
	outcome=$(jq -j ".[$i].outcome" "$file")
	reply=$(jq -j ".[$i].reply // empty" "$file")
	url=
	if [ "$outcome" = issue ]; then
		jq ".[$i].issue" "$file" >"$tmp/issue.json"
		url=$(sh "$p3" "$slug" "$tmp/issue.json") || stop "$id" issue
		reply=$reply$(printf '\n\n%s' "$url")
	fi
	# A fixed thread's push is still to come and rechecks the status. A resolve entry's push already ran, with the
	# thread open, so it doesn't count: the status needs the recheck below.
	[ "$outcome" != fixed ] || fixed=1
	if [ "$outcome" != resolve ]; then
		# The reply goes in a variable (-f is a raw string; -F would read a body starting with @ as a file).
		# shellcheck disable=SC2016 # GraphQL variables, not shell ones
		gh api graphql -f id="$id" -f body="$reply" -f query='
			mutation($id: ID!, $body: String!) {
				addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $id, body: $body}) { comment { id } }
			}' >/dev/null || stop "$id" reply
	fi
	# shellcheck disable=SC2016 # GraphQL variables, not shell ones
	gh api graphql -f id="$id" -f query='
		mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id } } }' >/dev/null || stop "$id" resolve
	done_ids="$done_ids $id"
	echo "$id $outcome${url:+ $url}"
	i=$((i + 1))
done

if [ "$fixed" = 0 ]; then
	gh workflow run codex-review.yml -R "$slug" -f pr="$pr" || stop "(all threads)" workflow
fi
