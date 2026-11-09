#!/bin/sh
# Tests that install.sh runs origin/main's installer, not the checkout's: a checkout one commit behind a main
# whose installer deploys one more file still deploys it (claude-ship #20); and that it checks, read-only, that
# the Claude settings file registers the gate like README.md › Install says (claude-ship #109).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
# git's global config: every install below gets its own file (GIT_CONFIG_GLOBAL), never the machine's.
GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_NOSYSTEM
mkdir -p "$HOME" "$tmp/src/scripts"
# Never the machine's /etc/claude-code: a managed dir under the temp dir. Unless a case says otherwise it can't be written
# (its parent is a file), so the gate stays registered in user settings only and the checks below see no drop-in.
: >"$tmp/blocker"
blocked=$tmp/blocker/managed
CLAUDE_SHIP_MANAGED_DIR=$blocked
export CLAUDE_SHIP_MANAGED_DIR
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
cp -R "$root/agents" "$root/hooks" "$root/skills" "$root/settings" "$root/install.sh" "$root/README.md" "$tmp/src/"
cp "$root/scripts/codex-status.sh" "$tmp/src/scripts/"
# A stand-in for scripts/fetch-shfmt.sh (which has its own test): writes a small shfmt at its argument's path (install.sh
# must run what it fetched), fails when FETCH_FAIL is set, or leaves a file that can't run when FETCH_BROKEN is set.
cat >"$tmp/src/scripts/fetch-shfmt.sh" <<'STUB'
#!/bin/sh
[ -z "${FETCH_FAIL:-}" ] || {
	echo "stub: fetch failed" >&2
	exit 1
}
if [ -n "${FETCH_BROKEN:-}" ]; then
	printf '#!/nonexistent/interpreter\n' >"$1"
else
	printf '#!/bin/sh\n[ "$1" = --version ] && echo stub-shfmt\n' >"$1"
fi
chmod 755 "$1"
STUB
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
if ! GIT_CONFIG_GLOBAL="$tmp/gitconfig-main" CLAUDE_HOME="$tmp/dest" sh "$tmp/checkout/install.sh" >"$tmp/out" 2>&1; then
	echo "FAIL: install.sh exited non-zero"
	sed 's/^/  /' "$tmp/out"
	fail=1
fi
for f in main-installer-ran bin/shfmt hooks/review-gate.sh hooks/review-lib.sh hooks/orchestrate-hint.sh skills/ship/SKILL.md \
	skills/ship/orchestrate.md skills/ship/codex-status.sh agents/ship-explorer.md agents/ship-implementer.md \
	agents/ship-codex.md hooks/codex-bash.sh agents/mine.md; do
	[ -e "$tmp/dest/$f" ] || {
		echo "FAIL: $f wasn't deployed"
		fail=1
	}
done
# Every hook an agent's frontmatter names is deployed (claude-ship #122); the list comes from the agents themselves,
# so a new one can't be missed.
agent_hooks=$(grep -h 'command: ~/.claude/' "$root"/agents/ship-*.md | sed 's|.*command: ~/.claude/||')
case $agent_hooks in
*hooks/explorer-bash.sh*) ;;
*)
	echo "FAIL: no agent in agents/ names hooks/explorer-bash.sh"
	fail=1
	;;
