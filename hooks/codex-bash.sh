#!/bin/sh
# PreToolUse hook for the ship-codex agent (agents/ship-codex.md), for its Bash and Write. It runs a Codex round
# from PR text and Codex's findings, which can steer it, so each call is held to an exact list. Exit 0 with an
# allow decision approves the call for this agent (no permission prompt, no auto-mode classifier); exit 2 denies,
# and Claude Code shows the agent the reason on stderr. Anything it can't parse or tell denies (docs/scripts.md).
#
# Allowed, as one plain command (~ is the shell's, so the path is the installed one):
#   ~/.claude/skills/ship/codex-round.sh <pr> [owner/repo]
#   ~/.claude/skills/ship/codex-request.sh <pr> <owner/repo> <full sha>
#   [CODEX_WAIT_SECS=<n>] ~/.claude/skills/ship/codex-wait.sh <pr>
#   ~/.claude/skills/ship/codex-findings.sh <pr>
#   ~/.claude/skills/ship/codex-triage.sh <pr> <git common dir>/claude-ship/triage-<pr>.json
#   gh pr view <pr> ... | gh pr checks <pr> ...    without --web
# and a Write of <git common dir>/claude-ship/triage-<n>.json.
set -u

deny() {
	echo "ship-codex may only run ~/.claude/skills/ship/codex-round.sh <pr> [owner/repo], codex-request.sh <pr> <owner/repo> <sha>," \
		"[CODEX_WAIT_SECS=<n>] codex-wait.sh <pr>, codex-findings.sh <pr>, codex-triage.sh <pr> <claude-ship/triage-<pr>.json>," \
		"gh pr view|checks <pr> (no --web), as one plain command, and Write claude-ship/triage-<n>.json ($1)." >&2
	exit 2
}

allow() {
	printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
	exit 0
}

# isnum <word>: one to nine digits.
isnum() {
	case $1 in '' | *[!0-9]*) return 1 ;; esac
	[ "${#1}" -le 9 ]
}

# isslug <word>: owner/repo, each part starting with a letter, digit or _ (never an option), no "..".
isslug() {
	case $1 in '' | *[!A-Za-z0-9_./-]* | *..* | -* | */-* | /* | */ | */*/* | ./* | */.) return 1 ;; esac
	case $1 in */*) return 0 ;; esac
	return 1
}

# issha <word>: a full lowercase SHA-1, the form the PR's head is reported in.
issha() {
	case $1 in *[!0-9a-f]*) return 1 ;; esac
	[ "${#1}" -eq 40 ]
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

# The directory the plan and triage files live in: shared by every worktree of the repository.
triage_dir() {
	common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || deny "not in a git checkout"
	[ -n "$common" ] || deny "not in a git checkout"
	dir=$common/claude-ship
}

input=$(cat)
tool=$(printf '%s' "$input" | jq -er '.tool_name | select(type == "string")' 2>/dev/null) || deny "unreadable input"

case $tool in
Write)
	path=$(printf '%s' "$input" | jq -er '.tool_input.file_path | select(type == "string")' 2>/dev/null) || deny "unreadable input"
	triage_dir
	# Exactly <dir>/triage-<digits>.json: no "..", no other directory, no other name.
	rest=${path#"$dir"/triage-}
	[ "$rest" != "$path" ] || deny "Write to $path"
	num=${rest%.json}
	[ "$num.json" = "$rest" ] && isnum "$num" || deny "Write to $path"
	allow
	;;
Bash) ;;
*) deny "tool $tool" ;;
esac

# The command, from a string field only; malformed input, a missing field or a non-string denies.
cmd=$(printf '%s' "$input" | jq -er '.tool_input.command | select(type == "string")' 2>/dev/null) || deny "unreadable input"

# Only these characters: no quote, escape, expansion, redirect, list or glob character can reach the shell, so the
# words below are the words the command runs. (The ~ of the script path is the shell's home directory.)
case $cmd in
*[!A-Za-z0-9\ _./:=,@%+^~-]*) deny "characters outside letters, digits, space and _./:=,@%+^~-" ;;
esac

# Split on spaces (no glob characters are left to expand).
set -f
# shellcheck disable=SC2086
set -- $cmd
[ $# -ge 2 ] || deny "too short"

# The only environment: the wait's own cap, and only before the wait.
# shellcheck disable=SC2088 # the literal ~ is what the agent writes; the shell expands it
ship='~/.claude/skills/ship'
secs=
case $1 in
CODEX_WAIT_SECS=*)
	secs=${1#CODEX_WAIT_SECS=}
	isnum "$secs" || deny "CODEX_WAIT_SECS must be a number"
	shift
	[ $# -ge 2 ] || deny "too short"
	[ "$1" = "$ship/codex-wait.sh" ] || deny "CODEX_WAIT_SECS is for codex-wait.sh only"
	;;
esac
prog=$1
shift

case $prog in
"$ship/codex-round.sh")
	[ $# -ge 1 ] && [ $# -le 2 ] || deny "codex-round.sh takes <pr> [owner/repo]"
	isnum "$1" || deny "PR number $1"
	[ $# -lt 2 ] || isslug "$2" || deny "repository $2"
	;;
"$ship/codex-request.sh")
	[ $# -eq 3 ] || deny "codex-request.sh takes <pr> <owner/repo> <sha>"
	isnum "$1" || deny "PR number $1"
	isslug "$2" || deny "repository $2"
	issha "$3" || deny "sha $3"
	;;
"$ship/codex-wait.sh" | "$ship/codex-findings.sh")
	[ $# -eq 1 ] || deny "${prog##*/} takes <pr>"
	isnum "$1" || deny "PR number $1"
	;;
"$ship/codex-triage.sh")
	[ $# -eq 2 ] || deny "codex-triage.sh takes <pr> <triage file>"
	isnum "$1" || deny "PR number $1"
	triage_dir
	[ "$2" = "$dir/triage-$1.json" ] || deny "triage file $2"
	;;
gh)
	[ $# -ge 3 ] || deny "too short"
	case "$1 $2" in
	"pr view" | "pr checks") ;;
	*) deny "gh $1 $2" ;;
	esac
	shift 2
	isnum "$1" || deny "PR number $1"
	# Every word is checked, including those after a --, which can be an option's argument.
	for a in "$@"; do
		case $a in
		--*) exact "$a" --web && deny "gh option $a" ;;
		-*w*) deny "gh option $a" ;;
		esac
	done
	;;
*) deny "$prog" ;;
esac
allow
