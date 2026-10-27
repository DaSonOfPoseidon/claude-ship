#!/bin/sh
# Source: github.com/DaSonOfPoseidon/claude-ship (hooks/), deployed into ~/.claude by its install.sh from main.
#
# Files a review finding as an issue, labelled by the finding's file: p3-issue.sh <owner/repo> <finding.json>,
# where the JSON has `file`, `title` and `body` (in a file, since the gate reads a command naming ~/.claude/hooks
# with a `>` anywhere in it as a write). Run from the checkout whose branch the finding is in; prints the issue's
# URL. The review gate files its confirmed P3s with it, and the ship skill files Codex findings it defers with it.
#
# Labels: the repo variable CLAUDE_P3_LABELS (default `review:p3`), plus every rule matching `file` in
# .github/claude-ship/p3-labels on the default branch (a branch can't change how its own findings are filed),
# one rule per line, `<glob> <label>[,<label>...]`, where `*` spans `/`. If none of them is a type label (`bug`,
# `documentation`, `enhancement`, `type:*`), CLAUDE_P3_TYPE_LABEL is added when set. Labels the repo doesn't have
# are dropped.
# Milestone, only with CLAUDE_P3_MILESTONE=auto: the branch's open PR's, else the one milestone of the issues its
# commit subjects fix (`fixes #N`), else none.
# A finding is never lost to its labels: if filing fails, it retries without the milestone, then without labels.
set -u
slug=$1
file=$(jq -er .file "$2") && title=$(jq -er .title "$2") && body=$(jq -er .body "$2") || {
	echo "p3-issue: $2 needs string fields file, title and body" >&2
	exit 1
}

var() {
	gh variable get "$1" -R "$slug" 2>/dev/null
}

# The default branch, as GitHub reports it, fetched; empty if either fails.
base=
if main=$(gh repo view "$slug" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null) &&
	git check-ref-format "refs/heads/$main" && git fetch -q origin "+refs/heads/$main:refs/remotes/origin/$main" 2>/dev/null; then
	base=refs/remotes/origin/$main
fi

# One label per line.
labels=$(var CLAUDE_P3_LABELS) || labels=review:p3
labels=$(printf '%s\n' "$labels" | tr ',' '\n')
if [ -n "$base" ]; then
	map=$(git show "$base:.github/claude-ship/p3-labels" 2>/dev/null)
	set -f
	while read -r glob add; do
		case $glob in
		'' | '#'*) continue ;;
		esac
		# shellcheck disable=SC2254 # the rule's glob is a pattern
		case $file in
		$glob) labels=$(printf '%s\n%s\n' "$labels" "$add" | tr ',' '\n') ;;
		esac
	done <<EOF
$map
EOF
	set +f
fi
listed=
known=$(gh label list -R "$slug" --limit 1000 --json name --jq '.[].name' 2>/dev/null) && listed=1
# Trims and dedupes $labels, and drops the ones the repo doesn't have (when its labels could be listed).
tidy() {
	labels=$(printf '%s\n' "$labels" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | awk '!seen[$0]++')
	if [ -n "$listed" ]; then
		printf '%s\n' "$labels" | grep -vxF -e "$known" | while IFS= read -r l; do
			echo "p3-issue: $slug has no label \"$l\"; skipping it" >&2
		done
		labels=$(printf '%s\n' "$labels" | grep -xF -e "$known")
	fi
}
# The type fallback goes by the labels that will actually be applied.
tidy
if ! printf '%s\n' "$labels" | grep -Eq '^(bug|documentation|enhancement|type:.*)$' && type=$(var CLAUDE_P3_TYPE_LABEL); then
	labels=$(printf '%s\n%s\n' "$labels" "$type")
	tidy
fi

milestone=
if [ "$(var CLAUDE_P3_MILESTONE)" = auto ]; then
	branch=$(git symbolic-ref -q --short HEAD)
	if [ -n "$branch" ]; then
		milestone=$(gh pr list -R "$slug" --head "$branch" --state open --json milestone \
			--jq '.[0].milestone.title // empty' 2>/dev/null)
	fi
	if [ -z "$milestone" ] && [ -n "$base" ]; then
		found=$(git log --format=%s "$base..HEAD" |
			grep -Eio '(fix|fixes|fixed|close|closes|closed|resolve|resolves|resolved)[[:space:]]+#[0-9]+' |
			grep -Eo '[0-9]+$' | sort -u | while read -r n; do
			gh issue view "$n" -R "$slug" --json milestone --jq '.milestone.title // empty' 2>/dev/null
		done | sed '/^$/d' | sort -u)
		[ "$(printf '%s' "$found" | grep -c '')" = 1 ] && milestone=$found
	fi
fi

# create <with milestone: 1 or empty> <with labels: 1 or empty>
create() {
	m=$1
	l=$2
	set -- issue create -R "$slug" --title "$title" --body "$body"
	[ -n "$m" ] && set -- "$@" --milestone "$milestone"
	if [ -n "$l" ]; then
		while IFS= read -r label; do
			[ -n "$label" ] && set -- "$@" --label "$label"
		done <<EOF
$labels
EOF
	fi
	gh "$@"
}

if [ -n "$milestone" ]; then
	url=$(create 1 1 2>&1) && {
		printf '%s\n' "$url"
		exit 0
	}
	echo "p3-issue: couldn't file with milestone \"$milestone\" ($url); retrying without it" >&2
fi
url=$(create '' 1 2>&1) && {
	printf '%s\n' "$url"
	exit 0
}
if [ -n "$labels" ]; then
	echo "p3-issue: couldn't file with labels $(printf '%s' "$labels" | tr '\n' ',') ($url); retrying without them" >&2
	url=$(create '' '' 2>&1) && {
		printf '%s\n' "$url"
		exit 0
	}
fi
printf '%s\n' "$url"
exit 1