esac
for f in $agent_hooks; do
	[ -x "$tmp/dest/$f" ] || {
		echo "FAIL: $f, named by an agent, isn't deployed and executable"
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
# shfmt is fetched by the fetch script from main's archive and put at $dest/bin/shfmt.
[ -x "$tmp/dest/bin/shfmt" ] && [ "$("$tmp/dest/bin/shfmt" --version 2>/dev/null)" = stub-shfmt ] || {
	echo "FAIL: shfmt wasn't installed into dest/bin/shfmt"
	fail=1
}
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
	# $seed: a directory whose files are already installed there; $nodeploy: the install is expected to deploy nothing.
	[ -z "${seed:-}" ] || cp -R "$seed/." "$cdir/"
	[ -f "$start" ] && cp "$start" "$cdir/settings.json"
	GIT_CONFIG_GLOBAL="$tmp/gitconfig-$1" CLAUDE_HOME=$cdir PATH=$case_path "$sh_bin" "${install_sh:-$tmp/checkout/install.sh}" >"$tmp/out" 2>&1
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
	[ -n "${nodeploy:-}" ] || [ -x "$cdir/hooks/review-gate.sh" ] || {
		echo "FAIL: $1: the gate wasn't deployed"
		fail=1
	}
}
# lacks <name> <text>: the output doesn't have this text.
lacks() {
	grep -qF -- "$2" "$tmp/out" && {
		echo "FAIL: $1: output has: $2"
		sed 's/^/  /' "$tmp/out"
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

# Claude Code runs every registered gate hook, so each one is judged and a second registration is itself a warning
# (claude-ship #153): the verdict can't depend on the order of the entries.
# A stale entry that misses all three checks (matcher, timeout, onFailure).
stale=$(jq -n --arg c "$cmd" '{matcher: "Bash", hooks: [{type: "command", command: $c, timeout: 600}]}')
# The README entry follows the stale one.
gate_with --argjson s "$stale" '.hooks.PreToolUse = [$s] + .hooks.PreToolUse'
run_case stale-then-good
expect stale-then-good 0 4
has stale-then-good "registered 2 times"
has stale-then-good "1st"
lacks stale-then-good "The gate is registered"
# The same two entries the other way round: the good one first must not hide the stale one.
gate_with --argjson s "$stale" '.hooks.PreToolUse += [$s]'
run_case good-then-stale
expect good-then-stale 0 4
has good-then-stale "registered 2 times"
has good-then-stale "2nd"
lacks good-then-stale "The gate is registered"
gate_with '.hooks.PreToolUse += [.hooks.PreToolUse[0]]'
run_case two-good
expect two-good 0 1
has two-good "registered 2 times"
lacks two-good "The gate is registered"
# Two gate hooks in one entry count too, and so does one written with the absolute path.
gate_with '.hooks.PreToolUse[0].hooks += [.hooks.PreToolUse[0].hooks[0]]'
run_case one-entry-two-hooks
expect one-entry-two-hooks 0 1
has one-entry-two-hooks "registered 2 times"
gate_with --arg c "$tmp/case-abs-twice/hooks/review-gate.sh" '.hooks.PreToolUse[0].hooks += [.hooks.PreToolUse[0].hooks[0] | .command = $c | del(.onFailure)]'
run_case abs-twice
expect abs-twice 0 2
has abs-twice "2nd"
# Three registrations: the count, and the third one named.
gate_with --argjson s "$stale" '.hooks.PreToolUse += [.hooks.PreToolUse[0], $s]'
run_case three
expect three 0 4
has three "registered 3 times"
has three "3rd"

# The orchestrate hint is optional: an info line, the exit unchanged, and the gate's own warnings still show.
printf '%s\n' "$gate" >"$start"
run_case no-hint
expect no-hint 0 0
has no-hint "orchestrate-hint.sh"
printf '%s\n' "$gate" | jq '.hooks.PreToolUse[0].hooks[0].timeout = 600' >"$start"
run_case no-hint-warning
expect no-hint-warning 0 1

# The PR loop needs CLAUDE_CODE_FORK_SUBAGENT=0 (claude-ship #160): only the string "0" counts; anything else
# gets an info line, with the exit and the warning count unchanged.
fork_info='"CLAUDE_CODE_FORK_SUBAGENT": "0"'
gate_with '.'
run_case fork-missing
expect fork-missing 0 0
has fork-missing "$fork_info"
has fork-missing "claude-ship #160"
gate_with '.env = {"CLAUDE_CODE_FORK_SUBAGENT": "0"}'
run_case fork-set
expect fork-set 0 0
grep -qF 'CLAUDE_CODE_FORK_SUBAGENT' "$tmp/out" && {
	echo "FAIL: fork-set: the setting is there but the output mentions it"
	sed 's/^/  /' "$tmp/out"
	fail=1
}
# fork_case <name> <jq filter>: a settings file that doesn't set the string "0".
fork_case() {
	gate_with "$2"
	run_case "$1"
	expect "$1" 0 0
	has "$1" "$fork_info"
}
fork_case fork-number '.env = {"CLAUDE_CODE_FORK_SUBAGENT": 0}'
fork_case fork-one '.env = {"CLAUDE_CODE_FORK_SUBAGENT": "1"}'
fork_case fork-empty '.env = {"CLAUDE_CODE_FORK_SUBAGENT": ""}'
fork_case fork-null '.env = {"CLAUDE_CODE_FORK_SUBAGENT": null}'
fork_case fork-env-string '.env = "oops"'
fork_case fork-env-array '.env = []'

# A failing shfmt fetch stops the install before anything is changed (claude-ship #189): a gate deployed without shfmt
# blocks every Bash call. What was installed before stays as it was, shfmt and the gate included, and the settings stay
# untouched (run_case checks that). FETCH_BROKEN is a fetch that "succeeds" with a file that can't run.
gate_with '.'
mkdir -p "$tmp/old-install/hooks" "$tmp/old-install/bin"
printf 'old gate\n' >"$tmp/old-install/hooks/review-gate.sh"
printf 'old shfmt\n' >"$tmp/old-install/bin/shfmt"
chmod 755 "$tmp/old-install/hooks/review-gate.sh" "$tmp/old-install/bin/shfmt"
seed=$tmp/old-install
nodeploy=1
for v in FETCH_FAIL FETCH_BROKEN; do
	cn=shfmt-$v
	export "$v=1"
	run_case "$cn"
	unset "$v"
	expect "$cn" 1 0
	has "$cn" "couldn't install shfmt"
	has "$cn" "nothing was installed"
	[ "$(cat "$tmp/case-$cn/hooks/review-gate.sh")" = "old gate" ] && [ "$(cat "$tmp/case-$cn/bin/shfmt")" = "old shfmt" ] || {
		echo "FAIL: $cn: the installed gate or shfmt changed"
		fail=1
	}
	for f in skills agents hooks/review-lib.sh git-hooks; do
		[ ! -e "$tmp/case-$cn/$f" ] || {
			echo "FAIL: $cn: $f was deployed"
			fail=1
		}
	done
	lacks "$cn" "Deployed claude-ship"
done
unset seed nodeploy
# The same registration with a working fetch exits 0, with shfmt in place.
run_case shfmt-works
expect shfmt-works 0 0
[ -f "$tmp/case-shfmt-works/bin/shfmt" ] || {
	echo "FAIL: shfmt-works: no bin/shfmt"
	fail=1
}

# An agent whose frontmatter hook isn't deployed or isn't executable would run its Bash unrestricted (a missing hook
# is a non-blocking error), so the install says so and exits 1, the files still deployed (claude-ship #122). A main
# with two such agents: one names a hook it doesn't ship, one a hook committed without the execute bit.
cp -R "$tmp/src" "$tmp/src2"
for n in missing:not-shipped noexec:not-exec; do
	printf -- '---\nname: ship-%s\nhooks:\n  PreToolUse:\n    - matcher: Bash\n      hooks:\n        - type: command\n          command: ~/.claude/hooks/%s.sh\n---\nbody\n' "${n%%:*}" "${n#*:}" >"$tmp/src2/agents/ship-${n%%:*}.md"
done
printf '#!/bin/sh\n' >"$tmp/src2/hooks/not-exec.sh"
chmod 644 "$tmp/src2/hooks/not-exec.sh"
git -C "$tmp/src2" add -A
git -C "$tmp/src2" commit -qm fixtures
git clone -q --bare "$tmp/src2" "$tmp/origin2.git"
git clone -q "$tmp/origin2.git" "$tmp/checkout2"
install_sh="$tmp/checkout2/install.sh"
printf '%s\n' "$both" >"$start"
run_case agent-hook-missing
unset install_sh
expect agent-hook-missing 1 0
has agent-hook-missing "ship-missing names ~/.claude/hooks/not-shipped.sh, which isn't deployed or isn't executable; its Bash runs unrestricted"
has agent-hook-missing "ship-noexec names ~/.claude/hooks/not-exec.sh, which isn't deployed or isn't executable"
lacks agent-hook-missing "ship-explorer names"
lacks agent-hook-missing "ship-codex names"
has agent-hook-missing "The gate is registered"
[ -e "$tmp/case-agent-hook-missing/skills/ship/SKILL.md" ] || {
	echo "FAIL: agent-hook-missing: the skill wasn't deployed"
	fail=1
}

# The git hook stubs and core.hooksPath (docs/gate.md › Pre-push check). hk_run <dest> <global git config>: installs with
# that config as git's global one.
hk_run() {
	GIT_CONFIG_GLOBAL=$2 CLAUDE_HOME=$1 sh "$tmp/checkout/install.sh" >"$tmp/out" 2>&1
	rc=$?
}
# One stub per hook git 2.34 runs from the hooks directory (`git help hooks`), except the three whose presence alone changes
# what git does.
want_stubs='applypatch-msg commit-msg post-checkout post-commit post-index-change post-merge post-receive post-rewrite post-update
p4-changelist p4-post-changelist p4-pre-submit p4-prepare-changelist pre-applypatch pre-auto-gc pre-commit pre-merge-commit
pre-push pre-rebase pre-receive prepare-commit-msg post-applypatch reference-transaction sendemail-validate update'
want_stubs=$(printf '%s\n' $want_stubs | sort)
left_out='push-to-checkout proc-receive fsmonitor-watchman'
gc=$tmp/gc-hooks
: >"$gc"
# Each destination has a valid registration, so the exit status is about the hooks alone.
for d in hk-dest hk-dest2 hk-dest3; do
	mkdir -p "$tmp/$d"
	printf '%s\n' "$both" >"$tmp/$d/settings.json"
done
hk=$tmp/hk-dest
hk_run "$hk" "$gc"
[ "$rc" = 0 ] || {
	echo "FAIL: hooks: the install exited $rc"
	sed 's/^/  /' "$tmp/out"
	fail=1
}
[ "$(ls "$hk/git-hooks" | sort)" = "$want_stubs" ] || {
	echo "FAIL: hooks: the stubs aren't the expected set"
	printf '%s\n' "$want_stubs" >"$tmp/stubs.want"
	ls "$hk/git-hooks" | sort >"$tmp/stubs.got"
	diff "$tmp/stubs.want" "$tmp/stubs.got" | sed 's/^/  /'
	fail=1
}
for h in $left_out; do
	[ ! -e "$hk/git-hooks/$h" ] || {
		echo "FAIL: hooks: a stub for $h, whose presence alone changes what git does"
		fail=1
	}
done
# Against git's own list, when its manual is installed.
if listed=$(git help hooks 2>/dev/null | sed -n 's/^   \([a-z0-9-]*\)$/\1/p' | sort) && [ -n "$listed" ]; then
	for h in $left_out; do listed=$(printf '%s\n' "$listed" | grep -vx "$h"); done
	[ "$listed" = "$want_stubs" ] || echo "note: this git runs other hooks than the stub list (git help hooks): $(printf '%s\n' "$listed" | tr '\n' ' ')"
fi
for h in $want_stubs; do
	f=$hk/git-hooks/$h
	[ -x "$f" ] || {
		echo "FAIL: hooks: $h isn't executable"
		fail=1
	}
	[ "$(sed -n 1p "$f")" = '#!/bin/sh' ] && [ "$(sed -n 2p "$f")" = "exec sh '$hk/hooks/git-hook.sh' $h \"\$@\"" ] && [ "$(wc -l <"$f")" -eq 2 ] || {
		echo "FAIL: hooks: $h isn't the expected stub:"
		sed 's/^/  /' "$f"
		fail=1
	}
done
[ "$(git config -f "$gc" core.hooksPath)" = "$hk/git-hooks" ] || {
	echo "FAIL: hooks: core.hooksPath isn't set to the stubs"
	fail=1
}
has hooks "Git now runs repos' own hooks through the stubs in $hk/git-hooks"
[ -x "$hk/hooks/git-hook.sh" ] && [ -f "$hk/hooks/gate-common.sh" ] || {
	echo "FAIL: hooks: git-hook.sh or gate-common.sh wasn't deployed"
	fail=1
}
# The stubs work: a repo's own hook runs through the deployed stub, with its arguments.
mkdir -p "$tmp/hkrepo"
git -C "$tmp/hkrepo" init -q
printf '#!/bin/sh\necho "$@" >"%s/own.args"\nexit 3\n' "$tmp" >"$tmp/hkrepo/.git/hooks/post-checkout"
chmod +x "$tmp/hkrepo/.git/hooks/post-checkout"
(cd "$tmp/hkrepo" && "$hk/git-hooks/post-checkout" a b c)
[ $? = 3 ] && [ "$(cat "$tmp/own.args")" = "a b c" ] || {
	echo "FAIL: hooks: the repo's own hook didn't run through its stub"
	fail=1
}
(cd "$tmp/hkrepo" && "$hk/git-hooks/pre-commit") || {
	echo "FAIL: hooks: a stub for a hook the repo doesn't have failed"
	fail=1
}
# A second run changes nothing and exits 0.
cp -R "$hk/git-hooks" "$tmp/hk-before"
cp "$gc" "$tmp/gc-before"
hk_run "$hk" "$gc"
[ "$rc" = 0 ] || {
	echo "FAIL: hooks: the second install exited $rc"
	sed 's/^/  /' "$tmp/out"
	fail=1
}
diff -r "$tmp/hk-before" "$hk/git-hooks" >/dev/null && cmp -s "$tmp/gc-before" "$gc" || {
	echo "FAIL: hooks: a second install changed the stubs or the config"
	fail=1
}
# core.hooksPath already something else: left alone, with its value in the message, and the exit says so.
gc2=$tmp/gc-hooks2
git config -f "$gc2" core.hooksPath /somewhere/else
cp "$gc2" "$tmp/gc2-before"
hk_run "$tmp/hk-dest2" "$gc2"
[ "$rc" = 1 ] || {
	echo "FAIL: hooks: another core.hooksPath should exit 1, got $rc"
	fail=1
}
has hooks-other "/somewhere/else"
has hooks-other "$tmp/hk-dest2/git-hooks"
cmp -s "$tmp/gc2-before" "$gc2" || {
	echo "FAIL: hooks: another core.hooksPath was changed"
	fail=1
}
[ -x "$tmp/hk-dest2/git-hooks/pre-push" ] && [ -x "$tmp/hk-dest2/hooks/review-gate.sh" ] || {
	echo "FAIL: hooks: the rest wasn't deployed next to another core.hooksPath"
	fail=1
}
# Unrelated settings in the config survive the set.
gc3=$tmp/gc-hooks3
git config -f "$gc3" user.name keepme
hk_run "$tmp/hk-dest3" "$gc3"
[ "$rc" = 0 ] && [ "$(git config -f "$gc3" user.name)" = keepme ] && [ "$(git config -f "$gc3" core.hooksPath)" = "$tmp/hk-dest3/git-hooks" ] || {
	echo "FAIL: hooks: setting core.hooksPath lost other settings or failed (exit $rc)"
	fail=1
}
# A destination that isn't an absolute path can't be the value the gate wants.
(cd "$tmp" && GIT_CONFIG_GLOBAL=$tmp/gc-hooks4 CLAUDE_HOME=relative-dest sh "$tmp/checkout/install.sh") >"$tmp/out" 2>&1
rc=$?
[ "$rc" = 1 ] && grep -q 'absolute path' "$tmp/out" || {
	echo "FAIL: hooks: a relative CLAUDE_HOME should exit 1 naming the absolute path (got $rc)"
	fail=1
}

# The managed-settings drop-in (claude-ship #189): settings/claude-ship.json goes to $CLAUDE_SHIP_MANAGED_DIR/managed-settings.d,
# where user and project settings can't turn it off. It is the gate's registration, so the check accepts it alone.
dropin_want="$root/settings/claude-ship.json"
managed_case() {
	# managed_case <name>: run_case with a managed dir of its own, then back to the unwritable one.
	CLAUDE_SHIP_MANAGED_DIR=$tmp/managed-$1
	run_case "$1"
	CLAUDE_SHIP_MANAGED_DIR=$blocked
}
rm -f "$start"
managed_case drop-in-only
expect drop-in-only 0 0
has drop-in-only "managed settings drop-in"
has drop-in-only "$tmp/managed-drop-in-only/managed-settings.d/claude-ship.json"
has drop-in-only '"Enterprise managed settings (drop-ins)"'
lacks drop-in-only "the gate isn't registered"
cmp -s "$dropin_want" "$tmp/managed-drop-in-only/managed-settings.d/claude-ship.json" || {
	echo "FAIL: drop-in-only: the drop-in isn't a byte-for-byte copy of settings/claude-ship.json"
	fail=1
}
jq -e . "$tmp/managed-drop-in-only/managed-settings.d/claude-ship.json" >/dev/null 2>&1 || {
	echo "FAIL: drop-in-only: the installed drop-in isn't valid JSON"
	fail=1
}
[ "$(ls -A "$tmp/managed-drop-in-only/managed-settings.d")" = claude-ship.json ] || {
	echo "FAIL: drop-in-only: managed-settings.d holds more than claude-ship.json"
	ls -A "$tmp/managed-drop-in-only/managed-settings.d"
	fail=1
}
# A second install over the first changes nothing.
cp -R "$tmp/managed-drop-in-only" "$tmp/managed-again"
CLAUDE_SHIP_MANAGED_DIR=$tmp/managed-again
run_case drop-in-again
CLAUDE_SHIP_MANAGED_DIR=$blocked
expect drop-in-again 0 0
diff -r "$tmp/managed-drop-in-only" "$tmp/managed-again" >/dev/null || {
	echo "FAIL: drop-in-again: a second install changed the managed dir"
	fail=1
}
# Also in user settings: the same handler, which Claude Code runs once. Said once, no warning, the entry left alone.
printf '%s\n' "$both" >"$start"
managed_case drop-in-and-user
expect drop-in-and-user 0 0
has drop-in-and-user "runs a handler that appears in both once"
has drop-in-and-user '"Enterprise managed settings (drop-ins)"'
has drop-in-and-user "you can remove the gate's entry from"
lacks drop-in-and-user "the gate isn't registered"
# The user's entry is still judged: a stale one warns as it always did.
gate_with '.hooks.PreToolUse[0].hooks[0].timeout = 600'
managed_case drop-in-stale-user
expect drop-in-stale-user 0 1
# Other policy files in the managed dir stay as they are.
mkdir -p "$tmp/managed-others/managed-settings.d"
printf '{"permissions": {"deny": ["Bash(rm -rf /)"]}}\n' >"$tmp/managed-others/managed-settings.json"
printf '{"env": {"A": "1"}}\n' >"$tmp/managed-others/managed-settings.d/10-other.json"
cp -R "$tmp/managed-others" "$tmp/managed-others.before"
managed_case others
expect others 0 1
rm "$tmp/managed-others/managed-settings.d/claude-ship.json"
diff -r "$tmp/managed-others.before" "$tmp/managed-others" >/dev/null || {
	echo "FAIL: others: the managed dir's other files changed"
	fail=1
}
# Not writable (not root): the gate stays registered in user settings only, and everything else is installed.
gate_with '.'
run_case unwritable
expect unwritable 0 0
has unwritable "stays registered in user settings only"
has unwritable "The gate is registered in"
# Nowhere registered, and no drop-in: the old failure.
rm -f "$start"
run_case unwritable-none
expect unwritable-none 1
has unwritable-none "isn't registered"
has unwritable-none "stays registered in user settings only"
# A template that isn't a valid drop-in stops the install before anything is changed or written: a managed file that
# isn't valid JSON stops Claude Code from starting. bad_main <name> <content> makes a main whose template is that.
bad_main() {
	cp -R "$tmp/src" "$tmp/src-$1"
	printf '%s\n' "$2" >"$tmp/src-$1/settings/claude-ship.json"
	git -C "$tmp/src-$1" add -A
	git -C "$tmp/src-$1" commit -qm "bad template"
	git clone -q --bare "$tmp/src-$1" "$tmp/origin-$1.git"
	git clone -q "$tmp/origin-$1.git" "$tmp/checkout-$1"
}
gate_with '.'
seed=$tmp/old-install
nodeploy=1
bad_main t-not-json 'not json {'
bad_main t-no-onfailure "$(jq -c 'del(.hooks.PreToolUse[0].hooks[0].onFailure)' "$dropin_want")"
bad_main t-no-hooks '{}'
bad_main t-empty ''
bad_main t-command-type "$(jq -c '.hooks.PreToolUse[0].hooks[0].command = 7' "$dropin_want")"
for t in t-not-json t-no-onfailure t-no-hooks t-empty t-command-type; do
	install_sh=$tmp/checkout-$t/install.sh
	CLAUDE_SHIP_MANAGED_DIR=$tmp/managed-$t
	run_case "$t"
	CLAUDE_SHIP_MANAGED_DIR=$blocked
	expect "$t" 1 0
	has "$t" "settings/claude-ship.json"
	has "$t" "nothing was installed"
	[ ! -e "$tmp/managed-$t" ] || {
		echo "FAIL: $t: the managed dir was created"
		fail=1
	}
	[ "$(cat "$tmp/case-$t/hooks/review-gate.sh")" = "old gate" ] && [ ! -e "$tmp/case-$t/skills" ] || {
		echo "FAIL: $t: something was deployed"
		fail=1
	}
done
unset seed nodeploy install_sh

# Without jq the registration can't be read, so the check fails (the gate needs jq too).
nojq="$tmp/nojq-bin"
mkdir -p "$nojq"
unset -f git
for t in git tar mktemp mkdir cp mv rm cat dirname awk sed grep tr head cmp env sort sh cut chmod; do
	p=$(command -v "$t")
	case $p in /*) ln -s "$p" "$nojq/$t" ;; esac
done
printf '%s\n' "$both" >"$start"
case_path=$nojq
seed=$tmp/old-install
nodeploy=1
run_case no-jq
unset seed nodeploy
case_path=$PATH
expect no-jq 1
has no-jq "jq not found"
has no-jq "nothing was installed"

[ "$fail" = 0 ] && echo "install: ok"
exit "$fail"
