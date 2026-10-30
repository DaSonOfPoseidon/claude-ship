#!/bin/sh
# Source: github.com/DaSonOfPoseidon/claude-ship (hooks/), deployed into ~/.claude by its install.sh from main.
#
# UserPromptSubmit hook: in plan mode, in a GitHub repo where CLAUDE_AUTONOMOUS and CLAUDE_ORCHESTRATE are both
# `true`, it points Claude to the `ship` skill's orchestrated PR loop (skills/ship/orchestrate.md), once per
# session and repo (claude-ship #66; docs/scripts.md). On any error it adds nothing and lets the prompt through;
# a variable lookup that fails for any reason but "not found" (network, rate limit) isn't remembered either, so
# the next prompt asks again (claude-ship #67).
#
# A workspace (the git toplevel, else the cwd) whose AGENTS.md or CLAUDE.md has `- mode: local` in its `## PR loop`
# section gets the local loop's hint instead, with no repo variable and no `gh` (claude-ship #82). It reads only
# those two files, never runs anything from them, and puts only the directory in the hint.
set -u

input=$(cat)
mode=$(printf '%s' "$input" | jq -r '.permission_mode // ""' 2>/dev/null) || exit 0
[ "$mode" = plan ] || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
session=$(printf '%s' "$input" | jq -r '.session_id // ""')
# The session id names a file below, so it may hold only id characters.
printf '%s' "$session" | grep -Eq '^[A-Za-z0-9_-]+$' || exit 0
cd "$cwd" 2>/dev/null || exit 0
top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$(pwd) || exit 0

marks="${TMPDIR:-/tmp}/claude-ship-hint"
mark="$marks/$session-$(printf '%s' "$top" | cksum | cut -d' ' -f1)"
[ -e "$mark" ] && exit 0

# Succeeds when the file has `- mode: local` (backticks allowed) between the `## PR loop` heading and the next `## `
# heading. The scan is a state table; each state treats the other's markers as literal text (claude-ship #159):
#
#   state       | input line                                        | then
#   normal      | fence opener (3+ ` or ~ at the start)             | in a fence; the rest of the line is literal
#   normal      | `<!-- ... -->` complete, any number of times      | cut out of the line; the rest is read as normal
#   normal      | `<!--` with no `-->` after it                     | the text before it is read; in a comment
#   normal      | heading `## X`                                    | the section is live only if X is `PR loop`
#   normal      | `- mode: local`, in a live section                | found
#   in a fence  | a line of only the opener's character, as long    | normal
#   in a fence  | anything else (`<!--`, `-->`, headings, modes)    | literal, skipped
#   in a comment| a line holding `-->`                              | normal; the whole line is part of the comment
#   in a comment| anything else (fences, headings, modes)           | literal, skipped
has_local_mode() {
	[ -f "$1" ] || return 1
	[ "$(awk '
		function check(l) {
			if (l ~ /^ ? ? ?## /) { insec = (l ~ /^ ? ? ?## PR loop[ \t]*$/); return }
			if (insec && l ~ /^[ \t]*-[ \t]+mode:[ \t]*`?local`?[ \t]*$/) { found = 1; exit }
		}
		{
			sub(/\r$/, "")
			if (st == 1) {
				t = $0; gsub(/[ \t]/, "", t)
				if (t ~ /^(`+|~+)$/ && substr(t, 1, 1) == fch && length(t) >= flen) { st = 0 }
				next
			}
			if (st == 2) { if (index($0, "-->")) { st = 0 } next }
			if ($0 ~ /^[ \t]*(```|~~~)/) {
				t = $0; sub(/^[ \t]*/, "", t)
				fch = substr(t, 1, 1); flen = 0
				while (substr(t, flen + 1, 1) == fch) { flen++ }
				st = 1; next
			}
			line = $0
			while ((i = index(line, "<!--")) > 0) {
				rest = substr(line, i + 4)
				if ((j = index(rest, "-->")) > 0) { line = substr(line, 1, i - 1) substr(rest, j + 3) }
				else { line = substr(line, 1, i - 1); st = 2; break }
			}
			check(line)
		}
		END { print found ? "yes" : "no" }' "$1" 2>/dev/null)" = yes ]
}
if has_local_mode "$top/AGENTS.md" || has_local_mode "$top/CLAUDE.md"; then
	mkdir -p "$marks" 2>/dev/null && : >"$mark" 2>/dev/null
	jq -nc --arg dir "$top" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: (
		"Local orchestrated mode is on for " + $dir + " (## PR loop \u203a mode: local). If this prompt is an "
		+ "objective to plan, read ~/.claude/skills/ship/orchestrate.md \u203a Local mode now, explore with the "
		+ "ship-explorer agent instead of Explore, and write the plan in its master-plan shape. Once the plan is "
		+ "approved, run the local loop it describes: one unit at a time, no commits, PRs, gate or Codex.")}}'
	exit 0
fi
# Without the marker, a directory that isn't a git repo is not a workspace for the GitHub loop.
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

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
