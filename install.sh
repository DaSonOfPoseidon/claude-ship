#!/bin/sh
# Deploys claude-ship's origin/main into ~/.claude: the gate, its prompts and the orchestrate hint (hooks/), the
# ship agents (agents/) and the ship skill (skills/ship/, with the action's codex-status.sh for local DRY_RUN
# checks), a pinned shfmt in bin/ (scripts/fetch-shfmt.sh, run first: a gate without shfmt blocks every Bash call, so a
# failure there stops the install before anything is changed, #189), and the git hook
# stubs in git-hooks/, which it points git's global core.hooksPath at when that is unset (any other value makes the exit
# non-zero; docs/gate.md › Pre-push check). Only main
# is deployed, so a branch's changes never go live; after fetching, this script runs main's copy of itself
# (docs/scripts.md). It also registers the gate in a managed-settings drop-in (settings/claude-ship.json, copied to
# ${CLAUDE_SHIP_MANAGED_DIR:-/etc/claude-code}/managed-settings.d/ when that is writable, i.e. as root), which user and
# project settings can't turn off, and sets the immutable flag (chattr +i) on everything it deploys, lifting it first on a
# reinstall; only the user lifts it otherwise. The gate's hook entry may also live in ~/.claude/settings.json (see README.md): after
# deploying, this script reads that file (never writes it) and warns about a missing or outdated entry (the drop-in
# counts as a registration), and says when the PR loop's CLAUDE_CODE_FORK_SUBAGENT=0 setting is missing. It also fails (exit 1) when a hook named in a ship agent's
# frontmatter was not deployed or is not executable (#122).
set -eu
repo=${CLAUDE_SHIP_REPO:-$(cd "$(dirname "$0")" && pwd)}
dest=${CLAUDE_HOME:-$HOME/.claude}
managed=${CLAUDE_SHIP_MANAGED_DIR:-/etc/claude-code}
managed_dropin=$managed/managed-settings.d/claude-ship.json
managed_ok=
if [ -z "${CLAUDE_SHIP_REEXEC:-}" ]; then
	git -C "$repo" fetch -q origin main
	main=$(git -C "$repo" show origin/main:install.sh)
	CLAUDE_SHIP_REEXEC=1 CLAUDE_SHIP_REPO=$repo exec sh -c "$main" install.sh
fi
tmp=$(mktemp -d)
have_chattr=
# However the script ends, the flags it lifted go back (the ones recorded in $tmp/was-flagged, before the first lift): a
# write that fails half way (a full disk) must not leave the gate's files unlocked, the ones it never got to included.
cleanup() {
	if [ -n "$have_chattr" ] && [ -f "$tmp/was-flagged" ]; then
		while IFS= read -r f; do
			if [ -e "$f" ]; then chattr +i "$f" 2>/dev/null || :; fi
		done <"$tmp/was-flagged"
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT
# A shell killed by a signal doesn't run its EXIT trap: these go through exit, so the flags go back after a Ctrl-C or a kill too.
trap 'exit 1' HUP INT TERM
# Under sudo $HOME may be root's, which would put the gate where the user's Claude Code doesn't look.
if [ -n "${SUDO_USER:-}" ]; then
	echo "install: note: running under sudo; installing into $dest. If that isn't the ~/.claude Claude Code runs from, run again with sudo --preserve-env=HOME or set CLAUDE_HOME."
fi

# The immutable flag (docs/gate.md › Tamper protection): once installed, the gate's files are flagged with chattr +i, so no
# command Claude runs can change them, whatever it's spelled like; only the user lifts the flag (`! sudo chattr -i PATH`), and
# so does this script, before it writes and again after. chattr and lsattr are Linux's (e2fsprogs) and the only tools here
# that aren't POSIX; without them, or without root or a filesystem that has the flag, the install still works and says
# what isn't locked. lock_list prints what is locked, one path per line after its kind: "r" is a tree (locked recursively),
# "1" just that path (the managed dir holds other policy files, which are not ours to lock or unlock). Paths with a
# newline in them are not supported.
lock_list() {
	for f in "$tmp"/hooks/*; do printf '1 %s\n' "$dest/hooks/${f##*/}"; done
	printf 'r %s\n' "$dest/skills/ship"
	for f in "$tmp"/agents/ship-*.md; do printf '1 %s\n' "$dest/agents/${f##*/}"; done
	printf '1 %s\n' "$dest/bin/shfmt"
	printf 'r %s\n' "$dest/git-hooks"
	# $1 set: the managed paths too (they are lifted whether or not this run writes them, locked only when it did).
	if [ -n "$1" ]; then printf '1 %s\n' "$managed_dropin" "$managed/managed-settings.d" "$managed"; fi
}
# Whether lsattr shows the immutable flag on $1.
is_flagged() {
	attrs=$(lsattr -d "$1" 2>/dev/null) || return 1
	case ${attrs%% *} in *i*) return 0 ;; *) return 1 ;; esac
}
# The paths of lock_list (trees walked) that have the immutable flag ($1 = flagged) or lack it ($1 = loose), one per line; $2 as
# for lock_list.
flag_report() {
	lock_list "$2" | while read -r kind p; do
		[ -e "$p" ] || continue
		if [ "$kind" = r ]; then find "$p"; else printf '%s\n' "$p"; fi
	done | while IFS= read -r f; do
		if is_flagged "$f"; then state=flagged; else state=loose; fi
		if [ "$state" = "$1" ]; then printf '%s\n' "$f"; fi
	done
}
git -C "$repo" archive origin/main agents hooks skills settings/claude-ship.json scripts/codex-status.sh scripts/fetch-shfmt.sh | tar -x -C "$tmp"
# shfmt first, into a temp file and run once, before anything installed is touched (#189): the gate blocks every Bash call
# without a working shfmt, so a failed fetch must not leave a new gate next to a missing one. An installed shfmt is the
# starting file, so the fetch script's "already current" check still saves the download.
if [ -f "$dest/bin/shfmt" ]; then cp "$dest/bin/shfmt" "$tmp/shfmt" 2>/dev/null || :; fi
if ! sh "$tmp/scripts/fetch-shfmt.sh" "$tmp/shfmt" || ! "$tmp/shfmt" --version >/dev/null 2>&1; then
	echo "install: couldn't install shfmt (see above); the review gate needs it, so nothing was installed." >&2
	exit 1
