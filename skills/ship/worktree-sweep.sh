#!/bin/sh
# Removes the linked worktrees (and their local branches) of PRs that are merged and hold nothing more, so
# finished implementers' worktrees don't pile up (claude-ship #244). For each linked worktree of the current
# repository it runs unit-state.sh on the worktree's branch, and removes it only when ALL of these hold:
# `state: merged <pr>`, no `unpushed:` line, no `dirty:` line, and no `diverged: yes` line. Removing means:
# unlock it if it is locked, `git worktree remove` (never --force), then `git branch -D` (a squash merge leaves
# the branch unmerged by SHA, so -D is needed, and only after the remove succeeded).
# A lock is not a sign of a live agent: an agent's worktree stays locked with its parent session's pid, which
# outlives the agent. The unit-state facts decide, and the caller checks that no implementer is running.
# Output, one line each:
#   removed: <path> <branch>
#   kept: <path> <branch> <reason>     <branch> is "(none)" for a detached worktree
# It finishes with `git worktree prune`. The main checkout and the checkout it runs in are never touched.
# Exit 0 when it ran to the end (removing nothing or something), 2 on usage, 1 when git or gh failed: it stops at
# once, before any further removal and before the prune.
# Usage: worktree-sweep.sh [owner/repo]   (repo defaults to the current checkout's)
set -eu
usage() {
	echo "usage: worktree-sweep.sh [owner/repo]" >&2
	exit 2
}
die() {
	echo "worktree-sweep.sh: $*" >&2
	exit 1
}
[ $# -le 1 ] || usage
slug=${1:-}
case $slug in
'') ;;
-* | */*/* | *[!A-Za-z0-9_./-]*) usage ;;
*/*) ;;
*) usage ;;
esac

state=$(dirname "$0")/unit-state.sh
[ -f "$state" ] || die "unit-state.sh not found next to the script"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Resolved once, so unit-state.sh doesn't ask for it per worktree.
[ -n "$slug" ] || slug=$(gh repo view --json nameWithOwner --jq .nameWithOwner </dev/null) || die "gh repo view failed"
cur=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
curphys=$(cd "$cur" && pwd -P) || die "cannot enter $cur"

# One record per linked worktree (the first entry is the main checkout and is skipped): path, branch, locked, lock
# reason, joined with the unit separator since a path can hold spaces or tabs.
git worktree list --porcelain >"$tmp/porcelain" 2>"$tmp/err" || die "git worktree list failed: $(head -n 3 "$tmp/err")"
awk '
function out() { if (n > 1) printf "%s\037%s\037%s\037%s\n", path, br, lk, rs }
/^worktree / { if (n > 0) out(); n++; path = substr($0, 10); br = ""; lk = ""; rs = ""; next }
/^branch refs\/heads\// { br = substr($0, 19); next }
/^locked/ { lk = "yes"; rs = substr($0, 8); next }
END { if (n > 0) out() }
' "$tmp/porcelain" >"$tmp/records" || die "reading the worktree list failed"

us=$(printf '\037')
while IFS=$us read -r path branch locked reason; do
	if [ -z "$branch" ]; then
		echo "kept: $path (none) detached HEAD or no branch"
		continue
	fi
	case $path in
	*[[:cntrl:]]*)
		echo "kept: $path $branch path has control characters"
		continue
		;;
	esac
	# Compared resolved (a symlinked path is the same directory), not as text.
	pathphys=$(cd "$path" 2>/dev/null && pwd -P) || pathphys=
	if [ "$path" = "$cur" ] || { [ -n "$pathphys" ] && [ "$pathphys" = "$curphys" ]; }; then
		echo "kept: $path $branch current checkout"
		continue
	fi

	# Exit 2 is a branch name unit-state.sh won't take: not ours to judge. Anything else but 0 is a failure.
	rc=0
	sh "$state" "$branch" "$slug" >"$tmp/state" 2>"$tmp/err" </dev/null || rc=$?
	case $rc in
	0) ;;
	2)
		echo "kept: $path $branch not a plain branch name"
		continue
		;;
	*)
		sed 's/^/worktree-sweep.sh: /' "$tmp/err" >&2
		die "unit-state.sh $branch failed (exit $rc): nothing more was removed"
		;;
	esac

	why=
	first=$(head -n 1 "$tmp/state")
	case $first in
	'state: merged '*) ;;
	*) why=$first ;;
	esac
	if [ -z "$why" ]; then
		if grep -q '^dirty:' "$tmp/state"; then
			why="modified or untracked files, or unreadable"
		elif grep -q '^unpushed:' "$tmp/state"; then
			why="commits the merged PR lacks"
		elif grep -q '^diverged:' "$tmp/state"; then
			why="local and origin diverged"
		fi
	fi
	if [ -n "$why" ]; then
		echo "kept: $path $branch $why"
		continue
	fi

	if [ -n "$locked" ]; then
		git worktree unlock "$path" </dev/null || die "git worktree unlock $path failed: nothing more was removed"
	fi
	if ! git worktree remove "$path" </dev/null 2>"$tmp/err"; then
		# Put the lock back, so a failed remove leaves the worktree as it was.
		if [ -n "$locked" ]; then
			if [ -n "$reason" ]; then
				git worktree lock --reason "$reason" "$path" </dev/null 2>/dev/null || :
			else
				git worktree lock "$path" </dev/null 2>/dev/null || :
			fi
		fi
		die "git worktree remove $path failed: $(head -n 3 "$tmp/err")"
	fi
	git branch -D "$branch" >/dev/null </dev/null || die "git branch -D $branch failed (its worktree $path is already removed)"
	echo "removed: $path $branch"
done <"$tmp/records"

git worktree prune || die "git worktree prune failed"
exit 0
