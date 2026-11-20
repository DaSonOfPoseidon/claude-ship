#!/bin/sh
# Tests the review gate's tamper check: a Bash command that names a protected path literally and writes it blocks; anything
# else passes (docs/gate.md › Tamper protection). The check reads the command's syntax tree and compares only literal
# words, so what a command builds at run time, a `cd`, an interpreter and the like are out of its scope: the installed
# files are immutable (chattr +i) and that flag holds them. The commands are literal text for the gate to read, so `~` in
# them must stay unexpanded.
# shellcheck disable=SC2088
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/lib/shfmt.sh"
. "$root/tests/lib/gitenv.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
link_shfmt "$tmp/home"
gate_git_hooks "$tmp/home"
printf '#!/bin/sh\necho true\n' >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
fail=0

# gate_call <stderr file> <working directory> <command>: runs the gate on a Bash call of the command, outside any git repo.
gate_call() {
	jq -nc --arg c "$3" --arg d "$2" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
		HOME=$tmp/home PATH=$tmp/bin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$1"
}
# expectc <exit code> <working directory> <command>: checks the gate's exit code for the command. The cases run a few at a
# time in the background (each gate run is a handful of processes, and there are hundreds) and report into $tmp/fails.
n=0
: >"$tmp/fails"
expectc() {
	n=$((n + 1))
	(
		gate_call "$tmp/err.$n" "$2" "$3"
		rc=$?
		if [ "$rc" != "$1" ]; then
			out=$(
				printf 'FAIL (exit %s, want %s; cwd %s): %s\n' "$rc" "$1" "$2" "$3"
				sed 's/^/  /' "$tmp/err.$n"
			)
			printf '%s\n' "$out" >>"$tmp/fails"
		fi
	) &
	[ $((n % 8)) != 0 ] || wait
}
# expect <exit code> <command>: the same from an unprotected working directory.
expect() { expectc "$1" "$tmp" "$2"; }
# expect_err <exit code> <command>: one case run on its own, leaving the gate's message in $tmp/err.
expect_err() {
	wait
	gate_call "$tmp/err" "$tmp" "$2"
	rc=$?
	if [ "$rc" != "$1" ]; then
		echo "FAIL (exit $rc, want $1): $2"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}

h=$tmp/home
# `up` goes from the working directory ($tmp) to the root: a relative path that reaches / again.
depth=$(printf '%s' "$tmp" | tr -cd / | wc -c)
up=
i=0
while [ "$i" -lt "$depth" ]; do
	up=$up../
	i=$((i + 1))
done

# --- What blocks -----------------------------------------------------------------------------------------------------

# Each writing tool against each protected root, in the three forms a path is written: `~`, `$HOME` and the home directory
# itself. The writers are cp mv rm rmdir ln install tee touch truncate dd rsync unlink shred mkdir chmod chown chgrp tar
# unzip patch, and sed and perl with an in-place option; `@` stands for the path. The form rotates with the writer and the
# root, so every pair has one form, and each writer and each root gets all three.
writers='cp /tmp/x @|mv /tmp/x @|rm -rf @|rmdir @|ln -s /tmp/x @|install -m 644 /tmp/x @|tee @|touch @|truncate -s 0 @|dd of=@|rsync /tmp/x @|unlink @|shred @|mkdir @|chmod 600 @|chown me @|chgrp me @|tar xf a.tar -C @|unzip a.zip -d @|patch @ /tmp/p|sed -i s/a/b/ @|perl -pi -e s/a/b/ @'
# The roots below ~/.claude (hooks, settings, skills/ship, agents/ship-, bin/, git-hooks); the managed directory and the
# gate's state follow, which have no `~` form.
claude_roots='hooks/review-gate.sh settings.json skills/ship/SKILL.md agents/ship-implementer.md bin/shfmt git-hooks/pre-push'
oldifs=$IFS
IFS='|'
set -f
# shellcheck disable=SC2086 # the writer list is split on `|` on purpose
set -- $writers
set +f
IFS=$oldifs
wi=0
for w in "$@"; do
	ri=0
	for r in $claude_roots; do
		case $(((wi + ri) % 3)) in
		0) p="~/.claude/$r" ;;
		1) p="\$HOME/.claude/$r" ;;
		2) p="$h/.claude/$r" ;;
		esac
		expect 2 "$(printf '%s' "$w" | sed "s#@#$p#")"
		ri=$((ri + 1))
	done
	for p in /etc/claude-code/managed-settings.d/claude-ship.json /repo/.git/review-gate/abc.pass .git/review-gate/abc.pass; do
		expect 2 "$(printf '%s' "$w" | sed "s#@#$p#")"
	done
	wi=$((wi + 1))
done
# The directories themselves, and the managed directory, are protected like what is in them.
expect 2 'rm -rf ~/.claude/hooks'
expect 2 'rm -rf ~/.claude/skills/ship'
expect 2 'mv ~/.claude/bin /tmp/bin'
expect 2 'rm -rf /etc/claude-code'
expect 2 'rm -rf .git/review-gate'
expect 2 'rm -rf /repo/.git/review-gate'

# Redirects, in every form of every root.
for r in $claude_roots; do
	for p in "~/.claude/$r" "\$HOME/.claude/$r" "\"\${HOME}/.claude/$r\"" "$h/.claude/$r"; do
		expect 2 "echo x > $p"
		expect 2 "echo x >> $p"
	done
