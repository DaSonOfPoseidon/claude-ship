#!/bin/sh
# Source: github.com/DaSonOfPoseidon/claude-ship (hooks/), deployed into ~/.claude by its install.sh from main.
#
# UserPromptSubmit hook: in plan mode, in a GitHub repo where both CLAUDE_AUTONOMOUS and CLAUDE_ORCHESTRATE are
# `true`, it tells Claude to plan and run the work as the `ship` skill's orchestrated PR loop
# (skills/ship/orchestrate.md), so the user doesn't have to ask for it (claude-ship #66).
#   gh variable set CLAUDE_ORCHESTRATE --body true -R <owner/repo>
# It hints once per session and repo, and looks the variables up only until then.
#
# It's a convenience, not a protection: on any error it adds nothing and lets the prompt through. The review
# gate still reviews every push.
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
autonomous=$(gh variable get CLAUDE_AUTONOMOUS -R "$slug" 2>/dev/null) || autonomous=
orchestrate=$(gh variable get CLAUDE_ORCHESTRATE -R "$slug" 2>/dev/null) || orchestrate=
# Either variable may be missing (gh exits non-zero), which means off; remember the answer for the session.
mkdir -p "$marks" 2>/dev/null && : >"$mark" 2>/dev/null
[ "$autonomous" = true ] && [ "$orchestrate" = true ] || exit 0

jq -nc --arg repo "$slug" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: (
	"Orchestrated mode is on for " + $repo + " (CLAUDE_ORCHESTRATE). If this prompt is an objective to plan, "
	+ "read ~/.claude/skills/ship/orchestrate.md now, explore with the ship-explorer agent instead of Explore, "
	+ "and write the plan in its master-plan shape. Once the plan is approved, run the PR loop it describes.")}}'
