#!/bin/sh
# Asks Codex to review a PR once GitHub shows the commit just pushed as the PR's head. Right after a push
# GitHub's PR API can still report the previous head, and an `@codex review` posted then reviews that one.
# Usage: codex-request.sh <pr> [owner/repo]   (run in the checkout that pushed; CODEX_REQUEST_TRIES sets
# how many 10s checks to make, default 18)
set -eu
pr=$1
slug=${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
want=$(git rev-parse HEAD)
tries=${CODEX_REQUEST_TRIES:-18}
while :; do
	got=$(gh pr view "$pr" -R "$slug" --json headRefOid --jq .headRefOid)
	[ "$got" = "$want" ] && break
	tries=$((tries - 1))
	if [ "$tries" -le 0 ]; then
		echo "PR #$pr's head is still $got, not HEAD ($want). Did the push land on the PR's branch?" >&2
		exit 1
	fi
	sleep 10
done
gh pr comment "$pr" -R "$slug" -b "@codex review"
