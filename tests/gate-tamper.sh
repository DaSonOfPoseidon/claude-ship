#!/bin/sh
# Tests the review gate's check against Bash commands that write its own files and state: a write blocks,
# while reading them, or redirecting only to another descriptor or /dev/null, passes (claude-ship #21).
# The commands are literal text for the gate to read, so `~` in them must stay unexpanded.
# shellcheck disable=SC2088
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/lib/shfmt.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
link_shfmt "$tmp/home"
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
expect 2 'echo x > ~/.claude/hooks/review-lib.sh'
expect 0 'cat ~/.claude/hooks/review-lib.sh'
expect 2 'rm -rf /repo/.git/review-gate'
expect 2 'jq ".disableAllHooks = true" s.json > .claude/settings.local.json'
expect 2 'echo x > ~/.claude/agents/ship-implementer.md'
expect 2 'cp /tmp/x $HOME/.claude/agents/ship-explorer.md'
expect 0 'cat ~/.claude/agents/ship-implementer.md'
# Other agents are the user's own, outside the gate's files.
expect 0 'echo x > ~/.claude/agents/mine.md'

# The check reads the command's syntax tree (shfmt), so a protected path in a file name, a quoted string or a heredoc
# body is not a write (claude-ship #135, #40).
expect 0 'head -15 agents/ship-explorer.md; ls hooks; grep -n "permissionDecision\|allow" hooks/explorer-bash.sh | head; grep -n "settings" install.sh | head; jq '"'.permissions'"' ~/.claude/settings.json'
expect 0 'ls >"/dev/null" ~/.claude/hooks'
expect 0 'cat ~/.claude/hooks/review-gate.sh 2>"/dev/null"'
expect 0 'gh issue create --title t --body "~/.claude/skills/ship/codex-wait.sh <PR> stalls"'
expect 0 'rm .git/claude-ship/plan-x.md && ls -l ~/.claude/agents/ship-codex.md'
expect 0 'cat <<EOF
rm ~/.claude/hooks/x is what the old check read as a write
EOF'
expect 0 "git commit -m 'docs: cp of ~/.claude/hooks/x is read-only'"
# A command that names a protected path and writes a file elsewhere blocks, as it did before; /dev/null is no file.
expect 2 'echo x >/tmp/y && cat ~/.claude/hooks/x | head -3'
expect 0 'echo x >/dev/null && cat ~/.claude/hooks/x | head -3 2>&1'
# A write command with a protected literal argument blocks even when it only reads that file (cp's source): that is
# stricter than needed, and it is what the text check did.
expect 2 'cp ~/.claude/hooks/review-gate.sh /tmp/x'