done
for p in /etc/claude-code/managed-settings.json /repo/.git/review-gate/abc.pass .git/review-gate/abc.waived; do
	expect 2 "echo x > $p"
	expect 2 "echo x >> $p"
done
expect 2 'echo x 2>&1 >~/.claude/hooks/x'
expect 2 'echo x 2>~/.claude/hooks/x'
expect 2 'echo x &> ~/.claude/hooks/x'
expect 2 'echo x &>> ~/.claude/hooks/x'
expect 2 'echo x >| ~/.claude/hooks/x'
expect 2 'echo x <>~/.claude/hooks/x'
expect 2 'echo x 2>/dev/null >~/.claude/skills/ship/SKILL.md'
expect 2 '{ echo x; } > ~/.claude/hooks/x'
expect 2 ': > /repo/.git/review-gate/abc.pass'
expect 2 ': >&1/../.git/review-gate/abc.waived'
expect 2 ': 2>&-x/.git/review-gate/abc.pass'
expect 2 'echo x >"~/.claude/hooks/x"'
expect 2 "echo x >'~/.claude/hooks/x'"
expect 2 'echo x > ~/.claude/agents/ship-implementer.md'
expect 2 "echo x >$h/.claude/git-hooks/pre-commit"
expect 2 'cat >~/.claude/hooks/x <<EOF
data
EOF'
expect 2 'cat <<EOF >~/.claude/hooks/x
data
EOF'

# A write anywhere in the tree: after a pipe, in a chain, in a substitution, a block, an `if`, a function, a subshell, after
# `!` or `time`. Every simple command in it is read.
expect 2 'echo x | tee -a ~/.claude/hooks/x'
expect 2 'echo $(rm ~/.claude/hooks/x)'
expect 2 'echo `rm ~/.claude/hooks/x`'
expect 2 'cat <<EOF
$(rm ~/.claude/hooks/x)
EOF'
expect 2 'diff <(rm ~/.claude/hooks/x) /dev/null'
expect 2 'true && { rm ~/.claude/hooks/x; }'
expect 2 '(cd /tmp; rm ~/.claude/hooks/x)'
expect 2 'if true; then rm ~/.claude/hooks/x; fi'
expect 2 'f() { rm ~/.claude/hooks/x; }; f'
expect 2 '! rm ~/.claude/hooks/x'
expect 2 'time rm ~/.claude/hooks/x'
expect 2 'rm /tmp/y && rm ~/.claude/hooks/x'
expect 2 'ls | rm ~/.claude/hooks/x'
expect 2 'gh issue create --title t --body "$(rm ~/.claude/hooks/x)"'

# The wrappers `eff` knows, and `find`.
expect 2 'env FOO=1 rm ~/.claude/hooks/x'
expect 2 'sudo tee ~/.claude/settings.json </tmp/x'
expect 2 'nice -n 5 timeout 9 rm ~/.claude/hooks/x'
expect 2 'command rm ~/.claude/hooks/x'
expect 2 '/bin/rm ~/.claude/hooks/x'
expect 2 'find ~/.claude/hooks -name x -exec rm {} +'
expect 2 'find ~/.claude/hooks -name x -exec rm {} \;'
expect 2 'find ~/.claude/hooks -name x -delete'
# A string a shell runs is parsed again, to a depth of 3.
expect 2 "bash -c 'rm ~/.claude/hooks/review-gate.sh'"
expect 2 'sh -c "echo x > ~/.claude/hooks/review-gate.sh"'
expect 2 "sh -xc 'rm ~/.claude/hooks/x'"
expect 2 'eval "rm ~/.claude/hooks/review-gate.sh"'
expect 2 "eval 'echo x > /repo/.git/review-gate/abc.pass'"
expect 2 'sh -c "bash -c \"rm ~/.claude/hooks/x\""'
expect 2 'sh -c "chmod -x ~/.claude/git-hooks/pre-push"'

