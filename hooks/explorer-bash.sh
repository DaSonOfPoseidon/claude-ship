#!/bin/sh
# PreToolUse hook for the ship-explorer agent (agents/ship-explorer.md): it reads issue and PR text, which can
# steer it, so its Bash is limited to read-only git and gh. Exit 0 allows; exit 2 denies, and Claude Code shows
# the agent the reason on stderr. Anything it can't parse or tell denies (docs/scripts.md has the reasons).
#
# Allowed, as one simple command:
#   git log|show|diff|grep|ls-files|blame ...     without options that write, run a program or leave the repo
#   gh issue view|pr view|pr diff ...             without --web
#   gh api <path> ...                             without a body, a method, or a GraphQL mutation
set -u

deny() {
	echo "ship-explorer Bash is read-only: only git log|show|diff|grep|ls-files|blame, gh issue view, gh pr view," \
		"gh pr diff and gh api <path> (no -f, -F, -X, --input), as one plain command ($1). Use Read, Grep and Glob for files." >&2
	exit 2
}

# The command, from a string field only; malformed input, a missing field or a non-string denies.
cmd=$(jq -er '.tool_input.command | select(type == "string")' 2>/dev/null) || deny "unreadable input"

# Only these characters: no quote, escape, expansion, redirect, list or glob character can reach the shell, so the
# words below are the words the command runs. A quoted form like --grep="a b" is refused with the rest.
case $cmd in
*[!A-Za-z0-9\ _./:=,@%+^~-]*) deny "characters outside letters, digits, space and _./:=,@%+^~-" ;;
esac

# Split on spaces (no glob characters are left to expand).
set -f
# shellcheck disable=SC2086
set -- $cmd
[ $# -ge 2 ] || deny "too short"
prog=$1
shift

# hit <name> <option>...: succeeds when a long option name (the part before any =) is, or abbreviates, or extends
# one of the options. git accepts any unambiguous abbreviation of a long option, so --out is --output.
hit() {
	name=${1%%=*}
	shift
	for opt; do
		case $opt in "$name"*) return 0 ;; esac
		case $name in "$opt"*) return 0 ;; esac
	done
	return 1
}

# exact <name> <option>...: succeeds when the option's name (before any =) is exactly one of them (gh's flags
# can't be abbreviated).
exact() {
	name=${1%%=*}
	shift
	for opt; do
		[ "$name" = "$opt" ] && return 0
	done
	return 1
}

case $prog in
git)
	# The subcommand comes first: -c, -C, --git-dir and --work-tree before it change what it runs.
	case $1 in
	log | show | diff | grep | ls-files | blame) shift ;;
	*) deny "git $1" ;;
	esac
	for a in "$@"; do
		case $a in
		# A bare -- is not trusted to end the options (it can be -e's pattern), so every word after it is checked too.
		--) ;;
		--*) hit "$a" --output --ext-diff --textconv --no-index --open-files-in-pager && deny "git option $a" ;;
		# A cluster of short options: -o and -O write a file or open a pager, and may be bundled (-nO).
		-*[oO]*) deny "git option $a" ;;
		esac
	done
	;;
gh)
	case $1 in
	issue | pr)
		sub=$1
		case "$sub ${2:-}" in
		"issue view" | "pr view" | "pr diff") ;;
		*) deny "gh $sub ${2:-}" ;;
		esac
		shift 2
		for a in "$@"; do
			case $a in
			--*) exact "$a" --web && deny "gh option $a" ;;
			-*w*) deny "gh option $a" ;;
			esac
		done
		;;
	api)
		shift
		[ $# -ge 1 ] || deny "gh api needs a path"
		for a in "$@"; do
			case $a in
			--*) exact "$a" --field --raw-field --method --input && deny "gh option $a" ;;
			# A cluster of short options: -f, -F and -X add a body or a method, and may be bundled (-XPOST).
			-*[fFX]*) deny "gh option $a" ;;
			esac
		done
		# A GraphQL mutation, in any case, anywhere in the command (the characters it needs are denied above).
		case $cmd in *[Mm][Uu][Tt][Aa][Tt][Ii][Oo][Nn]*) deny "gh api mutation" ;; esac
		;;
	*) deny "gh $1" ;;
	esac
	;;
*) deny "$prog" ;;
esac
exit 0
