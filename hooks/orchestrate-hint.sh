#!/bin/sh
# Source: github.com/DaSonOfPoseidon/claude-ship (hooks/), deployed into ~/.claude by its install.sh from main.
#
# UserPromptSubmit hook: in plan mode, in a GitHub repo where CLAUDE_AUTONOMOUS and CLAUDE_ORCHESTRATE are both
# `true`, it points Claude to the `ship` skill's orchestrated PR loop (skills/ship/orchestrate.md), once per
# session and repo (claude-ship #66; docs/scripts.md). On any error it adds nothing and lets the prompt through;
# a variable lookup that fails for any reason but "not found" (network, rate limit) isn't remembered either, so
# the next prompt asks again (claude-ship #67).
set -u

input=$(cat)
mode=$(printf '%s' "$input" | jq -r '.permission_mode // ""' 2>/dev/null) || exit 0
[ "$mode" = plan ] || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
session=$(printf '%s' "$input" | jq -r '.session_id // ""')
# The session id names a file below, so it may hold only id characters.
printf '%s' "$session" | grep -Eq '^[A-Za-z0-9_-]+$' || exit 0
cd "$cwd" 2>/dev/null || exit 0
top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

marks="${TMPDIR:-/tmp}/claude-ship-hint"
mark="$marks/$session-$(printf '%s' "$top" | cksum | cut -d' ' -f1)"
[ -e "$mark" ] && exit 0

slug=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || exit 0
[ -n "$slug" ] || exit 0
# Prints a variable's value, nothing if it is not set; fails if GitHub can't say (same split as the gate's).
lookup() {
	if out=$(gh variable get "$1" -R "$slug" 2>&1); then
		printf '%s' "$out"
		return 0
	fi
	case $out in
	*'not found'* | *'Not Found'*) return 0 ;;
	*) return 1 ;;
	esac
}
autonomous=$(lookup CLAUDE_AUTONOMOUS) || exit 0
orchestrate=$(lookup CLAUDE_ORCHESTRATE) || exit 0
# A missing variable means off, and so does a value; remember the answer for the session.
mkdir -p "$marks" 2>/dev/null && : >"$mark" 2>/dev/null
[ "$autonomous" = true ] && [ "$orchestrate" = true ] || exit 0

jq -nc --arg repo "$slug" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: (
	"Orchestrated mode is on for " + $repo + " (CLAUDE_ORCHESTRATE). If this prompt is an objective to plan, "
	+ "read ~/.claude/skills/ship/orchestrate.md now, explore with the ship-explorer agent instead of Explore, "
	+ "and write the plan in its master-plan shape. Once the plan is approved, run the PR loop it describes.")}}'