# The edge cases of the path: absolute, doubled slashes, `.` and `..`, quoting, and the working directory for a relative word.
expect 2 "rm $h/.claude/hooks/x"
expect 2 "rm /$h//.claude//hooks/x"
expect 2 'rm ~/.claude/./hooks/x'
expect 2 'rm ~/.claude//hooks/x'
expect 2 'rm ~/.claude/hooks/./x'
expect 2 'rm ~/.claude/hooks/../hooks/x'
expect 2 'rm ~/.claude/projects/../hooks/x'
expect 2 "rm $h/../home/.claude/hooks/x"
expect 2 "rm $up${tmp#/}/home/.claude/hooks/x"
expect 2 'echo x > ~/.claude/./hooks/review-gate.sh'
expect 2 'echo x > ~/.claude/hooks/../hooks/x'
expect 2 'rm ~/.claude/ho\oks/x'
expect 2 "rm ~/.claude/'hooks'/x"
expect 2 'rm ~/.claude/"hooks"/x'
expect 2 'rm ~/.claude/ho""oks/x'
expect 2 'rm "$HOME/.claude/hooks/x"'
expect 2 'rm ${HOME}/.claude/hooks/x'
expect 2 'rm .git/review-gate/abc.pass'
expect 2 'rm /repo/.git/review-gate/abc.pass'
expect 2 'rm /etc//claude-code/managed-settings.json'
expect 2 'rm /etc/./claude-code/managed-settings.json'
expect 2 'rm /etc/claude-code/../claude-code/managed-settings.json'
expect 2 'rm /etc/claude-"code"/managed-settings.json'
expect 2 "rm '/etc/claude-code/managed-settings.json'"
expect 2 "cp x ${up}etc/claude-code/managed-settings.json"
# A relative word is resolved from the input's working directory, and from nothing else.
expectc 2 "$h/.claude/hooks" 'rm x'
expectc 2 "$h/.claude/hooks" 'rm -f x'
expectc 2 "$h/.claude/hooks" 'sudo rm x'
expectc 2 "$h/.claude/hooks" 'cp /tmp/a review-gate.sh'
expectc 2 "$h/.claude/hooks" 'echo hi > x'
expectc 2 "$h/.claude/hooks" 'tee x </tmp/a'
expectc 2 "$h/.claude/hooks" 'rm 1'
expectc 2 "$h/.claude/hooks" 'dd of=x'
expectc 2 "$h/.claude/hooks" 'sed -i s/a/b/ review-gate.sh'
expectc 2 "$h/.claude/hooks" ': > review-gate.sh'
expectc 2 "$h/.claude/hooks" 'cd /tmp/missing; : > review-gate.sh'
expectc 2 "$h/.claude" 'rm hooks/x'
expectc 2 "$h/.claude" 'rm ../.claude/hooks/x'
expectc 2 "$h/.claude" 'echo x > settings.json'
expectc 2 "$h" 'rm .claude/hooks/x'
expectc 2 /repo 'rm .git/review-gate/abc.pass'
expectc 2 /etc 'rm claude-code/managed-settings.json'
expectc 2 /etc/claude-code 'rm managed-settings.json'
# One narrow `cd`: a statement that is just `cd LITERAL`, or one on the left of `&&`, sets where later relative words and
# redirect targets resolve from, for the targets the immutable flag does not cover: the gate state, the settings and the lint config
# under ~/.claude (the cd's word has ~ and $HOME folded, and is relative to the cwd or to the cd before it).
expect 2 'cd ~/.claude && rm settings.json'
expect 2 'cd ~/.claude; echo x > settings.local.json'
expect 2 'cd repo/.git && rm -r review-gate'
expect 2 'cd repo/.git; touch review-gate/abc.pass'
expect 2 'cd /repo/.git/review-gate && touch abc.pass'
expect 2 'cd "$HOME/.claude" && rm settings.json'
expect 2 'cd ${HOME}/.claude && tee settings.json </tmp/a'
expect 2 'cd ~ && cd .claude && rm settings.json'
expect 2 'cd ~; cd .claude; echo x >> settings.json'
expect 2 'cd /tmp && cd ~/.claude && rm settings.json'
expect 2 'cd ~/.claude && ls && rm settings.json'
expect 2 'cd repo && cd .git && echo x > review-gate/abc.pass'
expect 2 'cd ~/.claude && sed -i s/a/b/ settings.json'
# Inside a protected directory the command's own name and its options are not paths, and a write elsewhere passes.
expectc 0 "$h/.claude/hooks" 'ls'
expectc 0 "$h/.claude/hooks" 'cat review-gate.sh'
expectc 0 "$h/.claude/hooks" 'rm /tmp/x'
expectc 0 "$h/.claude/hooks" 'rm -rf /tmp/x'
expectc 0 "$h/.claude/hooks" 'cp /tmp/a /tmp/b'
expectc 0 "$h/.claude/hooks" 'echo hi | tee /tmp/o'
expectc 0 "$h/.claude/hooks" 'sudo rm /tmp/x'
expectc 0 "$h/.claude/hooks" 'git status'
expectc 0 "$h/.claude/projects" 'rm x'
# The writes of the plan's edge-case table.
expect 2 'sed -i s/a/b/ ~/.claude/hooks/x'
expect 2 'sed -i.bak s/a/b/ ~/.claude/hooks/x'
expect 2 'sed -ni s/a/b/ ~/.claude/hooks/review-prompt.md'
expect 2 'sed --in-place s/a/b/ ~/.claude/settings.json'
expect 2 'sed -s --in-place=.bak s/a/b/ ~/.claude//settings.json'
expect 2 'perl -pi -e s/a/b/ ~/.claude/hooks/x'
expect 2 'perl -i.bak -pe s/a/b/ ~/.claude/hooks/x'
expect 2 'perl -pie s/a/b/ ~/.claude/hooks/x'
expect 2 'tar xf a.tar -C ~/.claude/hooks'
expect 2 'tar -C ~/.claude/hooks -xf a.tar'
expect 2 'tar cfz ~/.claude/hooks/a.tar.gz x'
expect 2 'tar --directory=~/.claude/hooks -xf a.tar'
expect 2 'cp --target-directory=~/.claude/./hooks a'
expect 2 'dd if=/dev/null of=~/.claude/hooks/x'
expect 2 'rm ~/.claude/./hooks/x ~/.claude/projects/p/memory/x.md'
# A write tool that only reads a protected file blocks too: the cp's source is a literal word of a writer.
expect 2 'cp ~/.claude/hooks/review-gate.sh /tmp/x'
expect 2 'tar -tf ~/.claude/hooks/a.tar'
# The git hook stubs, the ship agents, shfmt and the managed settings directory (claude-ship #189).
expect 2 'rm ~/.claude/git-hooks/pre-push'
expect 2 'echo exit 0 > ~/.claude/git-hooks/pre-push'
expect 2 'cp /tmp/x $HOME/.claude/agents/ship-explorer.md'
expect 2 'cp /tmp/x ~/.claude/bin/shfmt'
expect 2 'echo x > ~/.claude/claude-ship/lint'
expect 2 'echo "* off" >> $HOME/.claude/claude-ship/lint'
expect 2 'cp f ~/.claude/claude-ship/lint'
expect 2 'sed -i s/a/b/ ~/.claude/claude-ship/lint'
expect 2 'tee ~/.claude/claude-ship/lint </tmp/a'
expect 2 'cd ~/.claude && echo x > claude-ship/lint'
expect 2 'cd ~/.claude/claude-ship && rm lint'
expect 0 'cat ~/.claude/claude-ship/lint'
expect 0 'grep -n off ~/.claude/claude-ship/lint'
expect 0 'echo x > ~/.claude/state/claude-ship/triage-o+r-1.json'
expect 0 'echo x > ~/.claude/claude-ship-notes.md'
expect 0 'git commit --amend -m x'
expect 2 'git commit --no-verify -m x'
expect 2 'git commit -n -m x'
expect 2 'cp x /etc/claude-code/managed-settings.json'
expect 2 'mv /etc/claude-code/managed-settings.d /tmp/x'
expect 2 'echo x | tee /etc/claude-code/managed-settings.json'
expect 2 'sudo tee /etc/claude-code/managed-settings.d/x.json </tmp/x'
expect 2 'install -m 644 x /etc/claude-code/managed-settings.json'
expect 2 'tar -xf x.tar -C /etc/claude-code'
# `disableAllHooks` written into a settings file blocks, as for the Write tool: a project's own `.claude/settings` may
# change, but not to turn hooks off.
expect 2 'jq ".disableAllHooks = true" s.json > .claude/settings.local.json'
expect 2 'echo disableAllHooks >.claude/settings.local.json'
expect 2 'echo "{\"disableAllHooks\": true}" | tee .claude/settings.json'
expect 0 'echo disableAllHooks'
expect 0 'echo x >.claude/settings.local.json'
expect 0 'grep -n disableAllHooks docs/gate.md'
expect 0 'git commit -m "feat: block disableAllHooks"'
# A ship script run with its output sent to a protected place blocks (and to /tmp it passes, below).
expect 2 '~/.claude/skills/ship/token-report.sh 12 >~/.claude/hooks/out 2>&1'
expect 2 '~/.claude/skills/ship/token-report.sh 12 >/tmp/out 2>~/.claude/hooks/err'
expect 2 '~/.claude/skills/ship/token-report.sh 12 &>~/.claude/hooks/out'

