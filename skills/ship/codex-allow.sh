#!/bin/sh
# Allows one more Codex review round on a PR, past the cap of 3. Only the user runs it, with `!` (the review gate
# denies Claude the command and writes under ~/.claude/claude-ship/): it counts the rounds the PR has used
# (codex-round.sh) and records that plus one as the PR's allowance, which codex-request.sh reads as its cap. Each run
# grants exactly one round beyond those already used; a missing or malformed file leaves the cap at 3.
# Usage: codex-allow.sh <pr> [owner/repo]   (the repository defaults to the one gh sees in the cwd)
# The allowance is in ${CLAUDE_HOME:-$HOME/.claude}/claude-ship/codex-allow/<owner>+<repo>-<pr> (lower case: GitHub names match without case).
set -eu
usage() {
	echo "usage: codex-allow.sh <pr> [owner/repo]" >&2
	exit 2
}
pr=${1:-}
case $pr in
'' | *[!0-9]*) usage ;;
esac
slug=${2:-}
if [ -z "$slug" ]; then
	slug=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
fi
# owner/repo: two non-empty parts of GitHub name characters, neither of them . or .. (the file name is built from it).
case $slug in
*[!A-Za-z0-9._/-]* | /* | */ | */*/* | ./* | ../* | */. | */.. | '') usage ;;
*/*) ;;
*) usage ;;
esac
if [ -z "${CLAUDE_HOME:-}${HOME:-}" ]; then
	echo "codex-allow: neither CLAUDE_HOME nor HOME is set" >&2
	exit 1
fi
here=$(cd "$(dirname "$0")" && pwd)
# A failed count writes nothing: the allowance is built on how many rounds are used.
if ! rounds=$("$here/codex-round.sh" "$pr" "$slug"); then
	echo "codex-allow: couldn't count the rounds of $slug#$pr; nothing allowed" >&2
	exit 1
fi
case $rounds in
'' | *[!0-9]*)
	echo "codex-allow: codex-round.sh printed '$rounds', not a number; nothing allowed" >&2
	exit 1
	;;
esac
cap=$((rounds + 1))
dir=${CLAUDE_HOME:-${HOME:-}/.claude}/claude-ship/codex-allow
file=$dir/$(printf '%s' "$slug" | tr '[:upper:]/' '[:lower:]+')-$pr
mkdir -p "$dir"
# Written beside the file and moved into place, so codex-request.sh never reads half of it.
tmp=$(mktemp "$dir/.allow.XXXXXX")
trap 'rm -f "$tmp"' EXIT
echo "$cap" >"$tmp"
mv "$tmp" "$file"
echo "Allowed one more Codex round on $slug#$pr (cap $cap)."
