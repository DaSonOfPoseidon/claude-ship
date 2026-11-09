#!/bin/sh
# Source: github.com/DaSonOfPoseidon/claude-ship (hooks/), deployed into ~/.claude by its install.sh from main.
#
# What every git hook stub in ~/.claude/git-hooks runs: `git-hook.sh <hook name> [git's arguments]`. install.sh sets
# core.hooksPath to that directory, which stops git from running a repo's own .git/hooks, so every hook here first chains
# to the repo's own hook of that name (same arguments, same stdin), and pre-push also checks Claude's pushes: a commit
# with no `.pass` or `.waived` in the review state is refused, whatever started the push (a plain push, a script,
# `gh pr create`, a compound command); a tag is refused unless its commit is on the remote's default branch. The user's own
# pushes are untouched. Design notes: docs/gate.md › Pre-push check.
set -u

name=${1:-}
if [ -z "$name" ]; then
	echo "usage: git-hook.sh <hook name> [git's arguments]" >&2
	exit 2
fi
shift

# The repo's own hook of this name: its executable file in the repository's hooks directory, which a linked worktree
# shares. Fails when there is none (or no repository).
own_hook() {
	common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	[ -x "$common/hooks/$name" ] && [ -f "$common/hooks/$name" ]
}

if [ "$name" != pre-push ]; then
	if own_hook; then
		exec "$common/hooks/$name" "$@"
	fi
	exit 0
fi

# --- pre-push ---
# git gives it the remote's name and URL as arguments, and one line per ref on stdin:
#   <local ref> <local sha> <remote ref> <remote sha>
refuse() {
	echo "claude-ship: push refused: $1" >&2
	exit 1
}
saved=$(mktemp) || refuse "couldn't save the ref lines to check them (mktemp failed)."
trap 'rm -f "$saved"' EXIT
# A lines list that couldn't be saved in full (a full disk, a file size limit) is not an empty list.
cat >"$saved" || refuse "couldn't save the ref lines to check them."

# Is this Claude's push? The variable Claude Code sets for the processes it starts (the npm install runs as `node`, so the
# process name alone would miss it), or a process named `claude` among the ancestors (covers `sudo` and `env -i`).
# Walks at most 64 steps up and stops at PID 1. Without `ps` the answer is no: the user's pushes are never checked.
claude_ancestor() {
	pid=$$
	steps=0
	while [ "$steps" -lt 64 ]; do
		steps=$((steps + 1))
		pid=$(ps -o ppid= -p "$pid" 2>/dev/null) || return 1
		pid=$(printf '%s' "$pid" | tr -d '[:space:]')
		case $pid in
		'' | *[!0-9]*) return 1 ;;
		esac
		[ "$pid" -gt 1 ] || return 1
		comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
		comm=${comm##*/}
		[ "$comm" != claude ] || return 0
	done
	return 1
}

# Runs the repo's own pre-push the way git would have, with the arguments and the saved stdin; exits with its status.
run_own() {
	if own_hook; then
		"$common/hooks/pre-push" "$@" <"$saved"
		exit $?
	fi
	exit 0
}

if [ "${CLAUDE_CODE_CHILD_SESSION:-}" != 1 ] && ! claude_ancestor; then
	run_own "$@"
fi

dir=$(cd "$(dirname "$0")" && pwd)
[ -r "$dir/gate-common.sh" ] || refuse "$dir/gate-common.sh is missing, so the opt-in lookup can't run. Ask the user to run claude-ship's install.sh."
# shellcheck source=gate-common.sh
. "$dir/gate-common.sh"

# The destination, as GitHub repos: the remote's configured push URLs (pushurl, else url; as configured, before insteadOf
# rewrites them), the first argument itself (a push by URL passes the URL as typed there, and the rewritten one as the
# second) and the URL git resolved, so a pushurl that differs from the url, or a rewrite, can't hide one.
urls=
if [ -n "${1:-}" ]; then
	urls=$(git config --get-all "remote.$1.pushurl" 2>/dev/null)
	[ -n "$urls" ] || urls=$(git config --get-all "remote.$1.url" 2>/dev/null)
fi
urls=$(printf '%s\n%s\n%s\n' "$urls" "${1:-}" "${2:-}" | sed '/^$/d')
slugs=$(printf '%s\n' "$urls" | github_slugs)
# Not a GitHub destination: nothing to check.
[ -n "$slugs" ] || run_own "$@"
if bad=$(printf '%s\n' "$slugs" | grep -m1 '^?'); then
	refuse "can't read the GitHub repo in the remote URL ${bad#?}, so the opt-in lookup can't run. Use https://github.com/<owner>/<repo>.git or git@github.com:<owner>/<repo>.git."
fi

# Does any of the repos opt in? Not found means no; an error (GitHub down, gh missing or logged out) refuses.
enforce=
for slug in $slugs; do
	if ! flag=$(autonomous "$slug"); then
		refuse "couldn't read CLAUDE_AUTONOMOUS for $slug from GitHub, so the check can't tell whether it guards it. Check \`gh auth status\` and retry."
	fi
	if [ -n "$flag" ]; then
		enforce=1
		break
	fi