# --- What passes -----------------------------------------------------------------------------------------------------

# Reads of every protected root, by the common read tools (the form rotates, as above).
ti=0
for t in cat 'grep -n x' 'rg x' 'diff -u' less 'ls -l' lsattr sha256sum; do
	ri=0
	for r in $claude_roots; do
		case $(((ti + ri) % 3)) in
		0) p="~/.claude/$r" ;;
		1) p="\$HOME/.claude/$r" ;;
		2) p="$h/.claude/$r" ;;
		esac
		expect 0 "$t $p"
		ri=$((ri + 1))
	done
	expect 0 "$t /etc/claude-code/managed-settings.d/claude-ship.json"
	expect 0 "$t .git/review-gate/abc.pass"
	ti=$((ti + 1))
done
expect 0 'diff ~/.claude/hooks/review-gate.sh /tmp/y'
expect 0 'ls -la /etc/claude-code /etc/claude-code/managed-settings.d'
expect 0 'lsattr -d /etc/claude-code'
expect 0 'jq . /etc/claude-code/managed-settings.json 2>&1 | head'
expect 0 'ls ~/x/.git/review-gate/ >&2'
expect 0 'cat ~/.claude/hooks/x | head -3'
expect 0 'cat < ~/.claude/hooks/x'
expect 0 'cat <~/.claude/hooks/x >/dev/stdout'
expect 0 'jq ".permissions" ~/.claude/settings.json'
expect 0 'sed -n p ~/.claude/hooks/x'
expect 0 'sed -n s/a/b/p ~/.claude/hooks/review-prompt.md'
expect 0 'sed -E -n s/a/b/p ~/.claude/hooks/review-prompt.md'
expect 0 'perl -ne "print if /x/" ~/.claude/hooks/x'
expect 0 'perl -MList::Util=sum -e 1 ~/.claude/hooks/x'
expect 0 'head -15 agents/ship-explorer.md; ls hooks; grep -n "permissionDecision\|allow" hooks/explorer-bash.sh | head; grep -n "settings" install.sh | head; jq '"'.permissions'"' ~/.claude/settings.json'
expect 0 'cat ~/.claude/./hooks/review-gate.sh'
expect 0 'ls ~/.claude//hooks'
# Reads that name a writing tool as an argument next to a protected file (#195).
expect 0 'grep curl ~/.claude/hooks/review-gate.sh'
expect 0 'grep -n tar ~/.claude/skills/ship/SKILL.md'
expect 0 'grep -rn "curl -o\|wget\|tar -x\|rm " ~/.claude/hooks'
expect 0 'grep -n sponge ~/.claude/hooks/review-gate.sh | head'
expect 0 'grep node ~/.claude/hooks/review-gate.sh'
# Descriptor-only redirects and /dev/null.
expect 0 '~/.claude/skills/ship/codex-request.sh 29 2>&1 | tail -3'
expect 0 '~/.claude/skills/ship/codex-wait.sh 29 2>/dev/null'
expect 0 '~/.claude/skills/ship/codex-wait.sh 29 >/dev/null 2>&1'
expect 0 '~/.claude/skills/ship/codex-wait.sh 29 &>/dev/null'
expect 0 'cat ~/.claude/hooks/review-gate.sh 2>"/dev/null"'
expect 0 'ls >"/dev/null" ~/.claude/hooks'
expect 0 'cat ~/.claude/hooks/review-gate.sh >&2'
expect 0 'cat ~/.claude/hooks/review-gate.sh >&-'
expect 0 "sh -c 'cat ~/.claude/hooks/review-gate.sh >/dev/null'"
expect 0 'sh -c "cat ~/.claude/hooks/review-gate.sh 2>&1"'
expect 0 "sh -c 'cat ~/.claude/hooks/review-gate.sh >&2'"
expect 0 "sh -c 'ls ~/.claude/hooks'"
expect 0 '~/.claude/hooks/p3-issue.sh acme/app /tmp/s/finding.json 2>&1'
# Running the ship scripts.
expect 0 '~/.claude/skills/ship/codex-round.sh 12'
expect 0 'sh ~/.claude/skills/ship/codex-wait.sh 12'
expect 0 '~/.claude/skills/ship/codex-wait.sh 12 2>&1 | tail -5'
expect 0 '$HOME/.claude/skills/ship/codex-request.sh 12 acme/app abc123'
expect 0 'sh "$HOME/.claude/skills/ship/codex-wait.sh" 12'
expect 0 "$h/.claude/skills/ship/gate-stats.sh"
# The #135 regression of 2026-11-11: a ship script run with stdout and stderr in a file under /tmp.
expect 0 '~/.claude/skills/ship/token-report.sh 12 >/tmp/out 2>&1'
expect 0 '~/.claude/skills/ship/token-report.sh 12 --since 2026-11-01 >/tmp/out.txt 2>/tmp/err.txt'
expect 0 'sh ~/.claude/skills/ship/token-report.sh 12 > "/tmp/report.md" 2>&1'
expect 0 '~/.claude/skills/ship/token-report.sh 12 | tee /tmp/report.md'
# Writes elsewhere under ~/.claude, and names that only start like a protected one.
expect 0 'echo x > ~/.claude/agents/mine.md'
expect 0 'echo ok > ~/.claude/projects/p/x'
expect 0 'echo ok > $HOME/.claude/projects/p/x'
expect 0 'rm ~/.claude/projects/p/memory/x.md'
expect 0 'rm ~/.claude/skills/other/x'
expect 0 'rm ~/.claude/x/../projects/y'
expect 0 'rm ~/.claude/git-hooks-notes'
expect 0 'rm ~/.claude/hooks-old/x'
expect 0 'rm ~/.claude/bin-notes.md'
expect 0 'rm ~/.claude/skills/ship-notes/x'
expect 0 'rm ~/.claude/agents/ship'
expect 0 'rm /etc/claude-codex/y'
expect 0 'rm /etc/claude-code-notes.md'
expect 0 'cp x /etc/other.conf'
expect 0 'rm ./build/hooks/x'
expect 0 'rm hooks/x'
expect 0 'rm .git/review-gate-notes'
expect 0 'rm ~/.claude/.keep'
expect 0 'echo x > .git/info/exclude'
expect 0 'cp /tmp/a /tmp/b'
expect 0 'rm -rf build dist'
# A protected path inside a quoted string, a message or a heredoc body is no write (claude-ship #135, #40).
expect 0 'gh issue create --title t --body "~/.claude/skills/ship/codex-request.sh 29 2>&1 | tail"'
expect 0 'gh issue create --title t --body "the rm of ~/.claude/hooks/x and a cp of ~/.claude/settings.json"'
expect 0 'gh issue create --title t --body "echo x > ~/.claude/hooks/x"'
expect 0 'gh issue create --title t --body "~/.claude/skills/ship/codex-wait.sh <PR> stalls"'
expect 0 'rm .git/claude-ship/plan-x.md && ls -l ~/.claude/agents/ship-codex.md'
expect 0 "git commit -m 'docs: cp of ~/.claude/hooks/x is read-only'"
expect 0 'git commit -m "fix: rm ~/.claude/hooks/x"'
expect 0 'git commit -m "fix: echo x > ~/.claude/hooks/x"'
expect 0 'echo "rm ~/.claude/hooks/x"'
expect 0 'printf "%s\n" "cp x ~/.claude/hooks/y" > /tmp/note'
expect 0 'cat <<EOF
rm ~/.claude/hooks/x is what the old check read as a write
EOF'
# A heredoc to /tmp.
expect 0 'cat > /tmp/note.md <<EOF
rm ~/.claude/hooks/x
cp /tmp/a ~/.claude/settings.json
echo x > ~/.claude/hooks/y
EOF'
expect 0 'cat >/tmp/x <<EOF
~/.claude/hooks/x
EOF'
expect 0 "cat <<'EOF' | tee /tmp/x
rm ~/.claude/hooks/x
EOF"
# A protected file named in a command that writes elsewhere is no write of it.
expect 0 'echo ~/.claude/hooks/x > /tmp/list'
expect 0 'cat ~/.claude/hooks/x >/tmp/copy'
expect 0 'cat ~/.claude/hooks/x | tee /tmp/y'
expect 0 'echo x >/tmp/y && cat ~/.claude/hooks/x | head -3'
expect 0 'ls ~/.claude/hooks > /tmp/listing'
# The inputs of #195, #196 and #198-#203. From a protected working directory a `wget -O-`, a curl option with an attached
# value and a mode or size operand of a tool that is not a writer are no writes (#196, #199, #198); `curl`, `wget`, `scp`,
# `sponge` and the interpreters are not writers the check names; and a stacked `-C`, a variable in a path and a `cd` that
# may fail are what it does not follow (#200-#203).
expectc 0 "$h/.claude/hooks" 'wget -qO- https://example.com/i.sh | sh'
expectc 0 "$h/.claude/hooks" 'wget -O- https://example.com'
expectc 0 "$h/.claude/hooks" 'wget -q --spider URL'
expectc 0 "$h/.claude/hooks" 'curl -HContent-Type:x https://example.com'
expectc 0 "$h/.claude/hooks" 'curl -o - https://example.com'
expectc 0 "$h/.claude/hooks" 'curl -sSL -o- https://example.com'
expect 0 'cd ~/.claude/hooks && wget -qO- https://example.com/i.sh | sh'
expect 0 'cd ~/.claude/hooks && curl -HContent-Type:x https://example.com'
expect 0 'cd ~/.claude/hooks && rm 1'
expect 0 'cd ~/.claude/hooks && rm s/x'
expect 0 'cd ~/.claude/hooks && chmod 644 /tmp/f'
expect 0 'cd ~/.claude/hooks && dd if=/tmp/a of=/tmp/b bs=4M count=1'
expect 0 'cd ~/.claude/hooks && cp /tmp/a /tmp/b'
expect 0 'tar -xf a -C ~/.claude -C hooks'
expect 0 'f=review-gate.sh; dd if=/dev/null of=~/.claude/./hooks/$f'
expect 0 'cd /tmp/missing; : > review-gate.sh'
expect 0 'curl -o ~/.claude/hooks/x URL'
expect 0 'wget -O ~/.claude/settings.json URL'
expect 0 'wget -P ~/.claude/hooks URL'
expect 0 'scp h:a ~/.claude/bin/'
expect 0 'echo x | sponge ~/.claude/settings.json'
expect 0 'curl -O URL'
expect 0 'curl URL | tar -xf - -C /tmp'
expect 0 'tar -C /tmp -xf a.tar'
expect 0 'tar -czf /tmp/a.tar.gz ~/proj'
expect 0 'tar -xOf /tmp/a.tar member'
expect 0 'rsync a /tmp/b'
expect 0 'scp ~/.claude/hooks/x h:b'
expect 0 'node build.js'
expect 0 'git status'
expect 0 'git -C ~/.claude/hooks status'
expect 0 'git -C ~/.claude/hooks log --oneline | head'
expect 0 'git -C ~/proj checkout .'
expect 0 'dd if=/tmp/a of=/tmp/b'
expect 0 'chmod u+x,go-w /tmp/f'
expect 0 'sed -i s/a/b/ /tmp/f'
expect 0 'truncate -s 10 /tmp/f'

