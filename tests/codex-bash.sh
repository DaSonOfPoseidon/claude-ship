#!/bin/sh
# Tests the ship-codex agent's PreToolUse hook (hooks/codex-bash.sh): exactly the Codex round's ship scripts,
# read-only gh pr view/checks, and a Write of a triage file allow (with the allow decision on stdout); anything
# else, or anything it can't parse, exits 2.
# shellcheck disable=SC2088 # the literal ~ is what the agent writes; the shell expands it
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
# The triage file does not depend on the checkout, which may be anywhere, a path with a space included.
mkdir "$tmp/my repo" "$tmp/other" "$tmp/home"
git init -q "$tmp/my repo"
HOME=$tmp/home
export HOME
ship='~/.claude/skills/ship'
# The triage file, as the Bash command names it (the shell expands the ~) and as Write names it (absolute).
tf='~/.claude/state/claude-ship'
st=$HOME/.claude/state/claude-ship
sha=0123456789abcdef0123456789abcdef01234567
allow='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'

# check <exit code> <hook input> [dir]: runs the hook on the input from a checkout whose path has a space (or dir).
check() {
	(cd "${3:-$tmp/my repo}" &&printf '%s' "$2" | sh "$root/hooks/codex-bash.sh" >"$tmp/out" 2>"$tmp/err")
	rc=$?
	if [ "$rc" != "$1" ]; then
		echo "FAIL (exit $rc, want $1): $2"
		sed 's/^/  /' "$tmp/err"
		fail=1
	elif [ "$1" = 0 ] && [ "$(cat "$tmp/out")" != "$allow" ]; then
		echo "FAIL (no allow decision on stdout): $2"
		fail=1
	elif [ "$1" = 2 ] && [ -s "$tmp/out" ]; then
		echo "FAIL (a denial printed to stdout): $2"
		fail=1
	fi
}

# expect <exit code> <command>: a Bash call of the command.
expect() {
	check "$1" "$(jq -nc --arg c "$2" '{tool_name: "Bash", tool_input: {command: $c}}')"
}

# write <exit code> <file path>: a Write call.
write() {
	check "$1" "$(jq -nc --arg p "$2" '{tool_name: "Write", tool_input: {file_path: $p, content: "[]"}}')"
}

# Allowed: the round's ship scripts, as one plain command, by the installed path.
expect 0 "$ship/codex-round.sh 12"
expect 0 "$ship/codex-round.sh 12 o/r"
expect 0 "$ship/codex-round.sh 12 DaSonOfPoseidon/claude-ship"
expect 0 "$ship/codex-request.sh 12 o/r $sha"
expect 0 "$ship/codex-wait.sh 12"
expect 0 "CODEX_WAIT_SECS=300 $ship/codex-wait.sh 12"
expect 0 "CODEX_WAIT_SECS=570 $ship/codex-wait.sh 12"
expect 0 "CODEX_WAIT_SECS=1200 $ship/codex-wait.sh 12"
expect 0 "$ship/codex-findings.sh 12"
expect 0 "$ship/ci-failures.sh 12"
expect 0 "$ship/ci-failures.sh 12 acme/app"
expect 0 "$ship/ci-failures.sh 137 DaSonOfPoseidon/claude-ship"
expect 0 "$ship/ci-failures.sh 12 acme/app --wait"
expect 0 "$ship/codex-triage.sh 12 $tf/triage-o+r-12.json"
expect 0 "$ship/codex-triage.sh 137 $tf/triage-DaSonOfPoseidon+claude-ship-137.json"
expect 0 "$ship/codex-triage.sh 12 $tf/triage-o+x-12-12.json"
# Allowed: read-only gh.
expect 0 'gh pr view 12'
expect 0 'gh pr view 12 --json headRefOid --jq .headRefOid'
expect 0 'gh pr view 12 --comments'
expect 0 'gh pr view 12 -R o/r --json headRefOid --jq .headRefOid'
expect 0 'gh pr checks 12'
expect 0 'gh pr checks 12 --required'
expect 0 'gh pr checks 12 -R o/r'
expect 0 'gh pr checks 12 -R o/r --watch --interval 30'
# Allowed: the triage file, and only it, to write.
write 0 "$st/triage-o+r-12.json"
write 0 "$st/triage-DaSonOfPoseidon+claude-ship-137.json"
write 0 "$st/triage-o+x-12-12.json"
# Either works from outside any checkout, and from a path with no space.
check 0 "$(jq -nc --arg p "$st/triage-o+r-12.json" '{tool_name: "Write", tool_input: {file_path: $p, content: "[]"}}')" "$tmp/other"
check 0 "$(jq -nc --arg c "$ship/codex-triage.sh 12 $tf/triage-o+r-12.json" '{tool_name: "Bash", tool_input: {command: $c}}')" "$tmp/other"