fi
# The managed-settings drop-in (settings/claude-ship.json), validated before anything is changed or written: Claude Code
# doesn't start with a managed file that isn't valid JSON, so only a file that passed this is ever copied into the managed dir.
if ! command -v jq >/dev/null 2>&1; then
	echo "install: jq not found (the gate needs it, and it validates settings/claude-ship.json); nothing was installed." >&2
	exit 1
fi
# -s: exactly one JSON value (an empty file makes jq run nothing and still succeed).
if ! jq -es 'length == 1 and (.[0] | (.hooks | keys) == ["PreToolUse"] and (.hooks.PreToolUse | type == "array" and length > 0) and all(.hooks.PreToolUse[];
	(.matcher | type == "string") and (.hooks | type == "array" and length > 0) and all(.hooks[]; .type == "command" and (.command | type == "string")
		and (.timeout | type == "number") and .onFailure == "block")))' "$tmp/settings/claude-ship.json" >/dev/null 2>&1; then
	echo "install: settings/claude-ship.json on origin/main isn't a valid managed-settings drop-in (a bug there); nothing was installed." >&2
	exit 1
fi
# Lift the flags on everything this script is about to write (also the rm -rf of skills/ship below), and check that it
# worked: a flag that can't be lifted (not root) must stop the install before the first write, not half way through it.
if command -v chattr >/dev/null 2>&1 && command -v lsattr >/dev/null 2>&1; then have_chattr=1; fi
if [ -n "$have_chattr" ]; then
	flag_report flagged 1 >"$tmp/was-flagged"
	lock_list 1 | while read -r kind p; do
		[ -e "$p" ] || continue
		if [ "$kind" = r ]; then chattr -R -i "$p" 2>/dev/null || :; else chattr -i "$p" 2>/dev/null || :; fi
	done
	stuck=$(flag_report flagged 1)
	if [ -n "$stuck" ]; then
		echo "install: still immutable, and chattr -i couldn't lift it (it needs root; run install.sh as root, or lift it yourself with \`! sudo chattr -i <path>\`): $(printf '%s\n' "$stuck" | head -n 3 | tr '\n' ' ')" >&2
		echo "install: nothing was installed." >&2
		exit 1
	fi
fi
# The directories this run creates for the user's own files (agents/ and skills/ hold their own agents and skills): as root
# under sudo they would be root's, so they go to the sudo user. hooks/, bin/ and git-hooks/ are locked and stay root's.
: >"$tmp/new-dirs"
for d in "$dest" "$dest/agents" "$dest/skills"; do
	if [ ! -d "$d" ]; then printf '%s\n' "$d" >>"$tmp/new-dirs"; fi
done
mkdir -p "$dest/agents" "$dest/hooks" "$dest/skills" "$dest/bin"
if [ -n "${SUDO_USER:-}" ] && [ "$(id -u)" = 0 ]; then
	while IFS= read -r d; do chown "$SUDO_USER" "$d" || :; done <"$tmp/new-dirs"
