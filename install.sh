#!/bin/sh
# Deploys claude-ship's origin/main into ~/.claude: the gate, its prompts and the orchestrate hint (hooks/), the
# ship agents (agents/) and the ship skill (skills/ship/, with the action's codex-status.sh for local DRY_RUN
# checks), and a pinned shfmt in bin/ (scripts/fetch-shfmt.sh; a failure there makes the exit non-zero). Only main
# is deployed, so a branch's changes never go live; after fetching, this script runs main's copy of itself
# (docs/scripts.md). The gate's hook entry lives in ~/.claude/settings.json (see README.md): after deploying, this
# script reads that file (never writes it) and warns about a missing or outdated entry, and says when the PR
# loop's CLAUDE_CODE_FORK_SUBAGENT=0 setting is missing.
set -eu
repo=${CLAUDE_SHIP_REPO:-$(cd "$(dirname "$0")" && pwd)}
dest=${CLAUDE_HOME:-$HOME/.claude}
if [ -z "${CLAUDE_SHIP_REEXEC:-}" ]; then
	git -C "$repo" fetch -q origin main
	main=$(git -C "$repo" show origin/main:install.sh)
	CLAUDE_SHIP_REEXEC=1 CLAUDE_SHIP_REPO=$repo exec sh -c "$main" install.sh
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git -C "$repo" archive origin/main agents hooks skills scripts/codex-status.sh scripts/fetch-shfmt.sh | tar -x -C "$tmp"
mkdir -p "$dest/agents" "$dest/hooks" "$dest/skills"
# File by file: agents/ also holds the user's own agents.
cp "$tmp"/agents/ship-*.md "$dest/agents/"
cp "$tmp"/hooks/* "$dest/hooks/"
rm -rf "$dest/skills/ship"
cp -R "$tmp/skills/ship" "$dest/skills/ship"
cp "$tmp/scripts/codex-status.sh" "$dest/skills/ship/codex-status.sh"
echo "Deployed claude-ship $(git -C "$repo" rev-parse --short origin/main) to $dest."

# The gate's Bash checks will parse commands with shfmt (#135). main's fetch script installs a pinned release, checked
# against a pinned sha256 (docs/scripts.md). A failure doesn't stop the rest of the install; the exit status says it.
rc=0
mkdir -p "$dest/bin"
if ! sh "$tmp/scripts/fetch-shfmt.sh" "$dest/bin/shfmt"; then
	echo "install: couldn't install shfmt (see above); the review gate will need it." >&2
	rc=1
fi

# The first ```json block of origin/main's README.md that mentions $1: the registration the user copies.
snippet_of() {
	git -C "$repo" show origin/main:README.md | awk -v pat="$1" '
		/^```json/ { inblock = 1; block = ""; next }
		/^```/ { if (inblock && block ~ pat) { printf "%s", block; exit } inblock = 0; next }
		inblock { block = block $0 "\n" }
	'
}
# Reads (never writes) the settings and compares the gate's entry with README.md > Install. Returns 1 when the
# gate isn't registered at all or the check can't run; a registration that differs only warns.
check_settings() {
	settings=$dest/settings.json
	if ! command -v jq >/dev/null 2>&1; then
		echo "install: can't check $settings: jq not found (the gate needs it too)." >&2
		return 1
	fi
	snippet=$(snippet_of PreToolUse)
	hint=$(snippet_of UserPromptSubmit)
	want() { printf '%s' "$snippet" | jq -er "$1"; }
	if ! want_matcher=$(want '.hooks.PreToolUse[0].matcher | strings') ||
		! want_timeout=$(want '.hooks.PreToolUse[0].hooks[0].timeout | numbers') ||
		! want_failure=$(want '.hooks.PreToolUse[0].hooks[0].onFailure | strings') || [ -z "$hint" ]; then
		echo "install: bug: README.md on origin/main has no usable PreToolUse and UserPromptSubmit snippets." >&2
		return 1
	fi
	# shellcheck disable=SC2088 # the literal text README.md registers
	jqs() { jq --arg a '~/.claude/hooks/review-gate.sh' --arg b "$dest/hooks/review-gate.sh" "$@"; }
	hook='first(.hooks[] | select(type == "object" and (.command == $a or .command == $b)))'
	entry=$(jqs -c 'first(.hooks.PreToolUse[]? | select(type == "object" and any(.hooks[]?; type == "object" and (.command == $a or .command == $b))))' "$settings" 2>/dev/null) || entry=
	if [ -z "$entry" ]; then
		echo "install: the gate isn't registered in $settings (missing, not valid JSON, or no PreToolUse hook running ~/.claude/hooks/review-gate.sh), so it reviews nothing. Add this:" >&2
		printf '%s\n' "$snippet" >&2
		return 1
	fi
	warned=
	if ! printf '%s' "$entry" | jq -e --arg m "$want_matcher" '.matcher == $m' >/dev/null 2>&1; then
		echo "install: warning: the gate's matcher differs from README.md; use \"matcher\": \"$want_matcher\"." >&2
		warned=1
	fi
	if ! printf '%s' "$entry" | jqs -e --argjson w "$want_timeout" "$hook | .timeout | type == \"number\" and . >= \$w" >/dev/null 2>&1; then
		echo "install: warning: the gate's hook needs \"timeout\": $want_timeout (it must outlast the reviewer budget)." >&2
		warned=1
	fi
	if ! printf '%s' "$entry" | jqs -e --arg f "$want_failure" "$hook | .onFailure == \$f" >/dev/null 2>&1; then
		echo "install: warning: the gate's hook needs \"onFailure\": \"$want_failure\" (else a timeout lets the push through)." >&2
		warned=1
	fi
	if [ -n "$warned" ]; then
		echo "The entry from README.md:" >&2
		printf '%s\n' "$snippet" >&2
	else
		echo "The gate is registered in $settings."
	fi
	if ! jqs -e 'any(.hooks.UserPromptSubmit[]?.hooks[]?; type == "object" and (.command | tostring | test("orchestrate-hint[.]sh$")))' "$settings" >/dev/null 2>&1; then
		echo "install: info: orchestrated mode's hint hook isn't registered (optional). To use it, add:"
		printf '%s\n' "$hint"
	fi
	# Under Claude Code's fork mode a subagent's Agent call returns at once, so the PR loop's implementer never
	# gets ship-codex's report (claude-ship #160). Only the string "0" counts as set.
	if ! jqs -e '.env | type == "object" and .CLAUDE_CODE_FORK_SUBAGENT == "0"' "$settings" >/dev/null 2>&1; then
		echo "install: info: the PR loop needs \"env\": {\"CLAUDE_CODE_FORK_SUBAGENT\": \"0\"} in $settings (claude-ship #160); without it, nested agents run in the background."
	fi
}
check_settings || rc=1
[ "$rc" = 0 ] || exit "$rc"
