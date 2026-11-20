#!/bin/sh
# Removes the linked worktrees (and their local branches) of PRs that are merged and hold nothing more, so
# finished implementers' worktrees don't pile up (claude-ship #244). For each linked worktree of the current
# repository it runs unit-state.sh on the worktree's branch, and removes it only when ALL of these hold:
# `state: merged <pr>`, no `unpushed:` line, no `dirty:` line, and no `diverged: yes` line. Removing means:
# unlock it if it is locked, `git worktree remove` (never --force), then `git branch -D` (a squash merge leaves
# the branch unmerged by SHA, so -D is needed, and only after the remove succeeded).
# A lock is not a sign of a live agent: an agent's worktree stays locked with its parent session's pid, which
# outlives the agent. The unit-state facts decide, and the caller checks that no implementer is running.
# Then two passes over the local branches no worktree holds (claude-ship #286), against GitHub's default branch, freshly
# fetched. `worktree-agent-*` branches (made by Claude Code for an isolation: worktree agent) are deleted when their
# tip is on origin's default branch. Every other branch is deleted only when unit-state.sh says `state: merged`
# with no `unpushed:` and no `diverged:` line. The default branch and any branch a worktree has checked out (the main
# checkout's included, a worktree whose directory is gone, and one in the middle of a rebase) are never touched. A branch in any other state is the
# user's or a live unit's, and prints nothing. The second pass costs two gh calls per local branch.
# Git-ignored files (build output, a `.env`) are neither a `dirty:` fact nor a reason for `git worktree remove` to refuse,
# so they go with the worktree; the sweep lists them first (claude-ship #253). If git can't list them, the worktree stays.
# Output, one line each:
#   removed: <path> <branch>
#   deleted-ignored: <path> <n> path(s): <up to 5 of them>[ …]   after a `removed:` line whose worktree held ignored files
#   kept: <path> <branch> <reason>     <branch> is "(none)" for a detached worktree
#   deleted: <branch>                  a branch with no worktree
#   kept: - <branch> <reason>          a merged or agent branch that still holds something
# It finishes with `git worktree prune`. The main checkout and the checkout it runs in are never touched.
# Exit 0 when it ran to the end (removing nothing or something), 2 on usage, 1 when git or gh failed: it stops at
# once, before any further removal and before the prune; what an earlier pass removed stands.
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

	# git refuses to remove a worktree for modified or untracked files, never for ignored ones (build output, a `.env`):
	# they go with it. List them first, so the loss is told (claude-ship #253). Not being able to read them keeps the
	# worktree, as `dirty: unknown` does. An ignored directory counts as one entry (--ignored=traditional). The untracked mode
	# is set, since the user's status.showUntrackedFiles=no would hide the ignored files too.
	if ! git -C "$path" status --porcelain --untracked-files=normal --ignored=traditional >"$tmp/status" 2>"$tmp/err" </dev/null; then
		echo "kept: $path $branch ignored files unreadable"
		continue
	fi
	awk '/^!! / { print substr($0, 4) }' "$tmp/status" >"$tmp/ignored" || die "reading the ignored files of $path failed: nothing more was removed"
	nignored=$(wc -l <"$tmp/ignored" | tr -d ' ')

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
	if [ "$nignored" -gt 0 ]; then
		# The first five, with anything unprintable dropped from a name (git quotes most of it already).
		list=$(head -n 5 "$tmp/ignored" | tr '\n' ' ' | tr -d '[:cntrl:]')
		more=
		[ "$nignored" -le 5 ] || more=" …"
		echo "deleted-ignored: $path $nignored path(s): ${list% }$more"
	fi
done <"$tmp/records"

# The branch passes below delete local branches that no worktree holds (claude-ship #286): the worktree pass only
# deletes the branch of a worktree it removed. They compare against GitHub's default branch, freshly fetched (local
# refs are state the agent controls). A failure here stops the sweep, and the worktree pass's removals stand.
default=$(gh repo view "$slug" --json defaultBranchRef --jq .defaultBranchRef.name </dev/null) || die "gh repo view $slug (default branch) failed: no branch was deleted"
case $default in
'' | -*) die "$slug has no usable default branch ($default): no branch was deleted" ;;
esac
git check-ref-format --branch "$default" >/dev/null 2>&1 || die "$slug has an odd default branch name ($default): no branch was deleted"
git fetch -q origin "+refs/heads/$default:refs/remotes/origin/$default" 2>"$tmp/err" </dev/null ||
	die "git fetch origin $default failed: no branch was deleted: $(head -n 3 "$tmp/err")"