# The same cd rule passes elsewhere: a directory that is not protected, a cd that undoes the first, one it cannot read, and
# reads.
expect 0 'cd /tmp && rm settings.json'
expect 0 'cd /tmp && rm review-gate'
expect 0 'cd /tmp; echo x > settings.json'
expect 0 'cd ~/.claude && cd /tmp && rm settings.json'
expect 0 'cd $d && rm settings.json'
expect 0 'cd ~nobody/.claude && rm settings.json'
expect 0 'cd ~/.claude && ls settings.json'
expect 0 'cd ~/.claude && cat settings.json'
expect 0 'cd repo/.git && cat review-gate/abc.pass'
expect 0 'cd repo/.git && rm config'

# --- Out of scope: what the immutable flag holds, not the check ------------------------------------------------------
# The check reads literal words. A path built at run time, a `cd`, an interpreter, a wrapper it doesn't unwrap, the tools
# that are not writers all pass here (AGENTS.md › Gate scope, docs/gate.md › Threat model); `chattr +i` on the installed
# files is what keeps them from being written, and only the user lifts it.
expect 0 'cd ~/.claude/hooks && rm review-gate.sh'
expect 0 'cd ~/.claude && rm hooks/review-gate.sh'
expect 0 'cd ~/.claude/hooks && echo x > review-gate.sh'
expect 0 'pushd ~/.claude/hooks && echo x >review-gate.sh'
expect 0 'cd ~ && rm .claude/hooks/review-gate.sh'
expect 0 'cd ~/.claude && cd hooks && rm review-gate.sh'
expect 0 'env -C ~/.claude rm hooks/x'
expect 0 'sudo -D ~/.claude rm hooks/x'
expect 0 'git -C ~/.claude commit -am x'
expect 0 'git -C ~/.claude/hooks checkout .'
expect 0 'p=~/.claude/hooks; rm "$p"/x'
expect 0 'd=~/.claude/hooks; rm $d/review-gate.sh'
expect 0 'f=~/.claude/hooks/x; echo y >$f'
expect 0 'f=~/.claude/hooks/x; echo y | tee $f'
expect 0 'x=hooks; rm ~/.claude/$x/review-gate.sh'
expect 0 'x=1; rm ~/.claude/hooks/$x'
expect 0 'rm ~/.claude/hooks/*'
expect 0 'rm ~/.claude/hook?/review-gate.sh'
expect 0 'rm ~/.claude/{hooks,y}/review-gate.sh'
expect 0 'rm $(echo ~/.claude/hooks/x)'
expect 0 'echo ~/.claude/hooks/x | xargs rm'
expect 0 'ls ~/.claude/hooks | xargs rm'
expect 0 'rm ~nobody/.claude/hooks/x'
expect 0 "rm \$'$h/.claude/hooks/x'"
expect 0 'echo rm ~/.claude/hooks/x | sh'
expect 0 'bash <<EOF
rm ~/.claude/hooks/x
EOF'
expect 0 'sh -c "rm ~/.claude/hooks/\$x"'
expect 0 "python3 -c 'open(\"$h/.claude/hooks/x\", \"w\")'"
expect 0 "node -e 'require(\"fs\").rmSync(process.argv[1])' ~/.claude/hooks/x"
expect 0 'python3 - <<EOF
open("/x/.git/review-gate/a.pass", "w")
EOF'
expect 0 "awk 'BEGIN { print \"x\" > \"/repo/.git/review-gate/abc.pass\" }'"
expect 0 "awk '{ print > \"/tmp/o\" }' ~/.claude/settings.json"
expect 0 'flock /tmp/l rm ~/.claude/hooks/x'
expect 0 'watch rm ~/.claude/hooks/x'
expect 0 'busybox rm ~/.claude/hooks/x'
expect 0 "su -c 'rm ~/.claude/hooks/x'"
expect 0 "ssh host 'rm ~/.claude/hooks/x'"
expect 0 'sudo -i rm ~/.claude/hooks/x'
expect 0 'timeout --bogus 5 rm ~/.claude/hooks/x'
expect 0 'c=chattr; $c -i x'
# A shell nested past the depth cap is not read.
nest='rm ~/.claude/hooks/x'
for _ in 1 2 3 4 5; do nest="sh -c '$(printf '%s' "$nest" | sed "s/'/'\\\\''/g")'"; done
expect 0 "$nest"
nest='ls ~/.claude/hooks'
for _ in 1 2 3 4 5; do nest="sh -c '$(printf '%s' "$nest" | sed "s/'/'\\\\''/g")'"; done
expect 0 "$nest"

