#!/bin/sh
# Tests the review gate's check against Bash commands that write its own files and state: a write blocks,
# while reading them, or redirecting only to another descriptor or /dev/null, passes (claude-ship #21).
# The commands are literal text for the gate to read, so `~` in them must stay unexpanded.
# shellcheck disable=SC2088
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
printf '#!/bin/sh\necho true\n' >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
fail=0

# expect <exit code> <command>: runs the gate on a Bash call of the command, outside any git repo.
expect() {
	jq -nc --arg c "$2" --arg d "$tmp" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
		HOME=$tmp/home PATH=$tmp/bin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	if [ "$rc" != "$1" ]; then
		echo "FAIL (exit $rc, want $1): $2"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}

# Reads and descriptor-only redirects pass.
expect 0 '~/.claude/skills/ship/codex-request.sh 29 2>&1 | tail -3'
expect 0 '~/.claude/skills/ship/codex-wait.sh 29 2>/dev/null'
expect 0 '~/.claude/skills/ship/codex-wait.sh 29 >/dev/null 2>&1'
expect 0 '~/.claude/skills/ship/codex-wait.sh 29 &>/dev/null'
expect 0 'ls ~/x/.git/review-gate/ >&2'
expect 0 'cat ~/.claude/hooks/review-prompt.md'
expect 0 "sh -c 'cat ~/.claude/hooks/review-gate.sh >/dev/null'"
expect 0 'sh -c "cat ~/.claude/hooks/review-gate.sh 2>&1"'
expect 0 "sh -c 'cat ~/.claude/hooks/review-gate.sh >&2'"
expect 0 '~/.claude/hooks/p3-issue.sh acme/app /tmp/s/finding.json 2>&1'
expect 0 'gh issue create --title t --body "~/.claude/skills/ship/codex-request.sh 29 2>&1 | tail"'

# Writes block, by redirect or by tool.
expect 2 'echo x > ~/.claude/hooks/review-gate.sh'
expect 2 'echo x >> $HOME/.claude/settings.json'
expect 2 'echo x 2>&1 >~/.claude/hooks/x'
expect 2 'echo x &> ~/.claude/hooks/x'
expect 2 'echo x >| ~/.claude/hooks/x'
expect 2 'echo x 2>/dev/null >~/.claude/skills/ship/SKILL.md'
expect 2 'echo x >/dev/null,~/.claude/skills/ship/SKILL.md'
expect 2 'cat ~/.claude/hooks/review-gate.sh >/dev/null,x'
expect 2 'cat ~/.claude/hooks/review-gate.sh >&2,x'
expect 2 "cat ~/.claude/hooks/review-gate.sh >/dev/null'x'"
expect 2 "cat ~/.claude/hooks/review-gate.sh >&2'.txt'"
expect 2 ': > /repo/.git/review-gate/abc.pass'
expect 2 'cd ~/.claude/hooks && echo x >review-gate.sh'
# `>&1/…` is a file named after the digits, not a descriptor.
expect 2 ': >&1/../.git/review-gate/abc.waived'
expect 2 ': 2>&-x/.git/review-gate/abc.pass'
expect 2 "echo \$'x' > ~/.claude/hooks/x"
# A quoted `>` may still redirect, inside a shell or interpreter the command runs.
expect 2 'sh -c "echo x > ~/.claude/hooks/review-gate.sh"'
expect 2 "bash -c 'echo x >> ~/.claude/settings.json'"
expect 2 "eval 'echo x > /repo/.git/review-gate/abc.pass'"
expect 2 "awk 'BEGIN { print \"x\" > \"/repo/.git/review-gate/abc.pass\" }'"
expect 2 'gh issue create --title t --body "echo x > ~/.claude/hooks/x"'
expect 2 'cp /tmp/x ~/.claude/hooks/review-gate.sh'
expect 2 'echo x | tee ~/.claude/skills/ship/SKILL.md'
expect 2 'sed -i s/a/b/ ~/.claude/hooks/review-prompt.md'
expect 2 'rm -rf /repo/.git/review-gate'
expect 2 'jq ".disableAllHooks = true" s.json > .claude/settings.local.json'
expect 2 'echo x > ~/.claude/agents/ship-implementer.md'
expect 2 'cp /tmp/x $HOME/.claude/agents/ship-explorer.md'
expect 0 'cat ~/.claude/agents/ship-implementer.md'
# Other agents are the user's own, outside the gate's files.
expect 0 'echo x > ~/.claude/agents/mine.md'

# write <exit code> <path>: the Write tool on the path.
write() {
	jq -nc --arg p "$2" '{tool_name: "Write", tool_input: {file_path: $p, content: "x"}}' |
		HOME=$tmp/home PATH=$tmp/bin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	if [ "$rc" != "$1" ]; then
		echo "FAIL (exit $rc, want $1): Write $2"
		fail=1
	fi
}
write 2 "$tmp/home/.claude/agents/ship-implementer.md"
write 2 "$tmp/home/.claude/skills/ship/orchestrate.md"
write 0 "$tmp/home/.claude/agents/mine.md"

[ "$fail" = 0 ] && echo "gate-tamper: ok"
exit "$fail"
