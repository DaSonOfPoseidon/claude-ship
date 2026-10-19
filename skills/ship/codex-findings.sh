#!/bin/sh
# Lists a PR's unresolved Codex review threads, compactly, so triage doesn't read raw API JSON.
# One block per thread: <thread id> <priority> <path>:<line>, the finding's title, its first paragraph.
# Usage: codex-findings.sh <pr> [owner/repo]   (repo defaults to the current checkout's)
set -eu
pr=$1
slug=${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
# shellcheck disable=SC2016 # GraphQL variables, not shell ones
gh api graphql --paginate -F owner="${slug%/*}" -F name="${slug#*/}" -F pr="$pr" -f query='
	query($owner: String!, $name: String!, $pr: Int!, $endCursor: String) {
		repository(owner: $owner, name: $name) {
			pullRequest(number: $pr) {
				reviewThreads(first: 100, after: $endCursor) {
					pageInfo { hasNextPage endCursor }
					nodes { id isResolved path line originalLine comments(first: 1) { nodes { author { login } body } } }
				}
			}
		}
	}' --jq '.data.repository.pullRequest.reviewThreads.nodes[]
		| select((.isResolved | not) and .comments.nodes[0].author.login == "chatgpt-codex-connector")
		| (.comments.nodes[0].body | split("\n\n")) as $parts
		| ($parts[0] | capture("!\\[(?<p>P[0-9]) Badge") .p // "P?") as $prio
		| ($parts[0] | gsub("<[^>]*>|!\\[[^]]*\\]\\([^)]*\\)|\\*\\*"; "") | gsub("^\\s+|\\s+$"; "")) as $title
		| "\(.id) \($prio) \(.path):\(.line // .originalLine // "?")\n  \($title)\n  \($parts[1] // "" | gsub("\n"; " ") | .[0:400])\n"'