# Denied: more than one command, or anything the shell would rewrite.
expect 2 "$ship/codex-round.sh 12; rm x"
expect 2 "$ship/codex-round.sh 12 && rm x"
expect 2 "$ship/codex-round.sh 12 || rm x"
expect 2 "$ship/codex-round.sh 12 | sh"
expect 2 "$ship/codex-round.sh 12 & rm x"
expect 2 "$ship/codex-round.sh \$(rm x)"
expect 2 "$ship/codex-round.sh 12 \`rm x\`"
expect 2 "$ship/codex-round.sh \"12\""
expect 2 "$ship/codex-round.sh '12'"
expect 2 "$ship/codex-round.sh 12 > out"
expect 2 "$ship/codex-round.sh 12 2>&1"
expect 2 "$ship/codex-round.sh 12 < in"
expect 2 "$ship/codex-round.sh \$HOME"
expect 2 "$ship/codex-round.sh *"
expect 2 "$ship/codex-round.sh 1?"
expect 2 "$ship/codex-round.sh 12
rm x"
expect 2 "$ship/codex-round.sh 12	o/r"
expect 2 "$ship/codex-round.sh {1,2}"
expect 2 "$ship/codex-round.sh 12 \\"
# Denied: arguments that aren't what the script takes.
expect 2 "$ship/codex-round.sh"
expect 2 "$ship/codex-round.sh abc"
expect 2 "$ship/codex-round.sh 12abc"
expect 2 "$ship/codex-round.sh -1"
expect 2 "$ship/codex-round.sh 12 o/r extra"
expect 2 "$ship/codex-round.sh 12 -x/y"
expect 2 "$ship/codex-round.sh 12 o/r/s"
expect 2 "$ship/codex-round.sh 12 o"
expect 2 "$ship/codex-round.sh 12 ../x"
expect 2 "$ship/codex-round.sh 12 o/.."
expect 2 "$ship/codex-round.sh 12 o/r@x"
expect 2 "$ship/codex-request.sh 12"
expect 2 "$ship/codex-request.sh 12 o/r"
expect 2 "$ship/codex-request.sh 12 o/r nothex"
expect 2 "$ship/codex-request.sh 12 o/r abc1234"
expect 2 "$ship/codex-request.sh 12 o/r 0123456789ABCDEF0123456789abcdef01234567"
expect 2 "$ship/codex-request.sh 12 o/r ${sha}0"
expect 2 "$ship/codex-request.sh 12 o/r $sha extra"
expect 2 "$ship/codex-request.sh abc o/r $sha"
expect 2 "$ship/codex-wait.sh"
expect 2 "$ship/codex-wait.sh 12 extra"
expect 2 "$ship/codex-findings.sh"
expect 2 "$ship/codex-findings.sh 12 o/r"
# ci-failures.sh: <pr> and an optional owner/repo only (the near misses of every allowed form).
expect 2 "$ship/ci-failures.sh"
expect 2 "$ship/ci-failures.sh x"
expect 2 "$ship/ci-failures.sh 12abc"
expect 2 "$ship/ci-failures.sh -1"
expect 2 "$ship/ci-failures.sh 12 a;b"
expect 2 "$ship/ci-failures.sh 12 o/r extra"
expect 2 "$ship/ci-failures.sh 12 o"
expect 2 "$ship/ci-failures.sh 12 -x/y"
expect 2 "$ship/ci-failures.sh 12 o/r/s"
expect 2 "$ship/ci-failures.sh 12 ../x"
expect 2 "$ship/ci-failures.sh 12 o/r@x"
expect 2 "CODEX_WAIT_SECS=300 $ship/ci-failures.sh 12"
expect 2 "$ship/ci-failures.sh 12 --wait"
expect 2 "$ship/ci-failures.sh 12 o/r --wait extra"
expect 2 "$ship/ci-failures.sh 12 o/r --wai"
expect 2 "$ship/ci-failures.sh 12 o/r --wait=1"
expect 2 "$ship/ci-failures.sh 12 o/r -w"
expect 2 "$ship/ci-failures.sh 12 --wait o/r"
expect 2 "CI_WAIT_INTERVAL=0 $ship/ci-failures.sh 12 o/r --wait"
expect 2 "$ship/ci-failures.sh.bak 12"
expect 2 "~/.claude/skills/other/ci-failures.sh 12"
expect 2 "~/.claude/skills/ship/../ship/ci-failures.sh 12"
expect 2 "sh $ship/ci-failures.sh 12"
expect 2 "$ship/ci-failures.sh 12 | cat"
expect 2 "$ship/codex-triage.sh 12"
expect 2 "$ship/codex-triage.sh 12 $tf/triage-o+r-12.json o/r"
# Denied: the triage file must be the PR's own, in the one directory, named by a repository and the PR number.
expect 2 "$ship/codex-triage.sh 12 triage-o+r-12.json"
expect 2 "$ship/codex-triage.sh 12 $tf/triage-o+r-13.json"
expect 2 "$ship/codex-triage.sh 12 $tf/triage-12.json"
expect 2 "$ship/codex-triage.sh 12 $tf/triage-o-r-12.json"
expect 2 "$ship/codex-triage.sh 12 $tf/triage-o+r+s-12.json"
expect 2 "$ship/codex-triage.sh 12 $tf/triage-o/r-12.json"
expect 2 "$ship/codex-triage.sh 12 $tf/triage-+r-12.json"
expect 2 "$ship/codex-triage.sh 12 $tf/triage-o+-12.json"
expect 2 "$ship/codex-triage.sh 12 $tf/triage--o+r-12.json"
expect 2 "$ship/codex-triage.sh 12 $tf/triage-o+..-12.json"
expect 2 "$ship/codex-triage.sh 12 $tf/triage-o+r-12.json.bak"
expect 2 "$ship/codex-triage.sh 12 $tf/plan-o+r-12.json"
expect 2 "$ship/codex-triage.sh 12 $tf/../triage-o+r-12.json"
expect 2 "$ship/codex-triage.sh 12 $tf/x/triage-o+r-12.json"
expect 2 "$ship/codex-triage.sh 12 $tf//triage-o+r-12.json"
expect 2 "$ship/codex-triage.sh 12 ~/.claude/state/triage-o+r-12.json"
expect 2 "$ship/codex-triage.sh 12 ~/.claude/hooks/triage-o+r-12.json"
expect 2 "$ship/codex-triage.sh 12 ~/.claude/settings.json"
expect 2 "$ship/codex-triage.sh 12 $st/triage-o+r-12.json"
expect 2 "$ship/codex-triage.sh 12 $tmp/other/triage-o+r-12.json"
expect 2 "$ship/codex-triage.sh 12 /etc/passwd"
# Denied: environment before the script, other than the wait's own cap.
expect 2 "PATH=/tmp/x $ship/codex-wait.sh 12"
expect 2 "CODEX_WAIT_SECS=abc $ship/codex-wait.sh 12"
expect 2 "CODEX_WAIT_SECS= $ship/codex-wait.sh 12"
expect 2 "CODEX_WAIT_SECS=-5 $ship/codex-wait.sh 12"
expect 2 "CODEX_WAIT_SECS=570 CODEX_WAIT_SECS=1 $ship/codex-wait.sh 12"
# The foreground chunk (ship-codex runs it alone, claude-ship #147): nothing may follow or run after it.
expect 2 "CODEX_WAIT_SECS=300 $ship/codex-wait.sh 12; sleep 60"
expect 2 "CODEX_WAIT_SECS=300 $ship/codex-wait.sh 12 && cat /x/out"
expect 2 "CODEX_WAIT_SECS=300 $ship/codex-wait.sh 12 | tail"
expect 2 "CODEX_WAIT_SECS=300 $ship/codex-wait.sh 12 &"
expect 2 "CODEX_WAIT_SECS=570 PATH=/tmp/x $ship/codex-wait.sh 12"
expect 2 "CODEX_WAIT_SECS=570 $ship/codex-round.sh 12"
expect 2 "CODEX_WAIT_SECS=570 $ship/codex-findings.sh 12"
expect 2 "CODEX_WAIT_SECS=570 gh pr view 12"
expect 2 "CODEX_REQUEST_TRIES=1 $ship/codex-request.sh 12 o/r $sha"
expect 2 "CODEX_STALL_SECS=1 $ship/codex-round.sh 12"
expect 2 "GH_TOKEN=x $ship/codex-round.sh 12"
expect 2 "CODEX_WAIT_SECS=570"
expect 2 "env CODEX_WAIT_SECS=570 $ship/codex-wait.sh 12"
# Denied: the script must be named by the installed path, as the one command.
expect 2 './codex-triage.sh 12 f'
expect 2 'codex-round.sh 12'
expect 2 '/tmp/codex-triage.sh 12 f'
expect 2 "/tmp/codex-round.sh 12"
expect 2 "$HOME/.claude/skills/ship/codex-round.sh 12"
expect 2 "~/.claude/skills/ship/../ship/codex-round.sh 12"
expect 2 "~/.claude/skills/ship/./codex-round.sh 12"
expect 2 "~/.claude/skills//ship/codex-round.sh 12"
expect 2 "~/.claude/skills/ship/codex-round.sh.bak 12"
expect 2 "~/.claude/skills/ship/codex-status.sh 12"
expect 2 "~/.claude/skills/ship/p3-issue.sh 12"
expect 2 "~/.claude/skills/ship/token-report.sh 12"
expect 2 "~/.claude/hooks/p3-issue.sh 12"
expect 2 "~root/.claude/skills/ship/codex-round.sh 12"
expect 2 "~/.claude/skills/other/codex-round.sh 12"
expect 2 "sh $ship/codex-round.sh 12"
expect 2 "bash $ship/codex-round.sh 12"
expect 2 "env $ship/codex-round.sh 12"
expect 2 "sh -c codex-round.sh"
# Denied: gh other than a read of the PR.
expect 2 'gh api repos/o/r/pulls/12'
expect 2 'gh api graphql'
expect 2 'gh pr comment 12 --body x'
expect 2 'gh pr merge 12'
expect 2 'gh pr close 12'
expect 2 'gh pr edit 12 --title x'
expect 2 'gh pr create'
expect 2 'gh pr diff 12'
expect 2 'gh pr view'
expect 2 'gh pr view abc'
expect 2 'gh pr view --json x'
expect 2 'gh pr checks'
expect 2 'gh pr view 12 --web'
expect 2 'gh pr view 12 -w'
expect 2 'gh pr view 12 -cw'
expect 2 'gh pr view 12 --web=true'
expect 2 'gh pr view 12 -- --web'
expect 2 'gh pr checks 12 --web'
expect 2 'gh pr checks 12 -w'
expect 2 'gh pr checks 12 -R o/r --watch --web'
expect 2 'gh issue view 12'
expect 2 'gh issue create'
expect 2 'gh workflow run codex-review.yml'
expect 2 'gh -R o/r pr view 12'
expect 2 'gh'
expect 2 'gh pr'
expect 2 'GH_PAGER=x gh pr view 12'
expect 2 'git log'
expect 2 'git push origin HEAD'
expect 2 'rm -rf x'
expect 2 'cat README.md'
expect 2 'jq . x.json'
expect 2 ''
expect 2 ' '
# Denied: a Write that isn't the triage file.
write 2 "$st/triage-o+r-12.json.bak"
write 2 "$st/triage-.json"
write 2 "$st/triage-12.json"
write 2 "$st/triage-o+r-x.json"
write 2 "$st/triage-o+r-.json"
write 2 "$st/triage-o+r.json"
write 2 "$st/triage-o-r-12.json"
write 2 "$st/triage-o+r+s-12.json"
write 2 "$st/triage-o+-12.json"
write 2 "$st/triage-+r-12.json"
write 2 "$st/triage--o+r-12.json"
write 2 "$st/triage-o+..-12.json"
write 2 "$st/triage-o+r/../x-12.json"
write 2 "$st/triage-o/r-12.json"
write 2 "$st/triage-o+r-12-.json"
write 2 "$st/plan-o+r-12.json"
write 2 "$st/loop.md"
write 2 "$st/../triage-o+r-12.json"
write 2 "$st/x/../triage-o+r-12.json"
write 2 "$st//triage-o+r-12.json"
write 2 "$st/sub/triage-o+r-12.json"
write 2 "$HOME/.claude/state/triage-o+r-12.json"
write 2 "$HOME/.claude/hooks/triage-o+r-12.json"
write 2 "$HOME/.claude/skills/ship/triage-o+r-12.json"
write 2 "$HOME/.claude/agents/triage-o+r-12.json"
write 2 "$tmp/other/triage-o+r-12.json"
write 2 "$tmp/my repo/triage-o+r-12.json"
write 2 "$tmp/my repo/.git/claude-ship/triage-12.json"
write 2 '~/.claude/state/claude-ship/triage-o+r-12.json'
write 2 'triage-o+r-12.json'
write 2 'claude-ship/triage-o+r-12.json'
write 2 '/tmp/triage-o+r-12.json'
write 2 '/etc/passwd'
write 2 "$HOME/.claude/settings.json"
write 2 "$HOME/.claude/hooks/codex-bash.sh"
write 2 "$tmp/my repo/AGENTS.md"
write 2 ''
# Without a home directory there is no triage directory to judge a path by.
printf '%s' "$(jq -nc --arg p "$st/triage-o+r-12.json" '{tool_name: "Write", tool_input: {file_path: $p, content: "[]"}}')" | HOME='' sh "$root/hooks/codex-bash.sh" >/dev/null 2>&1
[ $? = 2 ] || {
	echo "FAIL: a Write with no HOME wasn't denied"
	fail=1
}
# Malformed or unexpected input denies (fail closed).
check 2 ''
check 2 'not json'
check 2 '{'
check 2 '{}'
check 2 '[]'
check 2 'null'
check 2 '{"tool_name": "Bash"}'
check 2 '{"tool_name": "Bash", "tool_input": {}}'
check 2 '{"tool_name": "Bash", "tool_input": {"command": null}}'
check 2 '{"tool_name": "Bash", "tool_input": {"command": 5}}'
check 2 '{"tool_name": "Bash", "tool_input": {"command": ["gh", "pr", "view", "1"]}}'
check 2 '{"tool_input": {"command": "gh pr view 12"}}'
check 2 '{"tool_name": null, "tool_input": {"command": "gh pr view 12"}}'
check 2 '{"tool_name": "Write"}'
check 2 '{"tool_name": "Write", "tool_input": {}}'
check 2 '{"tool_name": "Write", "tool_input": {"file_path": null}}'
check 2 '{"tool_name": "Write", "tool_input": {"file_path": 5}}'
check 2 '{"tool_name": "Write", "tool_input": {"file_path": ["a"]}}'
check 2 '{"tool_name": "Write", "tool_input": {"command": "gh pr view 12"}}'
# Denied: any other tool, even with an allowed-looking input.
check 2 '{"tool_name": "Edit", "tool_input": {"file_path": "x", "command": "gh pr view 12"}}'
check 2 '{"tool_name": "Read", "tool_input": {"file_path": "x"}}'
check 2 '{"tool_name": "bash", "tool_input": {"command": "gh pr view 12"}}'
check 2 '{"tool_name": "Agent", "tool_input": {"prompt": "x"}}'
check 2 '{"tool_name": "mcp__github__add_issue_comment", "tool_input": {}}'
# A Write's content is not the hook's to judge (codex-triage.sh validates it), but a Bash call's file_path is
# not a Write's: a Bash input that carries one allows nothing.
check 2 '{"tool_name": "Bash", "tool_input": {"file_path": "x", "command": "rm x"}}'

