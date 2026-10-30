#!/bin/sh
# Tests that install.sh runs origin/main's installer, not the checkout's: a checkout one commit behind a main
# whose installer deploys one more file still deploys it (claude-ship #20); and that it checks, read-only, that
# the Claude settings file registers the gate like README.md › Install says (claude-ship #109).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/src/scripts"
git() { command git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
fail=0

# The README's registration snippets, so the fixtures below can't drift from it.
snippet_of() {
	awk -v pat="$1" '
		/^```json/ { inblock = 1; block = ""; next }
		/^```/ { if (inblock && block ~ pat) { printf "%s", block; exit } inblock = 0; next }
		inblock { block = block $0 "\n" }
	' "$root/README.md"
}
gate=$(snippet_of PreToolUse)
hint=$(snippet_of UserPromptSubmit)
if [ -z "$gate" ] || [ -z "$hint" ]; then
	echo "FAIL: README.md lacks the PreToolUse or UserPromptSubmit snippet"
	exit 1
fi
both=$(printf '%s\n%s\n' "$gate" "$hint" | jq -s '.[0] * .[1]')

# main: this tree's installer, then a commit whose installer also deploys a marker file.
cp -R "$root/agents" "$root/hooks" "$root/skills" "$root/install.sh" "$root/README.md" "$tmp/src/"
cp "$root/scripts/codex-status.sh" "$tmp/src/scripts/"
git init -q "$tmp/src"
git -C "$tmp/src" add -A
git -C "$tmp/src" commit -qm old
printf ': >"$dest/main-installer-ran"\n' >>"$tmp/src/install.sh"
git -C "$tmp/src" commit -qam new
git clone -q --bare "$tmp/src" "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/checkout"
git -C "$tmp/checkout" reset -q --hard HEAD~1

# The user's own agents stay.
mkdir -p "$tmp/dest/agents"
: >"$tmp/dest/agents/mine.md"
printf '%s\n' "$both" >"$tmp/dest/settings.json"
cp "$tmp/dest/settings.json" "$tmp/settings.before"
if ! CLAUDE_HOME="$tmp/dest" sh "$tmp/checkout/install.sh" >"$tmp/out" 2>&1; then
	echo "FAIL: install.sh exited non-zero"
	sed 's/^/  /' "$tmp/out"
	fail=1
fi
for f in main-installer-ran hooks/review-gate.sh hooks/review-lib.sh hooks/orchestrate-hint.sh skills/ship/SKILL.md \
	skills/ship/orchestrate.md skills/ship/codex-status.sh agents/ship-explorer.md agents/ship-implementer.md \
	agents/ship-codex.md hooks/codex-bash.sh agents/mine.md; do
	[ -e "$tmp/dest/$f" ] || {
		echo "FAIL: $f wasn't deployed"
		fail=1
	}
done
# Hooks and skill scripts are registered or run as commands, so every deployed script is executable.
for f in "$tmp"/dest/hooks/*.sh "$tmp"/dest/skills/ship/*.sh; do
	[ -x "$f" ] || {
		echo "FAIL: ${f#"$tmp"/dest/} isn't executable"
		fail=1
	}
done
# A valid registration: nothing to warn about, and install.sh never touches the settings.
cmp -s "$tmp/settings.before" "$tmp/dest/settings.json" || {
	echo "FAIL: install.sh changed the settings file"
	fail=1
}
grep -qi 'warning' "$tmp/out" && {
	echo "FAIL: a valid registration got a warning"
	sed 's/^/  /' "$tmp/out"
	fail=1
}
# What's deployed is main's, not the checkout's.
grep -q "Deployed claude-ship $(git -C "$tmp/src" rev-parse --short HEAD)" "$tmp/out" || {
	echo "FAIL: didn't deploy main's commit"
	sed 's/^/  /' "$tmp/out"
	fail=1
}

# One case per row of install.sh's registration check. $start is the settings file to begin from (absent: none).
# run_case <name> runs the installer and leaves its exit status in $rc and its output in $tmp/out. The settings
# file must come out byte-identical, and the files are deployed whatever the check says.
start="$tmp/start.json"
run_case() {
	cdir="$tmp/case-$1"
	rm -rf "$cdir"
	mkdir -p "$cdir"
	[ -f "$start" ] && cp "$start" "$cdir/settings.json"
	CLAUDE_HOME=$cdir PATH=$case_path "$sh_bin" "$tmp/checkout/install.sh" >"$tmp/out" 2>&1
	rc=$?
	if [ -f "$start" ]; then
		cmp -s "$start" "$cdir/settings.json" || {
			echo "FAIL: $1: the settings file changed"
			fail=1
		}
	elif [ -e "$cdir/settings.json" ]; then
		echo "FAIL: $1: install.sh created the settings file"
		fail=1
	fi
	[ -x "$cdir/hooks/review-gate.sh" ] || {
		echo "FAIL: $1: the gate wasn't deployed"
		fail=1
	}
}
# expect <name> <exit> [<warnings>]: the exit status, and how many "warning:" lines there are.
expect() {
	[ "$rc" = "$2" ] || {
		echo "FAIL: $1: exit $rc, wanted $2"
		sed 's/^/  /' "$tmp/out"
		fail=1
	}
	if [ -n "${3-}" ]; then
		n=$(grep -c 'warning:' "$tmp/out")
		[ "$n" = "$3" ] || {
			echo "FAIL: $1: $n warnings, wanted $3"
			sed 's/^/  /' "$tmp/out"
			fail=1
		}
	fi
}
# has <name> <text>: the output has this text.
has() {
	grep -qF -- "$2" "$tmp/out" || {
		echo "FAIL: $1: output lacks: $2"
		sed 's/^/  /' "$tmp/out"
		fail=1
	}
}
sh_bin=$(command -v sh)
case_path=$PATH
# shellcheck disable=SC2088 # the literal text README.md registers
cmd='~/.claude/hooks/review-gate.sh'
expected_matcher=$(printf '%s' "$gate" | jq -r '.hooks.PreToolUse[0].matcher')
gate_with() { printf '%s' "$both" | jq "$@" >"$start"; }

rm -f "$start"
run_case none
expect none 1
has none "isn't registered"
has none "$cmd"

printf 'not json {\n' >"$start"
run_case not-json
expect not-json 1
has not-json "isn't registered"

printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/other.sh"}]}]}}' >"$start"
run_case other-hooks
expect other-hooks 1
has other-hooks "isn't registered"

gate_with '.hooks.PreToolUse[0].matcher = "Bash|Write|Edit|MultiEdit|NotebookEdit"'
run_case old-matcher
expect old-matcher 0 1
has old-matcher "$expected_matcher"

gate_with '.hooks.PreToolUse[0].hooks[0].timeout = 600'
run_case short-timeout
expect short-timeout 0 1
has short-timeout "2400"

gate_with 'del(.hooks.PreToolUse[0].hooks[0].timeout)'
run_case no-timeout
expect no-timeout 0 1
has no-timeout "timeout"

gate_with 'del(.hooks.PreToolUse[0].hooks[0].onFailure)'
run_case no-onfailure
expect no-onfailure 0 1
has no-onfailure '"onFailure": "block"'

gate_with '.hooks.PreToolUse[0].matcher = "Bash" | .hooks.PreToolUse[0].hooks[0].timeout = 600 | del(.hooks.PreToolUse[0].hooks[0].onFailure)'
run_case all-wrong
expect all-wrong 0 3
has all-wrong "$expected_matcher"

# The command written with the absolute path counts as registered.
gate_with --arg c "$tmp/case-abs-command/hooks/review-gate.sh" '.hooks.PreToolUse[0].hooks[0].command = $c'
run_case abs-command
expect abs-command 0 0

# The orchestrate hint is optional: an info line, the exit unchanged, and the gate's own warnings still show.
printf '%s\n' "$gate" >"$start"
run_case no-hint
expect no-hint 0 0
has no-hint "orchestrate-hint.sh"
printf '%s\n' "$gate" | jq '.hooks.PreToolUse[0].hooks[0].timeout = 600' >"$start"
run_case no-hint-warning
expect no-hint-warning 0 1

# Without jq the registration can't be read, so the check fails (the gate needs jq too).
nojq="$tmp/nojq-bin"
mkdir -p "$nojq"
unset -f git
for t in git tar mktemp mkdir cp rm cat dirname awk sed grep tr head cmp env sort sh cut; do
	p=$(command -v "$t")
	case $p in /*) ln -s "$p" "$nojq/$t" ;; esac
done
printf '%s\n' "$both" >"$start"
case_path=$nojq
run_case no-jq
case_path=$PATH
expect no-jq 1
has no-jq "jq not found"

[ "$fail" = 0 ] && echo "install: ok"
exit "$fail"
