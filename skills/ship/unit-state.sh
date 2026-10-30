#!/bin/sh
# Prints where a planned unit's branch stands, so the orchestrator can resume a unit whose implementer ended
# without a report (an error, a usage-limit stop, a killed session, or a /clear). Read-only: it fetches the
# default branch and the unit's branch from origin and never switches, resets, deletes or pushes.
# The first line is the state; detail lines follow, in this order, when they apply:
#   state: merged <pr> | pr-open <pr> | pr-closed <pr>   a PR on the branch (an open one wins over newer ones)
#   state: pushed       on origin, no PR
#   state: local <n>    only a local branch, <n> commits ahead of origin's default branch
#   state: diverged     no PR; local and origin each have commits the other lacks
#   state: none         no branch anywhere, or one with no commits of its own
#   ahead: <n>          commits of the branch (its furthest tip) over origin's default branch
#   unpushed: <n>       local commits origin's copy of the branch lacks
#   origin-only: <n>    origin commits the local branch lacks (with unpushed: diverged)
#   diverged: yes       diverged, and a PR exists, so the state line is the PR's
#   worktree: <path>    the worktree that has the branch checked out
#   dirty: yes|unknown  that worktree has modified or untracked files (unknown: git couldn't read it)
# Exit 0 when it printed a state, 2 on usage, 1 when git or gh failed (never a guess from stale refs).
# Usage: unit-state.sh <branch> [owner/repo]   (repo defaults to the current checkout's)
set -eu
usage() {
	echo "usage: unit-state.sh <branch> [owner/repo]" >&2
	exit 2
}
die() {
	echo "unit-state.sh: $*" >&2
	exit 1
}
[ $# -ge 1 ] && [ $# -le 2 ] || usage
branch=$1
slug=${2:-}
# The branch comes from a plan file: it must be a plain branch name. check-ref-format --branch would also expand
# "@{-1}" to a name, so the name must come back unchanged.
case $branch in '' | -*) usage ;; esac
[ "$(git check-ref-format --branch "$branch" 2>/dev/null)" = "$branch" ] || usage
case $slug in
'') ;;
-* | */*/* | *[!A-Za-z0-9_./-]*) usage ;;
*/*) ;;
*) usage ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

[ -n "$slug" ] || slug=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || die "gh repo view failed"
# GitHub says which branch is the default; origin/HEAD is a local ref the agent controls.
default=$(gh repo view "$slug" --json defaultBranchRef --jq .defaultBranchRef.name) || die "gh repo view $slug failed"
[ -n "$default" ] || die "$slug has no default branch"

# A failed fetch is an error, not "nothing there": the answer would come from stale refs.
git fetch -q origin "+refs/heads/$default:refs/remotes/origin/$default" 2>"$tmp/err" ||
	die "git fetch origin $default failed: $(head -n 3 "$tmp/err")"
git ls-remote origin "refs/heads/$branch" >"$tmp/ls" 2>"$tmp/err" || die "git ls-remote origin failed: $(head -n 3 "$tmp/err")"
# ls-remote matches patterns by their tail, so only the exact ref counts. A remote-tracking ref left over from a
# branch origin has since deleted (a merge with --delete-branch) is not read at all.
onorigin=$(awk -v ref="refs/heads/$branch" '$2 == ref { print "yes"; exit }' "$tmp/ls")
if [ -n "$onorigin" ]; then
	git fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" 2>"$tmp/err" ||
		die "git fetch origin $branch failed: $(head -n 3 "$tmp/err")"
fi

# count <base> <tip>: commits reachable from tip and not from base.
count() {
	git rev-list --count "$1..$2" 2>/dev/null || die "git rev-list failed"
}
# is_anc <a> <b>: a is an ancestor of b. Exit 1 is "no"; anything higher is a failure.
is_anc() {
	rc=0
	git merge-base --is-ancestor "$1" "$2" 2>/dev/null || rc=$?
	[ "$rc" -le 1 ] || die "git merge-base failed"
	return "$rc"
}