# Writes the tree shows through wrappers, nested shells, find and redirects.
expect 2 "bash -c 'rm ~/.claude/hooks/review-gate.sh'"
expect 2 'eval "rm ~/.claude/hooks/review-gate.sh"'
expect 2 'd=~/.claude/hooks; rm $d/review-gate.sh'
expect 2 'cd ~/.claude/hooks && rm review-gate.sh'
expect 2 'find ~/.claude/hooks -name x -exec rm {} +'
expect 2 'find ~/.claude/hooks -name x -exec rm {} \;'
expect 2 'find ~/.claude/hooks -name x -delete'
# A shell that find or xargs hands arguments to runs on files the command line doesn't show.
expect 2 "find ~/.claude/hooks -type f -exec sh -c 'rm {}' \\;"
expect 2 "ls ~/.claude/hooks | xargs sh -c 'rm \"\$@\"' x"
expect 0 "find . -name '*.md' -exec grep -l x {} +"
expect 2 'env FOO=1 rm ~/.claude/hooks/x'
expect 2 'sudo tee ~/.claude/settings.json </tmp/x'
expect 2 'echo x | tee -a ~/.claude/hooks/x'
expect 2 'echo x >~/.claude/bin/shfmt'
expect 2 'cp /tmp/x ~/.claude/bin/shfmt'
expect 2 'nice -n 5 timeout 9 rm ~/.claude/hooks/x'
expect 2 'command rm ~/.claude/hooks/x'
expect 2 'echo ~/.claude/hooks/x | xargs rm'
expect 2 'echo $(rm ~/.claude/hooks/x)'
expect 2 'cat <<EOF
$(rm ~/.claude/hooks/x)
EOF'
expect 2 'sh -c "bash -c \"rm ~/.claude/hooks/x\""'
expect 2 'echo rm ~/.claude/hooks/x | sh'
expect 2 'python3 - <<EOF
open("/x/.git/review-gate/a.pass", "w")
EOF'
expect 2 'cat ~/.claude/hooks/x >/tmp/copy'
expect 2 'sed -ni s/a/b/ ~/.claude/hooks/review-prompt.md'
expect 2 'sed --in-place s/a/b/ ~/.claude/settings.json'
expect 0 'sed -n s/a/b/p ~/.claude/hooks/review-prompt.md'
# A write redirect's target is read from the tree, not from the text around it.
expect 2 ': >&1/../.git/review-gate/abc.waived'
expect 2 'echo x 2>~/.claude/hooks/x'
expect 2 'echo x >"~/.claude/hooks/x"'
expect 2 "echo x >'~/.claude/hooks/x'"
expect 2 'echo x <>~/.claude/hooks/x'
expect 2 'echo x &>>~/.claude/hooks/x'
expect 2 'echo x &>~/.claude/hooks/x'
expect 2 'echo x >|~/.claude/hooks/x'
expect 2 '{ echo x; } > ~/.claude/hooks/x'
expect 0 'cat < ~/.claude/hooks/x'
expect 0 'cat <~/.claude/hooks/x >/dev/stdout'
# What the tree can't settle falls back to the text check (a variable, a command substitution or a glob in a word,
# a protected `cd`, `disableAllHooks`): it reads `cat $(echo …)` as it always did, a read, and blocks a write.
expect 0 'cat $(echo ~/.claude/hooks/x)'
expect 2 'rm $(echo ~/.claude/hooks/x)'
expect 2 'rm ~/.claude/hooks/*'
expect 2 'x=1; rm ~/.claude/hooks/$x'
expect 2 'pushd ~/.claude/hooks && echo x >review-gate.sh'
expect 2 'cd "$HOME/.claude/hooks" && echo x >review-gate.sh'
expect 2 'echo disableAllHooks >.claude/settings.local.json'
expect 0 'echo disableAllHooks'
# Only literal words are read as paths: a variable holding the path hides it from the tree, and the fallback sees it.
expect 2 'f=~/.claude/hooks/x; echo y >$f'
expect 2 'f=~/.claude/hooks/x; echo y | tee $f'
# Escapes and quoting inside a word are resolved, not matched as text.
expect 2 'rm ~/.claude/ho\oks/x'
expect 2 "rm ~/.claude/'hooks'/x"
expect 2 'rm ~/.claude/"hooks"/x'
expect 2 'rm ~/.claude/ho""oks/x'

# The home directory written out is as protected as `~`.
expect 2 "rm $tmp/home/.claude/hooks/x"
expect 2 "echo x >$tmp/home/.claude/settings.json"
# Every construct that runs a command reaches the tree walk.
expect 2 "sh -xc 'rm ~/.claude/hooks/x'"
expect 2 'time rm ~/.claude/hooks/x'
expect 2 '! rm ~/.claude/hooks/x'
expect 2 'if true; then rm ~/.claude/hooks/x; fi'
expect 2 'f() { rm ~/.claude/hooks/x; }; f'
expect 2 'diff <(rm ~/.claude/hooks/x) /dev/null'
expect 2 'true && { rm ~/.claude/hooks/x; }'
expect 2 '(cd /tmp; rm ~/.claude/hooks/x)'
# A writing tool behind a wrapper the gate doesn't list, or a `>` in one word with a protected path in another (an awk
# program next to its file), is read by the text check, as before (the gate's own review of this change, #135).
expect 2 'flock /tmp/l rm ~/.claude/hooks/x'
expect 2 'watch rm ~/.claude/hooks/x'
expect 2 'ionice -c3 rm ~/.claude/hooks/x'
expect 2 'busybox rm ~/.claude/hooks/x'
expect 2 'taskset 1 cp /tmp/x ~/.claude/hooks/x'
expect 2 'strace -o /tmp/t sed -i s/a/b/ ~/.claude/hooks/x'
# A word that is a command line (it starts with a writing tool, or one follows `;`, `&`, `|`, `(`, `{` or a quote) and
# names a protected path writes: `watch 'rm …'`, `su -c`, `ssh host '…'`, awk's system(). Prose that mentions a tool
# (a commit message, an issue body) is not a command line.
expect 2 "awk 'BEGIN{system(\"rm ~/.claude/hooks/x\")}'"
expect 2 "watch 'rm ~/.claude/hooks/x'"
expect 2 "su -c 'rm ~/.claude/hooks/x'"
expect 2 "ssh host 'cd /tmp; rm ~/.claude/hooks/x'"
expect 2 "flock -c 'sudo tee ~/.claude/settings.json' /tmp/l"
expect 2 "ssh host 'echo y | tee -a ~/.claude/hooks/x'"
expect 0 'gh issue create --title t --body "the rm of ~/.claude/hooks/x and a cp of ~/.claude/settings.json"'
expect 0 "ssh host 'cat ~/.claude/hooks/x'"
expect 0 "watch 'sed -n 1p ~/.claude/hooks/x'"
expect 0 'ionice -c3 ls ~/.claude/hooks'
expect 0 'flock /tmp/l ls ~/.claude/hooks'
expect 2 "awk '{ print > \"out\" }' ~/.claude/hooks/x"
expect 2 "awk '{ print > \"/tmp/o\" }' ~/.claude/settings.json"
expect 0 "awk '{ print }' ~/.claude/settings.json"
# A wrapper option the gate doesn't know, a script on stdin and a pipe into a writing tool fall back to the text.
expect 2 'sudo -i rm ~/.claude/hooks/x'
expect 2 'timeout --bogus 5 rm ~/.claude/hooks/x'
expect 2 "env -S 'rm ~/.claude/hooks/x'"
expect 2 'ls ~/.claude/hooks | xargs rm'
expect 0 'ls ~/.claude/hooks | xargs ls -l'
expect 2 'bash <<EOF
rm ~/.claude/hooks/x
EOF'
expect 0 'bash <<EOF
ls ~/.claude/hooks
EOF'
expect 0 'sh tests/gate-tamper.sh'
expect 0 "sh -c 'ls ~/.claude/hooks'"
# Shells nested past the depth cap fall back too.
nest='rm ~/.claude/hooks/x'
for _ in 1 2 3 4 5; do nest="sh -c '$(printf '%s' "$nest" | sed "s/'/'\\\\''/g")'"; done
expect 2 "$nest"
nest='ls ~/.claude/hooks'
for _ in 1 2 3 4 5; do nest="sh -c '$(printf '%s' "$nest" | sed "s/'/'\\\\''/g")'"; done
expect 0 "$nest"

