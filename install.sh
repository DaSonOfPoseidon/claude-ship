#!/bin/sh
# Deploys claude-ship's origin/main into ~/.claude: the gate, its prompts and the orchestrate hint (hooks/), the
# ship agents (agents/) and the ship skill (skills/ship/, with the action's codex-status.sh for local DRY_RUN
# checks), a pinned shfmt in bin/ (scripts/fetch-shfmt.sh; a failure there makes the exit non-zero), and the git hook
# stubs in git-hooks/, which it points git's global core.hooksPath at when that is unset (any other value makes the exit
# non-zero; docs/gate.md › Pre-push check). Only main
# is deployed, so a branch's changes never go live; after fetching, this script runs main's copy of itself
# (docs/scripts.md). The gate's hook entry lives in ~/.claude/settings.json (see README.md): after deploying, this
# script reads that file (never writes it) and warns about a missing or outdated entry, and says when the PR
# loop's CLAUDE_CODE_FORK_SUBAGENT=0 setting is missing. It also fails (exit 1) when a hook named in a ship agent's
# frontmatter was not deployed or is not executable (#122).
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

# The git hook stubs (docs/gate.md › Pre-push check): core.hooksPath points git at $dest/git-hooks, where each stub runs
# hooks/git-hook.sh with its own name, so a pre-push check refuses Claude's unreviewed pushes and the repo's own hooks still
# run (git stops reading a repo's .git/hooks once core.hooksPath is set). One stub for every hook git 2.34 runs from the hooks
# directory (`git help hooks`) except push-to-checkout, proc-receive and fsmonitor-watchman, whose presence alone changes what
# git does. The gate wants exactly "$dest/git-hooks" as the value, so $dest must be an absolute path.
case $dest in
/*"'"* | [!/]* | "")
	echo "install: can't write git hook stubs: $dest must be an absolute path without a single quote." >&2
	rc=1
	;;
*)
	mkdir -p "$dest/git-hooks"
	for h in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg \
		post-commit pre-rebase post-checkout post-merge pre-push pre-receive update post-receive post-update \
		reference-transaction pre-auto-gc post-rewrite sendemail-validate p4-changelist p4-prepare-changelist \
		p4-post-changelist p4-pre-submit post-index-change; do
		printf '#!/bin/sh\nexec sh '"'%s'"' %s "$@"\n' "$dest/hooks/git-hook.sh" "$h" >"$dest/git-hooks/$h"
		chmod 755 "$dest/git-hooks/$h"
	done
	# core.hooksPath is the user's too: set it only when it is unset, and leave any other value alone.
	hooks_path=
	hooks_st=0
	hooks_path=$(git config --global --get core.hooksPath 2>/dev/null) || hooks_st=$?
	if [ "$hooks_st" = 1 ]; then
		git config --global core.hooksPath "$dest/git-hooks" || hooks_st=2
		[ "$hooks_st" = 2 ] || hooks_path=$dest/git-hooks
	fi
	if [ "$hooks_st" != 0 ] && [ "$hooks_st" != 1 ]; then
		echo "install: couldn't read or set git's global core.hooksPath; the review gate's pre-push check is off, and the gate blocks pushes until it is $dest/git-hooks." >&2
		rc=1
	elif [ "$hooks_path" != "$dest/git-hooks" ]; then
		echo "install: git's core.hooksPath is $hooks_path, not $dest/git-hooks, so the review gate's pre-push check is off and the gate blocks pushes. Point it at ours (or unset it) and run this again." >&2
		rc=1
	else
		echo "Git now runs repos' own hooks through the stubs in $dest/git-hooks (core.hooksPath), which add the review gate's pre-push check."
	fi
	;;
esac

# Each deployed ship agent's frontmatter hooks (ship-explorer's explorer-bash.sh, ship-codex's codex-bash.sh) are what
# keep its Bash in bounds. A hook that is missing or not executable fails with a non-blocking error, so the agent's
# Bash would run unrestricted (#122): check every hook a ship agent's frontmatter names.
for agent in "$tmp"/agents/ship-*.md; do
	name=${agent##*/}
	name=${name%.md}
	awk '/^---[ \t]*$/ { n++; next } n == 1 && /^[ \t]*(-[ \t]+)?command:/ { sub(/^[^:]*:[ \t]*/, ""); gsub(/["'"'"']/, ""); sub(/[ \t]+$/, ""); print }' "$agent" | while read -r hook; do
		# shellcheck disable=SC2088 # the literal text the frontmatter holds
		case $hook in
		"~/.claude/"*) file=$dest/${hook#"~/.claude/"} ;;
		*) file=$hook ;;
		esac
		[ -x "$file" ] && [ -f "$file" ] || echo "install: $name names $hook, which isn't deployed or isn't executable; its Bash runs unrestricted" >&2
	done
done >"$tmp/agent-hooks.err" 2>&1
if [ -s "$tmp/agent-hooks.err" ]; then
	cat "$tmp/agent-hooks.err" >&2
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
	# Every hook that runs the gate, with its entry's matcher: Claude Code runs all of them, so each is judged (#153).
	gates=$(jqs -c '[.hooks.PreToolUse[]? | select(type == "object") | . as $e | $e.hooks[]? | select(type == "object" and (.command == $a or .command == $b)) | {matcher: $e.matcher, timeout, onFailure}]' "$settings" 2>/dev/null) || gates=
	count=$(printf '%s' "$gates" | jq -r 'length' 2>/dev/null) || count=0
	count=${count:-0}
	if [ "$count" = 0 ]; then
		echo "install: the gate isn't registered in $settings (missing, not valid JSON, or no PreToolUse hook running ~/.claude/hooks/review-gate.sh), so it reviews nothing. Add this:" >&2
		printf '%s\n' "$snippet" >&2
		return 1
	fi
	warned=
	if [ "$count" -gt 1 ]; then
		echo "install: warning: the gate is registered $count times in $settings; keep only the README entry (Claude Code runs every one, so a stale one still runs with its weaker settings)." >&2
		warned=1
	fi
	# One line per gate hook: whether its matcher, timeout and onFailure are right.
	verdicts=$(printf '%s' "$gates" | jq -r --arg m "$want_matcher" --argjson w "$want_timeout" --arg f "$want_failure" '.[] | [.matcher == $m, ((.timeout | type) == "number" and .timeout >= $w), .onFailure == $f] | map(tostring) | join(" ")')
	i=0
	while read -r ok_matcher ok_timeout ok_failure; do
		i=$((i + 1))
		case $i in
		1) ord=1st ;;
		2) ord=2nd ;;
		3) ord=3rd ;;
		*) ord=${i}th ;;
		esac
		if [ "$count" -gt 1 ]; then g="the $ord gate registration's"; else g="the gate's"; fi
		if [ "$ok_matcher" != true ]; then
			echo "install: warning: $g matcher differs from README.md; use \"matcher\": \"$want_matcher\"." >&2
			warned=1
		fi
		if [ "$ok_timeout" != true ]; then
			echo "install: warning: $g hook needs \"timeout\": $want_timeout (it must outlast the reviewer budget)." >&2
			warned=1
		fi
		if [ "$ok_failure" != true ]; then
			echo "install: warning: $g hook needs \"onFailure\": \"$want_failure\" (else a timeout lets the push through)." >&2
			warned=1
		fi
	done <<VERDICTS
$verdicts
VERDICTS
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