# A denial says what is allowed, on stderr.
printf '%s' '{"tool_name": "Bash", "tool_input": {"command": "rm x"}}' | sh "$root/hooks/codex-bash.sh" >/dev/null 2>"$tmp/err"
grep -q 'codex-round.sh' "$tmp/err" || {
	echo "FAIL: a denial doesn't name the allowed forms"
	fail=1
}
# A denied poll of a background wait says what to do instead: call the wait again in the foreground. Only
# those commands say so (a denial of anything else doesn't mention it), and every form stays denied.
for poll in 'sleep 60' 'cat /x/out' 'tail -f /x/out' 'head /x/out' 'sleep 60; cat /x/out' 'cat /x/out | tail'; do
	expect 2 "$poll"
	grep -q "don't poll: run codex-wait.sh again in the foreground" "$tmp/err" || {
		echo "FAIL: the denial of '$poll' doesn't tell the agent to wait in the foreground"
		fail=1
	}
done
for other in 'rm x' 'git log' "$ship/codex-wait.sh" 'gh pr merge 12' 'catalog x' 'sleeping 60'; do
	expect 2 "$other"
	if grep -q "don't poll" "$tmp/err"; then
		echo "FAIL: the denial of '$other' mentions polling"
		fail=1
	fi
done
# A backgrounded call denies (claude-ship #171): ship-codex's waits run in the foreground, or its parent gets an
# interim result. false, absent and null are the foreground. Whatever the field holds, the command is judged too.
bg() {
	jq -nc --arg c "$2" --argjson b "$1" '{tool_name: "Bash", tool_input: {command: $c, run_in_background: $b}}'
}
check 2 "$(bg true "$ship/codex-wait.sh 12")"
check 2 "$(bg '"true"' "$ship/codex-wait.sh 12")"
check 2 "$(bg 1 "$ship/codex-wait.sh 12")"
check 2 "$(bg '"false"' "$ship/codex-wait.sh 12")"
check 2 "$(bg 0 "$ship/codex-wait.sh 12")"
check 2 "$(bg '[]' "$ship/codex-wait.sh 12")"
check 2 "$(bg '{}' "$ship/codex-wait.sh 12")"
check 2 "$(bg true "CODEX_WAIT_SECS=300 $ship/codex-wait.sh 12")"
check 2 "$(bg true "CI_WAIT_POLLS=10 $ship/ci-failures.sh 12 o/r --wait")"
check 2 "$(bg true 'gh pr view 12')"
check 2 "$(bg true 'sleep 5')"
check 2 "$(bg false 'sleep 5')"
check 0 "$(bg false "$ship/codex-wait.sh 12")"
check 0 "$(bg null "$ship/codex-wait.sh 12")"
check 0 "$(bg false "CODEX_WAIT_SECS=300 $ship/codex-wait.sh 12")"
check 0 "$(bg false "CI_WAIT_POLLS=10 $ship/ci-failures.sh 12 o/r --wait")"
check 0 "$(bg false 'gh pr view 12')"
# A Write ignores the field.
check 0 "$(jq -nc --arg p "$st/triage-o+r-12.json" '{tool_name: "Write", tool_input: {file_path: $p, content: "[]", run_in_background: true}}')"
check 2 "$(bg true "$ship/codex-wait.sh 12")"
grep -q "Run it in the foreground (no run_in_background), and never end your turn before it returns a result." "$tmp/err" || {
	echo "FAIL: the denial of a backgrounded call doesn't tell the agent to run it in the foreground"
	fail=1
}
grep -q 'codex-round.sh' "$tmp/err" || {
	echo "FAIL: the denial of a backgrounded call doesn't name the allowed forms"
	fail=1
}
# The foreground hint is for a backgrounded call only.
expect 2 "$ship/codex-wait.sh"
if grep -q 'run_in_background' "$tmp/err"; then
	echo "FAIL: the denial of a foreground call mentions run_in_background"
	fail=1