# --- chattr is denied (claude-ship #189) -----------------------------------------------------------------------------
# chattr is how the installed files are locked and unlocked; only the user does either, with `!`.
expect 2 'chattr -i ~/.claude/hooks/review-gate.sh'
expect 2 'sudo chattr -R -i ~/.claude'
expect 2 'chattr +i /tmp/x'
expect 2 '/usr/bin/chattr -i ~/.claude/hooks/review-gate.sh'
expect 2 'sudo -u root chattr -i /etc/claude-code'
expect 2 'env X=1 chattr -i x'
expect 2 'nice -n 5 chattr -i x'
expect 2 'command chattr -i x'
expect 2 'echo x | xargs chattr -i'
expect 2 'find ~/.claude -exec chattr -i {} +'
expect 2 "sh -c 'chattr -i ~/.claude/hooks/x'"
expect 2 'eval "chattr -i x"'
expect 2 'cd ~/.claude && chattr -R -i .'
expect 2 'true && chattr -i x'
expect 2 'echo $(chattr -i x)'
expect 2 'chattr "-i" x'
expect 2 "ch\"attr\" -i x"
expect 0 'lsattr ~/.claude/hooks'
expect 0 'grep -n chattr install.sh'
expect 0 'echo chattr -i is for the user'
expect 0 'git commit -m "feat: chattr +i the files"'
expect 0 'cat docs/chattr.md'
expect 0 'ls chattr-notes'