base=$(git rev-parse --verify -q "refs/remotes/origin/$default^{commit}") || die "no origin/$default after the fetch"
# rev-parse --verify -q exits 1 for a missing ref; anything else is a failure, not "no local branch".
rc=0
localsha=$(git rev-parse --verify -q "refs/heads/$branch^{commit}" 2>/dev/null) || rc=$?
[ "$rc" -le 1 ] || die "git rev-parse refs/heads/$branch failed"
originsha=
[ -z "$onorigin" ] || originsha=$(git rev-parse --verify -q "refs/remotes/origin/$branch^{commit}") || die "no origin/$branch after the fetch"

tip=
unpushed=
originonly=
diverged=
if [ -n "$localsha" ] && [ -n "$originsha" ]; then
	if [ "$localsha" = "$originsha" ]; then
		tip=$originsha
	elif is_anc "$originsha" "$localsha"; then
		tip=$localsha
		unpushed=$(count "$originsha" "$localsha")
	elif is_anc "$localsha" "$originsha"; then
		tip=$originsha
	else
		diverged=1
		unpushed=$(count "$originsha" "$localsha")
		originonly=$(count "$localsha" "$originsha")
	fi
elif [ -n "$localsha" ]; then
	tip=$localsha
elif [ -n "$originsha" ]; then
	tip=$originsha
fi
ahead=0
[ -z "$tip" ] || ahead=$(count "$base" "$tip")

# The PRs on the branch, newest first (gh's order). --head filters by branch name only, so a fork's PR from a
# branch of the same name comes back too: isCrossRepository drops those, and a PR without the field is an error
# (it could be a fork's). Of the unit's own PRs, an open one is the unit's; else the newest.
gh pr list -R "$slug" --head "$branch" --state all --json number,state,isCrossRepository --limit 30 >"$tmp/prs" 2>"$tmp/err" ||
	die "gh pr list failed: $(head -n 3 "$tmp/err")"
pick=$(jq -r 'if type == "array" and all(.[]; .isCrossRepository | type == "boolean")
	then map(select(.isCrossRepository == false)) | (map(select(.state == "OPEN")) + .)[0] // empty | [.state, (.number | tostring)] | join(" ")
	else error("not a list of PRs with isCrossRepository") end' "$tmp/prs" 2>/dev/null) ||
	die "gh pr list printed no JSON list of PRs with isCrossRepository"
state=
if [ -n "$pick" ]; then
	prnum=${pick#* }
	# Only digits come out of this: the number is printed, and the orchestrator passes it to gh.
	case $prnum in '' | *[!0-9]*) die "gh pr list gave a PR number that isn't a number" ;; esac
	case ${pick%% *} in
	OPEN) state="pr-open $prnum" ;;
	MERGED) state="merged $prnum" ;;
	CLOSED) state="pr-closed $prnum" ;;
	*) die "gh pr list gave a PR state it doesn't know" ;;
	esac
elif [ -n "$diverged" ]; then
	state=diverged
elif [ -z "$tip" ] || [ "$ahead" -eq 0 ]; then
	state=none
elif [ -n "$originsha" ]; then
	state=pushed
else
	state="local $ahead"
fi

echo "state: $state"
case $state in
pushed | pr-* | merged*) [ -n "$tip" ] && [ -z "$diverged" ] && echo "ahead: $ahead" ;;
esac
[ -z "$unpushed" ] || echo "unpushed: $unpushed"
[ -z "$originonly" ] || echo "origin-only: $originonly"
[ -z "$diverged" ] || [ "$state" = diverged ] || echo "diverged: yes"

# The worktree that has the branch (the plan's implementer's, or the main checkout). Its path is only printed.
git worktree list --porcelain >"$tmp/wt" 2>"$tmp/err" || die "git worktree list failed: $(head -n 3 "$tmp/err")"
awk -v ref="refs/heads/$branch" '/^worktree / { p = substr($0, 10) } $0 == ("branch " ref) { print p; exit }' "$tmp/wt" >"$tmp/wtpath" || die "reading the worktree list failed"
wtpath=$(tr -d '[:cntrl:]' <"$tmp/wtpath")
if [ -n "$wtpath" ]; then
	echo "worktree: $wtpath"
	if st=$(git -C "$wtpath" status --porcelain 2>/dev/null); then
		[ -z "$st" ] || echo "dirty: yes"
	else
		echo "dirty: unknown"
	fi
fi
exit 0