fi
# CI_WAIT_POLLS: the --wait poll count, digits only, and only before ci-failures.sh.
expect 0 "CI_WAIT_POLLS=10 $ship/ci-failures.sh 12 o/r --wait"
expect 0 "CI_WAIT_POLLS=1 $ship/ci-failures.sh 12 o/r"
expect 0 "CI_WAIT_POLLS=123456789 $ship/ci-failures.sh 12 o/r --wait"
expect 2 "CI_WAIT_POLLS=1234567890 $ship/ci-failures.sh 12 o/r --wait"
expect 2 "CI_WAIT_POLLS=abc $ship/ci-failures.sh 12 o/r --wait"
expect 2 "CI_WAIT_POLLS= $ship/ci-failures.sh 12 o/r --wait"
expect 2 "CI_WAIT_POLLS=-1 $ship/ci-failures.sh 12 o/r --wait"
expect 2 "CI_WAIT_POLLS=1.5 $ship/ci-failures.sh 12 o/r --wait"
expect 2 "CI_WAIT_POLLS=10 CI_WAIT_POLLS=1 $ship/ci-failures.sh 12 o/r --wait"
expect 2 "CI_WAIT_POLLS=10 CODEX_WAIT_SECS=300 $ship/ci-failures.sh 12 o/r --wait"
expect 2 "CODEX_WAIT_SECS=300 CI_WAIT_POLLS=10 $ship/ci-failures.sh 12 o/r --wait"
expect 2 "CI_WAIT_POLLS=10 $ship/codex-wait.sh 12"
expect 2 "CI_WAIT_POLLS=10 $ship/codex-round.sh 12"
expect 2 "CI_WAIT_POLLS=10 $ship/codex-findings.sh 12"
expect 2 "CI_WAIT_POLLS=10 $ship/codex-request.sh 12 o/r $sha"
expect 2 "CI_WAIT_POLLS=10 gh pr view 12"
expect 2 "CI_WAIT_POLLS=10 PATH=/tmp/x $ship/ci-failures.sh 12 o/r --wait"
expect 2 "CI_WAIT_POLLS=10 $ship/ci-failures.sh 12 o/r --wait; rm x"
expect 2 "CI_WAIT_POLLS=10"
# A hook registered as a command needs its execute bit (claude-ship #69).
[ -x "$root/hooks/codex-bash.sh" ] || {
	echo "FAIL: hooks/codex-bash.sh isn't executable"
	fail=1
}

[ "$fail" = 0 ] && echo "codex-bash: all passed"
exit "$fail"