# --- The parse fails closed ------------------------------------------------------------------------------------------
# No shfmt, or a command it can't read, blocks the call.
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
expect_err 2 'echo "unterminated'
grep -q "couldn't parse" "$tmp/err" || {
	echo "FAIL: an unparsable command should say the gate couldn't parse it"
	cat "$tmp/err"
	fail=1
}
expect 2 "echo 'x"
expect 2 'if then fi'
expect 0 ''

# --- The Codex round allowance (claude-ship #282) -------------------------------------------------------------------
# Only the user allows a Codex round past the cap, with `! ~/.claude/skills/ship/codex-allow.sh`: Claude's own run of the
# script, in any repo and under the spellings the docs use, is denied...
expect 2 '~/.claude/skills/ship/codex-allow.sh 290'
expect 2 'sh ~/.claude/skills/ship/codex-allow.sh 290 o/r'
expect 2 'cd /x && codex-allow.sh 1'
expect 2 "$tmp/home/.claude/skills/ship/codex-allow.sh 290 o/r"
expect 2 'bash -c "~/.claude/skills/ship/codex-allow.sh 1"'
expect 2 'cd tests && ../skills/ship/codex-allow.sh 1'
expect 2 'sh ~/.claude/skills/ship/mytests/codex-allow.sh 1'
expect 2 'bash -x ~/.claude/skills/ship/codex-allow.sh 1 o/r'
expect 2 'sh -e -u ~/.claude/skills/ship/codex-allow.sh 1'
expect 2 'env X=1 ~/.claude/skills/ship/codex-allow.sh 1'
expect 2 'timeout 60 ~/.claude/skills/ship/codex-allow.sh 1'
expect 2 'nohup ~/.claude/skills/ship/codex-allow.sh 1 &'
expect 2 '. ~/.claude/skills/ship/codex-allow.sh'
expect 2 'source ~/.claude/skills/ship/codex-allow.sh 1'
expect 2 'echo 1 | xargs ~/.claude/skills/ship/codex-allow.sh'
expect 2 'git status && ~/.claude/skills/ship/codex-allow.sh 1'
# ...and so is writing the allowance file it leaves (under ~/.claude/claude-ship/, which the gate protects whole)...
expect 2 'echo 9 > ~/.claude/claude-ship/codex-allow/o+r-1'
expect 2 "echo 9 > $tmp/home/.claude/claude-ship/codex-allow/o+r-1"
expect 2 "printf 9 | tee $tmp/home/.claude/claude-ship/codex-allow/o+r-1"
# ...while the rest of what Claude does with the file in the repo, a commit message that names it and reading the allowance
# are fine: the denial is of running it, not of mentioning it.
expect 0 'sh tests/codex-allow.sh'
expect 0 'sh ./tests/codex-allow.sh'
expect 0 "sh $tmp/repo/tests/codex-allow.sh"
expect 0 'git add skills/ship/codex-allow.sh'
expect 0 'git update-index --chmod=+x skills/ship/codex-allow.sh'
expect 0 'git commit -m "fix(ship): codex-allow.sh reads the home"'
expect 0 'shellcheck --shell=sh skills/ship/codex-allow.sh tests/codex-allow.sh'
expect 0 'cat skills/ship/codex-allow.sh'
expect 0 'grep -n cap skills/ship/codex-allow.sh docs/scripts.md'
expect 0 'chmod +x skills/ship/codex-allow.sh'
expect 0 'diff -u skills/ship/codex-allow.sh ~/.claude/skills/ship/codex-allow.sh'
expect 0 'echo "ask the user to run codex-allow.sh"'
expect 0 'cat ~/.claude/claude-ship/codex-allow/o+r-1'
# ...and a syntax check only reads the script (bash -n runs nothing), so it passes; flags after the script name are its own.
expect 0 'bash -n skills/ship/codex-allow.sh'
expect 0 'sh -n ~/.claude/skills/ship/codex-allow.sh'
expect 0 'bash -nv skills/ship/codex-allow.sh'
expect 2 'bash ~/.claude/skills/ship/codex-allow.sh -n'
expect 2 'bash -x -c ~/.claude/skills/ship/codex-allow.sh'
expect 0 '~/.claude/skills/ship/codex-request.sh 1 o/r 1111111111111111111111111111111111111111'