fi
# File by file: agents/ also holds the user's own agents.
cp "$tmp"/agents/ship-*.md "$dest/agents/"
cp "$tmp"/hooks/* "$dest/hooks/"
rm -rf "$dest/skills/ship"
cp -R "$tmp/skills/ship" "$dest/skills/ship"
cp "$tmp/scripts/codex-status.sh" "$dest/skills/ship/codex-status.sh"
# The gate reads every Bash command with shfmt (#135). Copied beside its place and moved in, so it is never half-written.
cp "$tmp/shfmt" "$dest/bin/.shfmt.new"
chmod 755 "$dest/bin/.shfmt.new"
mv -f "$dest/bin/.shfmt.new" "$dest/bin/shfmt"
echo "Deployed claude-ship $(git -C "$repo" rev-parse --short origin/main) to $dest."

rc=0

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

# The gate's registration in managed settings (docs/gate.md › Tamper protection): Claude Code reads every
# managed-settings.d/*.json in the managed directory, and user and project settings can't override or disable what it sets.
# Copied beside its place and moved in, so Claude Code never reads half a file. Without write access (not root) the gate
# stays registered in user settings only (README.md › Install).
if mkdir -p "$managed/managed-settings.d" 2>/dev/null &&
	cp "$tmp/settings/claude-ship.json" "$managed/managed-settings.d/.claude-ship.json.new" 2>/dev/null &&
	chmod 644 "$managed/managed-settings.d/.claude-ship.json.new" &&
	mv -f "$managed/managed-settings.d/.claude-ship.json.new" "$managed_dropin"; then
	managed_ok=1
	echo "Registered the gate in the managed settings drop-in $managed_dropin."
else
	rm -f "$managed/managed-settings.d/.claude-ship.json.new" 2>/dev/null || :
	echo "install: couldn't write $managed (run install.sh as root for that), so the gate stays registered in user settings only (README.md › Install)."
fi

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
	# Info lines about the rest of the settings (optional pieces: they never change the exit status).
	extra_info() {
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
	# Every hook that runs the gate, with its entry's matcher: Claude Code runs all of them, so each is judged (#153).
	gates=$(jqs -c '[.hooks.PreToolUse[]? | select(type == "object") | . as $e | $e.hooks[]? | select(type == "object" and (.command == $a or .command == $b)) | {matcher: $e.matcher, timeout, onFailure}]' "$settings" 2>/dev/null) || gates=
	count=$(printf '%s' "$gates" | jq -r 'length' 2>/dev/null) || count=0
	count=${count:-0}
	if [ "$count" = 0 ] && [ -n "$managed_ok" ]; then
		echo "The gate is registered in the managed settings drop-in $managed_dropin (not in $settings)."
		echo "install: info: restart Claude Code, then check that /status lists \"Enterprise managed settings (drop-ins)\"; if it doesn't, add the README's entry to $settings."
		extra_info
		return 0
	fi
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
	if [ -n "$managed_ok" ]; then
		echo "install: info: the gate is also registered in the managed drop-in $managed_dropin; Claude Code runs a handler that appears in both once. Once /status lists \"Enterprise managed settings (drop-ins)\", you can remove the gate's entry from $settings."
	fi
	extra_info
}
# Everything written, flag it, then check with lsattr. The managed paths are flagged when the drop-in was written (or was
# there already, so that a flag lifted above is never left off).
lock_managed=$managed_ok
if [ -z "$lock_managed" ] && [ -f "$managed_dropin" ]; then lock_managed=1; fi
if [ -z "$have_chattr" ]; then
	echo "install: warning: chattr or lsattr not found (they are Linux's), so the installed gate isn't locked against edits." >&2
else
	lock_list "$lock_managed" | while read -r kind p; do
		[ -e "$p" ] || continue
		if [ "$kind" = r ]; then chattr -R +i "$p" 2>/dev/null || :; else chattr +i "$p" 2>/dev/null || :; fi
	done
	loose=$(flag_report loose "$lock_managed" | head -n 20 | tr '\n' ' ')
	if [ -z "$loose" ]; then
		echo "Set the immutable flag on the installed gate; to change a file by hand, lift it first: ! sudo chattr -i <path>."
	else
		echo "install: warning: not immutable, so a command Claude runs could still change it (chattr +i needs root and a filesystem that supports it): $loose" >&2
		# As root there is no excuse: that is a gate that isn't locked.
		if [ "$(id -u)" = 0 ]; then rc=1; fi
	fi
fi

check_settings || rc=1
[ "$rc" = 0 ] || exit "$rc"