done
[ -n "$enforce" ] || run_own "$@"

# git with the network's wait bounded, no prompt for credentials and no stdin (the loop below reads the ref lines from its
# own, which a fetch over ssh would eat): a hook that waits forever is no answer.
net_git() {
	if command -v timeout >/dev/null 2>&1; then
		GIT_TERMINAL_PROMPT=0 timeout 60 git "$@" </dev/null
	else
		GIT_TERMINAL_PROMPT=0 git "$@" </dev/null
	fi
}
# on_default_branch <remote URL> <commit>: is the commit on the remote's default branch, as the remote reports it now?
# Local refs are state Claude controls (`git update-ref refs/remotes/origin/main` proves nothing), so the tip comes from
# `ls-remote` against the URL the push goes to, and its commit is fetched from there if this clone lacks it. Anything it
# can't tell (no URL, the network, output it can't read, a missing object, a shallow clone) fails; $tag_why says why.
tag_why=
on_default_branch() {
	odb_url=$1
	odb_commit=$2
	tag_why="it couldn't be checked against the remote's default branch"
	[ -n "$odb_url" ] || return 1
	odb_out=$(net_git ls-remote --symref "$odb_url" HEAD 2>/dev/null) || {
		tag_why="the remote's default branch couldn't be read from $odb_url (\`git ls-remote\` failed)"
		return 1
	}
	# Exactly one line for HEAD, with a full object name: the default branch's tip.
	odb_tips=$(printf '%s\n' "$odb_out" | awk -F'\t' '$2 == "HEAD" && $1 !~ /[^0-9a-f]/ && (length($1) == 40 || length($1) == 64) { print $1 }')
	if [ -z "$odb_tips" ] || [ "$(printf '%s\n' "$odb_tips" | wc -l | tr -d '[:space:]')" != 1 ]; then
		tag_why="the remote at $odb_url gave no single commit for its default branch"
		return 1
	fi
	if ! git cat-file -e "$odb_tips^{commit}" 2>/dev/null; then
		net_git fetch -q --no-tags "$odb_url" "$odb_tips" >/dev/null 2>&1 || true
		git cat-file -e "$odb_tips^{commit}" 2>/dev/null || {
			tag_why="the remote's default branch tip ($(printf '%.8s' "$odb_tips")) couldn't be fetched from $odb_url"
			return 1
		}
	fi
	git merge-base --is-ancestor "$odb_commit" "$odb_tips" 2>/dev/null || {
		tag_why="it isn't on the default branch of $odb_url"
		return 1
	}
}

# Every pushed ref's commit needs a pass or a waiver in the common directory's state (shared by the worktrees).
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || refuse "couldn't find the repository's review state."
state=$common/review-gate
while IFS=' ' read -r lref lsha rref rsha extra || [ -n "$lref$lsha$rref$rsha" ]; do
	# A full object name (SHA-1 or SHA-256) only: rev-parse would also take an abbreviation or a ref name.
	case ${#lsha}:$lsha in
	40:*[!0-9a-f]* | 64:*[!0-9a-f]*) refuse "unreadable ref line from git ('$lref $lsha $rref $rsha'), so it can't be checked." ;;
	40:* | 64:*) ;;
	*) refuse "unreadable ref line from git ('$lref $lsha $rref $rsha'), so it can't be checked." ;;
	esac
	if [ -z "$lref" ] || [ -z "$rref" ] || [ -z "$rsha" ] || [ -n "$extra" ]; then
		refuse "unreadable ref line from git ('$lref $lsha $rref $rsha'), so it can't be checked."
	fi
	# A delete sends no commit.
	[ -n "$(printf '%s' "$lsha" | tr -d 0)" ] || continue
	commit=$(git rev-parse --verify --quiet "$lsha^{commit}") || refuse "$(printf '%.8s' "$lsha") ($rref) is not a commit this repository has, so it has no review."
	short=$(git rev-parse --short "$commit" 2>/dev/null) || short=$(printf '%.8s' "$commit")
	# A tag is a release: it is pushed only when its commit is already on the remote's default branch, as the remote says now
	# (a squash merge never gets a local `.pass`, but it went through a PR with this gate, CI and Codex). A local `.pass` or
	# `.waived` doesn't count for it, or a reviewed feature commit could be released before it is merged.
	case $rref in
	refs/tags/*)
		if on_default_branch "${2:-}" "$commit"; then
			continue
		fi
		refuse "$short ($rref) can't be tagged yet: $tag_why. A tag is pushed only when its commit is already on the remote's default branch (merged through a PR), whatever its local review. Don't skip this check (\`--no-verify\`, \`core.hooksPath\`); if it is wrong, ask the user to push the tag."
		;;
	esac
	if [ -e "$state/$commit.pass" ] || [ -e "$state/$commit.waived" ]; then
		continue
	fi
	refuse "$short ($rref) has no passing review. Run a plain \`git push\` (or \`cd <dir> && git push\`) on its own so the review gate reviews HEAD first. Don't skip this check (\`--no-verify\`, \`core.hooksPath\`); if a review is wrong, ask the user to waive it."
done <"$saved"

run_own "$@"