# --- The Write tool --------------------------------------------------------------------------------------------------
# write <exit code> <path> [text]: the Write tool on the path.
write() {
	jq -nc --arg p "$2" --arg t "${3:-x}" --arg d "$tmp" '{tool_name: "Write", tool_input: {file_path: $p, content: $t}, cwd: $d}' |
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
# The install's lint config: weakening it would switch the pre-commit lint off for Claude's own commits.
write 2 "$tmp/home/.claude/claude-ship/lint"
write 2 "$tmp/home/.claude/./claude-ship/lint"
write 2 "$tmp/home/.claude/claude-ship"
write 0 "$tmp/home/.claude/claude-ship-notes.md"
write 0 "$tmp/home/.claude/state/claude-ship/triage-o+r-1.json"
# The Codex round allowance (claude-ship #282) is gate state too.
write 2 "$tmp/home/.claude/claude-ship/codex-allow/o+r-1"
write 2 "$tmp/home/.claude/./claude-ship/codex-allow/o+r-1"
# The git hook stubs run the pre-push check; replacing one would switch it off while the executable-file check passed.
write 2 "$tmp/home/.claude/git-hooks/pre-push"
write 2 "$tmp/home/.claude/./git-hooks/pre-push"
write 0 "$tmp/home/.claude/git-hooks-notes.md"
write 0 "$tmp/home/.claude/agents/mine.md"
write 0 "$tmp/home/.claude/bin-notes.md"
# The path is resolved first: `.`, `//`, `..` and a relative path spell the same file (claude-ship #187).
write 2 "$tmp/home/.claude/./hooks/x"
write 2 "$tmp/home/.claude//hooks/x"
write 2 "$tmp/home/.claude/projects/../hooks/x"
write 2 "$tmp/home/.claude/hooks/../settings.json"
write 2 "${up}${tmp#/}/home/.claude/hooks/x"
write 0 "$tmp/home/.claude/projects/x"
# The managed settings directory, under every spelling (claude-ship #189).
write 2 /etc/claude-code/managed-settings.json
write 2 /etc/claude-code/managed-settings.d/50-x.json
write 2 /etc/claude-code/managed-settings.d/claude-ship.json
write 2 /etc/claude-code
write 2 /etc//claude-code/managed-settings.json
write 2 /etc/./claude-code/managed-settings.json
write 2 /etc/claude-code/../claude-code/managed-settings.json
write 2 /etc/x/../claude-code/managed-settings.d/x.json
write 2 "${up}etc/claude-code/managed-settings.json"
write 0 /etc/claude-codex/x
write 0 /etc/claude-code-notes.md
write 0 /etc/other.conf
# The gate's state, in any repo.
write 2 /repo/.git/review-gate/abc.pass
write 2 .git/review-gate/abc.waived
write 0 /repo/.git/info/exclude
# The user's settings register the gate and are protected whole; a project's own `.claude/settings` may change, but not to
# turn hooks off.
write 2 "$tmp/home/.claude/settings.json"
write 2 "$tmp/home/.claude/settings.local.json"
write 2 "$tmp/proj/.claude/settings.local.json" '{"disableAllHooks": true}'
write 0 "$tmp/proj/.claude/settings.local.json" '{"permissions": {}}'

wait
if [ -s "$tmp/fails" ]; then
	cat "$tmp/fails"
	fail=1
fi
[ "$fail" = 0 ] && echo "gate-tamper: ok"
exit "$fail"