# The parse fails closed: no shfmt, or a command it can't read, blocks the call.
nohome=$tmp/nohome
mkdir -p "$nohome"
jq -nc '{tool_name: "Bash", tool_input: {command: "ls"}}' | HOME=$nohome PATH=$tmp/bin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
rc=$?
if [ "$rc" != 2 ] || ! grep -q 'shfmt' "$tmp/err"; then
	echo "FAIL (exit $rc, want 2 naming shfmt): no shfmt in HOME/.claude/bin"
	sed 's/^/  /' "$tmp/err"
	fail=1
fi
mkdir -p "$nohome/.claude/bin"
printf '#!/bin/sh\nexit 0\n' >"$nohome/.claude/bin/shfmt"
chmod +x "$nohome/.claude/bin/shfmt"
jq -nc '{tool_name: "Bash", tool_input: {command: "ls"}}' | HOME=$nohome PATH=$tmp/bin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
rc=$?
if [ "$rc" != 2 ] || ! grep -q 'unreadable\|couldn.t read' "$tmp/err"; then
	echo "FAIL (exit $rc, want 2 unreadable): a shfmt that prints nothing"
	sed 's/^/  /' "$tmp/err"
	fail=1
fi
chmod -x "$nohome/.claude/bin/shfmt"
jq -nc '{tool_name: "Bash", tool_input: {command: "ls"}}' | HOME=$nohome PATH=$tmp/bin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
rc=$?
if [ "$rc" != 2 ] || ! grep -q 'shfmt' "$tmp/err"; then
	echo "FAIL (exit $rc, want 2 naming shfmt): a shfmt that isn't executable"
	sed 's/^/  /' "$tmp/err"
	fail=1
fi
printf '#!/bin/sh\necho not json\n' >"$nohome/.claude/bin/shfmt"
chmod +x "$nohome/.claude/bin/shfmt"
jq -nc '{tool_name: "Bash", tool_input: {command: "ls"}}' | HOME=$nohome PATH=$tmp/bin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
rc=$?
if [ "$rc" != 2 ] || ! grep -q 'unreadable\|couldn.t read' "$tmp/err"; then
	echo "FAIL (exit $rc, want 2 unreadable): a shfmt that prints something else than JSON"
	sed 's/^/  /' "$tmp/err"
	fail=1
fi
expect 2 'echo "unterminated'
grep -q "couldn't parse" "$tmp/err" || {
	echo "FAIL: an unparsable command should say the gate couldn't parse it"
	cat "$tmp/err"
	fail=1
}
expect 2 "echo 'x"
expect 2 'if then fi'
expect 0 ''

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
write 2 "$tmp/home/.claude/hooks/review-lib.sh"
write 2 "$tmp/home/.claude/bin/shfmt"
write 0 "$tmp/home/.claude/agents/mine.md"
write 0 "$tmp/home/.claude/bin-notes.md"

[ "$fail" = 0 ] && echo "gate-tamper: ok"
exit "$fail"