# Branches a worktree has checked out are never touched, the main checkout's included. Read after the worktree pass
# and before the prune, so a worktree whose directory is gone still holds its branch (it has unfinished work).
git worktree list --porcelain >"$tmp/porcelain" 2>"$tmp/err" || die "git worktree list failed: no branch was deleted: $(head -n 3 "$tmp/err")"
awk '/^branch refs\/heads\// { print substr($0, 19) }' "$tmp/porcelain" >"$tmp/checked" || die "reading the worktree list failed: no branch was deleted"

# A worktree in the middle of a rebase lists as detached, but its rebase-merge/rebase-apply directory names the branch
# (`refs/heads/<branch>`, or `detached HEAD`, which matches nothing here). Both backends, in the main checkout's git
# directory and in each linked worktree's.
common=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd) || die "cannot find the git directory: no branch was deleted"
for f in "$common"/rebase-merge/head-name "$common"/rebase-apply/head-name "$common"/worktrees/*/rebase-merge/head-name "$common"/worktrees/*/rebase-apply/head-name; do
	[ -f "$f" ] || continue
	sed -n '1s|^refs/heads/||p' "$f" >>"$tmp/checked" || die "reading $f failed: no branch was deleted"
done

# held <branch>: some worktree has the branch checked out.
held() {
	grep -qxF -- "$1" "$tmp/checked"
}

# The branches Claude Code makes for an isolation: worktree agent (`worktree-agent-<id>`) outlive the agent's
# worktree. One whose tip is on origin's default branch holds nothing more. -D, not -d, after that check: -d compares
# with HEAD or the branch's upstream, which in the user's checkout may be another or a stale branch, and would refuse
# a branch the ancestor check has just proved merged.
git for-each-ref --format='%(refname)' 'refs/heads/worktree-agent-*' >"$tmp/agents" 2>"$tmp/err" || die "git for-each-ref failed: no branch was deleted: $(head -n 3 "$tmp/err")"
while IFS= read -r ref; do
	b=${ref#refs/heads/}
	! held "$b" || continue
	rc=0
	git merge-base --is-ancestor "$ref" "refs/remotes/origin/$default" </dev/null 2>"$tmp/err" || rc=$?
	case $rc in
	0)
		git branch -D "$b" >/dev/null </dev/null || die "git branch -D $b failed"
		echo "deleted: $b"
		;;
	1) echo "kept: - $b commits not on origin/$default" ;;
	*) die "git merge-base $b failed (exit $rc): no more branches were deleted: $(head -n 3 "$tmp/err")" ;;
	esac
done <"$tmp/agents"

# Every other local branch is deleted only when its PR is merged and it holds nothing more, the facts the worktree pass
# uses. A branch in any other state is the user's or a live unit's: it says nothing, so the `kept:` lines stay few.
# Costs two gh calls per local branch.
git for-each-ref --format='%(refname)' refs/heads/ >"$tmp/branches" 2>"$tmp/err" || die "git for-each-ref failed: no more branches were deleted: $(head -n 3 "$tmp/err")"
while IFS= read -r ref; do
	b=${ref#refs/heads/}
	case $b in
	"$default" | worktree-agent-*) continue ;;
	esac
	! held "$b" || continue
	rc=0
	sh "$state" "$b" "$slug" >"$tmp/state" 2>"$tmp/err" </dev/null || rc=$?
	case $rc in
	0) ;;
	2) continue ;;
	*)
		sed 's/^/worktree-sweep.sh: /' "$tmp/err" >&2
		die "unit-state.sh $b failed (exit $rc): no more branches were deleted"
		;;
	esac
	case $(head -n 1 "$tmp/state") in
	'state: merged '*) ;;
	*) continue ;;
	esac
	# A worktree that unit-state.sh found and the list above lacked (made meanwhile) holds the branch.
	if grep -q '^worktree:' "$tmp/state"; then
		continue
	elif grep -q '^unpushed:' "$tmp/state"; then
		echo "kept: - $b commits the merged PR lacks"
	elif grep -q '^diverged:' "$tmp/state"; then
		echo "kept: - $b local and origin diverged"
	else
		git branch -D "$b" >/dev/null </dev/null || die "git branch -D $b failed"
		echo "deleted: $b"
	fi
done <"$tmp/branches"

git worktree prune || die "git worktree prune failed"
exit 0
