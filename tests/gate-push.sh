#!/bin/sh
# Tests the review gate's checks on what a push sends and where: origin's URLs must all name the pushed repo
# (claude-ship #11, #13), and a pushing command may contain only the push (#14, #25).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/lib/shfmt.sh"
. "$root/tests/lib/gitenv.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
link_shfmt "$tmp/home"
printf '#!/bin/sh\necho true\n' >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
export HOME="$tmp/home"
# The gate wants the pre-push check active before it lets a push through (docs/gate.md › Pre-push check).
gate_git_hooks "$HOME"
fail=0
n=0

# fixture <origin URL> [nopass]: a new repo on branch feat with one commit, whose review already passed unless nopass.
fixture() {
	n=$((n + 1))
	repo=$tmp/repo$n
	git init -q -b feat "$repo"
	git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
	git -C "$repo" remote add origin "$1"
	mkdir -p "$repo/.git/review-gate"
	[ "${2:-}" = nopass ] || : >"$repo/.git/review-gate/$(git -C "$repo" rev-parse HEAD).pass"
}

# expect <exit code> <command>: runs the gate on a Bash call of the command in the current fixture.
expect() {
	jq -nc --arg c "$2" --arg d "$repo" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
		PATH=$tmp/bin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	if [ "$rc" != "$1" ]; then
		echo "FAIL (exit $rc, want $1) in $(git -C "$repo" remote get-url --all origin | tr '\n' ' '): $2"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}

fixture https://github.com/acme/app.git
expect 0 'git push -u origin HEAD'
# Allowed next to a push: a leading `cd <dir> &&`, harmless redirects, and trailing pipes into read-only filters.
expect 0 "cd $repo && git push origin HEAD"
expect 0 'git push origin HEAD 2>&1'
expect 0 'git push origin HEAD >/dev/null 2>&1'
expect 0 'git push origin HEAD 2>/dev/null'
expect 0 'git push origin HEAD > /dev/stdout'
expect 0 'git push origin HEAD 2>&1 | tail -3'
expect 0 'git push origin HEAD >&2'
expect 0 'git push origin HEAD >&-'
expect 0 'git push origin HEAD 2>&1 | tail -3 2>&1'
expect 0 'git push origin HEAD 2>&1 | grep -v hint | head -5'
expect 0 'git -C . push origin HEAD | cat'
expect 0 "cd $repo && git push -u origin HEAD 2>&1 | tail -3"
# The shape is read from the syntax tree, so quoting and line continuations don't change it: a quoted directory with
# spaces (#39), a push continued onto a second line (#42), `--quiet` and `--verbose` (#83), and a quoted redirect
# target (#99). Equivalent spellings pass; anything else in the command still blocks.
cp -R "$repo" "$tmp/dir with space"
expect 0 "cd \"$tmp/dir with space\" && git push origin HEAD"
expect 0 "cd '../dir with space' && git push -u origin HEAD 2>&1 | tail -3"
expect 0 'git push -u \
origin HEAD'
expect 0 'git push --quiet origin HEAD'
expect 0 'git push --verbose origin HEAD'
expect 0 "git push origin HEAD >'/dev/null'"
expect 0 'git push origin HEAD 2>"/dev/null" | tail -1'
expect 0 'git push origin HEAD 2>&1 | tail -3 | head -1'
expect 0 "'git' push \"origin\" HEAD"
expect 0 'git pu\
sh origin HEAD'
expect 0 'git push origin HEAD 3>&-'
# The git hook that checks Claude's pushes (hooks/git-hook.sh) must stay on: `--no-verify` and a write of
# core.hooksPath skip it, so they block, with or without a push, in any spelling the tree shows. Reading the setting,
# `git commit --no-verify` and text that only mentions the name are fine.
expect 2 'git push --no-verify origin HEAD'
expect 2 'git push origin HEAD --no-verify'
expect 2 'git -C . push --no-verify'
expect 2 'git push -u --no-verify origin HEAD'
expect 2 "cd $repo && git push --no-verify"
expect 2 'git push origin HEAD --no-verify 2>&1 | tail -3'
expect 2 'sh -c "git push --no-verify"'
expect 2 'sudo git push --no-verify'
expect 2 'git config --global core.hooksPath /dev/null'
expect 2 'git config core.hooksPath /dev/null'
expect 2 'git config --unset core.hookspath'
expect 2 'git config --global --unset-all core.hooksPath'
expect 2 'git config --global --add core.hooksPath /x'
expect 2 'git config --replace-all CORE.HOOKSPATH /x'
expect 2 'git config -f /tmp/c core.hooksPath /x'
expect 2 'git config set core.hooksPath /x'
expect 2 'git config unset core.hooksPath'
expect 2 'git -c core.hooksPath=/dev/null push'
expect 2 'git -c core.hooksPath=/dev/null status'
expect 2 'git -c core.hookspath=/dev/null status'
expect 2 'git -ccore.hooksPath=/dev/null status'
expect 2 'git -c user.name=t -c core.hooksPath= status'
expect 2 'git --config-env=core.hooksPath=X status'
expect 2 'git --config-env core.hooksPath=X status'
expect 2 'git -C . -c core.hooksPath=/x commit -m x'
expect 2 'sh -c "git config --global core.hooksPath /dev/null"'
expect 2 'env FOO=1 git config core.hooksPath /x'
expect 0 'git config --get core.hooksPath'
expect 0 'git config --global --get core.hooksPath'
expect 0 'git config --get-all core.hooksPath'
expect 0 'git config --get-regexp hooks'
expect 0 'git config --list'
expect 0 'git config -l'
expect 0 'git config core.hooksPath'
expect 0 'git config --global core.hooksPath'
expect 0 'git config get core.hooksPath'
expect 0 'git config user.name t'
expect 0 'git -c user.name=t status'
expect 0 'git commit --no-verify -m x'
expect 0 'git grep hooksPath'
expect 0 'git log --grep hooksPath'
expect 0 'grep -n hooksPath docs/gate.md'
expect 0 'echo "core.hooksPath"'
# The check before a push: the gate wants the hook active where the push runs (core.hooksPath at ours, with an
# executable pre-push), else a push would skip the review the hook enforces. The harness HOME above has both.
gitcfg=$HOME/.gitconfig
cp "$gitcfg" "$tmp/gitconfig.good"
: >"$gitcfg"
expect 2 'git push -u origin HEAD'
grep -q "core.hooksPath is ''" "$tmp/err" && grep -q 'install.sh' "$tmp/err" || {
	echo "FAIL: the unset-hooksPath block lacks its advice"
	sed 's/^/  /' "$tmp/err"
	fail=1
}
git config -f "$gitcfg" core.hooksPath /elsewhere
expect 2 'git push -u origin HEAD'
grep -q "core.hooksPath is '/elsewhere'" "$tmp/err" || {
	echo "FAIL: the block doesn't name the other path"
	sed 's/^/  /' "$tmp/err"
	fail=1
}
cp "$tmp/gitconfig.good" "$gitcfg"
chmod -x "$HOME/.claude/git-hooks/pre-push"
expect 2 'git push -u origin HEAD'
rm -f "$HOME/.claude/git-hooks/pre-push"
expect 2 'git push -u origin HEAD'
# Every Bash command in an opted-in repo is held to it, not only a push: a push that is no canonical push is left to the
# pre-push check, so the check must be on whatever the command says (docs/gate.md › Pre-push check). Here the executable
# pre-push is gone, so a plain `ls` blocks too.
expect 2 'git status'
expect 2 'ls'
printf '#!/bin/sh\nexit 0\n' >"$HOME/.claude/git-hooks/pre-push"
chmod +x "$HOME/.claude/git-hooks/pre-push"
# A repo-level override of core.hooksPath is what git would use, so it counts.
git -C "$repo" config core.hooksPath /elsewhere
expect 2 'git push -u origin HEAD'
# A repo's own core.hooksPath (husky and the like) switches the pre-push check off for any push, however it starts: every command
# blocks, with advice for the user, and the global setup passes everything that is no canonical push.
git -C "$repo" config core.hooksPath .husky
expect 2 'git commit -m x && git push'
expect 2 "bash -c 'git push'"
expect 2 'ls'
grep -q 'core.hooksPath is .\.husky' "$tmp/err" && grep -q 'unset' "$tmp/err" || {
	echo "FAIL: the block for a repo-local core.hooksPath lacks its advice"
	sed 's/^/  /' "$tmp/err"
	fail=1
}
git -C "$repo" config --unset core.hooksPath
# A checkout under the scan root (REVIEW_GATE_SCAN_ROOT, set by gate_git_hooks; /srv/CodeServer in use) whose local config overrides
# core.hooksPath blocks every command once the repo is opted in, wherever the command goes: no `cd` or `git -C` is read.
scan=$REVIEW_GATE_SCAN_ROOT
git init -q -b feat "$scan/husky"
git -C "$scan/husky" remote add origin https://github.com/acme/other.git
git -C "$scan/husky" config core.hooksPath .husky
expect 2 "cd -P $scan/husky && git commit -m x && git push"
# The round-3 P0 shape: a canonical push after `cd -P`, then more commands.
expect 2 "cd -P $scan/husky && git push && git status"
expect 2 'ls'
expect 2 './scripts/release.sh'
expect 2 "git -C $scan/husky status"
grep -q "$scan/husky" "$tmp/err" && grep -q '\.husky' "$tmp/err" && grep -q 'unset' "$tmp/err" || {
	echo "FAIL: the block for another checkout's core.hooksPath lacks its path or advice"
	sed 's/^/  /' "$tmp/err"
	fail=1
}
# A config.worktree override counts, and so does one in a checkout's linked-worktree config.
git -C "$scan/husky" config --unset core.hooksPath
expect 0 'ls'
printf '[core]\n\thooksPath = .husky\n' >"$scan/husky/.git/config.worktree"
expect 2 'ls'
rm -f "$scan/husky/.git/config.worktree"
mkdir -p "$scan/husky/.git/worktrees/w1"
printf '[core]\n\thooksPath = /elsewhere\n' >"$scan/husky/.git/worktrees/w1/config.worktree"
expect 2 'ls'
rm -rf "$scan/husky/.git/worktrees"
# The deployed path itself is no override, and a key in another section is not one.
git -C "$scan/husky" config core.hooksPath "$HOME/.claude/git-hooks"
expect 0 'ls'
git -C "$scan/husky" config --unset core.hooksPath
git -C "$scan/husky" config alias.hooksPath .husky
expect 0 'ls'
git -C "$scan/husky" config --unset alias.hooksPath
# No override anywhere: everything that is no canonical push passes.
expect 0 "cd -P $scan/husky && git commit -m x && git push"
expect 0 'git push -u origin HEAD'
expect 0 'ls'
expect 0 'git commit -m x && git push'
expect 0 "bash -c 'git push'"
# The deployed location follows CLAUDE_HOME, as install.sh does.
mkdir -p "$tmp/chome/git-hooks"
printf '#!/bin/sh\nexit 0\n' >"$tmp/chome/git-hooks/pre-push"
chmod +x "$tmp/chome/git-hooks/pre-push"
jq -nc --arg c 'git push -u origin HEAD' --arg d "$repo" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
	CLAUDE_HOME=$tmp/chome PATH=$tmp/bin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
[ $? = 2 ] && grep -q "core.hooksPath is '$HOME/.claude/git-hooks'" "$tmp/err" || {
	echo "FAIL: CLAUDE_HOME's git-hooks isn't the directory the gate wants"
	sed 's/^/  /' "$tmp/err"
	fail=1
}
git config -f "$gitcfg" core.hooksPath "$tmp/chome/git-hooks"
jq -nc --arg c 'git push -u origin HEAD' --arg d "$repo" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
	CLAUDE_HOME=$tmp/chome PATH=$tmp/bin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
[ $? = 0 ] || {
	echo "FAIL: a push with CLAUDE_HOME's hooks active was blocked"
	sed 's/^/  /' "$tmp/err"
	fail=1
}
cp "$tmp/gitconfig.good" "$gitcfg"
# The gate starts a review only for a canonical push: one statement, `git push ARGS` or `cd DIR && git push ARGS` (or either
# piped on), whose git command is the first of its pipeline. Anything else passes to the pre-push check (docs/gate.md ›
# Command reading). A canonical push that the tree doesn't describe as the push shape blocks: a word that isn't literal text,
# an assignment, a negation, `&`, a redirect to a file, a here-string, a second `cd`, or a pipe into anything but tail, head,
# cat and grep.
expect 2 'git push origin "$b"'
expect 2 'git push $(echo origin) HEAD'
expect 2 'git push origin HEAD*'
expect 2 'git push origin {HEAD,main}'
expect 2 'git push origin "$(echo HEAD)"'
expect 2 'cd "$d" && git push'
expect 0 'cd ~ && git push'
expect 2 'cd -P . && git push'
expect 2 'cd a b && git push'
expect 2 'cd "" && git push'
expect 2 'cd a && cd b && git push'
expect 0 'cd a && git push && cd b'
expect 2 'x=1 git push'
expect 2 'GIT_DIR=/x git push'
expect 0 '(git push origin HEAD)'
expect 0 '{ git push; }'
expect 0 'git push origin HEAD; echo'
expect 2 'git push origin HEAD;'
expect 2 'git push & '
expect 2 '! git push origin HEAD'
expect 2 'git push origin HEAD >/tmp/out'
expect 2 'git push origin HEAD <<<x'
expect 2 'git push origin HEAD 2>&1 >out.log'
expect 2 'git push origin HEAD {v}>&1'
expect 2 'git push origin HEAD |& tail'
expect 2 'git push origin HEAD | tail -1 | tee f'
expect 2 'git push origin HEAD | sh'
expect 2 'git push | tee f'
expect 2 'git push | grep "$x"'
expect 2 'git push origin HEAD | ./tail'
expect 0 'git push origin HEAD || true'
expect 2 "git push '' HEAD"
expect 0 'cat x | git push origin HEAD'
expect 0 'if true; then git push origin HEAD; fi'
expect 0 'git push origin HEAD
git push origin HEAD'
expect 2 'git push -c push.default=matching'
expect 2 'git -c push.default=matching push'
expect 2 'git -C . -C . push origin HEAD'
expect 2 'git -C "$d" push origin HEAD'
expect 2 'git --git-dir=x push origin HEAD'
expect 2 'git push origin HEAD:other'
# The directory of `cd DIR && git push` and `git -C DIR push` is one literal path, `~` expanded to the home directory and a
# relative one resolved from the session's directory; anything else can't be followed.
cp -R "$repo" "$HOME/hrepo"
expect 0 'cd ~/hrepo && git push origin HEAD'
expect 0 'git -C ~/hrepo push origin HEAD'
expect 0 "git -C ../$(basename "$HOME")/hrepo push origin HEAD"
rm -f "$HOME"/hrepo/.git/review-gate/*.pass
expect 2 'cd ~/hrepo && git push origin HEAD'
expect 2 'git -C ~/hrepo push origin HEAD'
rm -rf "$HOME/hrepo"
expect 2 'cd ~nobody/x && git push'
expect 2 'git -C ~nobody/x push'
expect 2 'git -C "$d" push'
expect 2 'git -C "" push'
expect 2 'cd - && git push'
expect 2 'cd -P . && git push'
expect 2 'git -C a -C b push'
# A command that is not a canonical push is left to the pre-push check (docs/gate.md › Command reading), whatever else it
# mentions: a wrapper, a shell, a compound command, a script or an alias; the heredoc and the `Foo=1` word of #193 and #192.
expect 0 'git add -A && git commit -m x && git push'
expect 0 '(cd x; git push)'
expect 0 "bash -c 'git push'"
expect 0 'xargs git push </dev/null'
expect 0 './scripts/release.sh'
expect 0 'git p'
expect 0 'gh pr create --fill'
expect 0 'timeout 60 git push'
expect 0 'git commit -m "Closes=1 note" && echo Foo=bar'
expect 0 'cat >/tmp/x <<'\''EOF'\''
git push origin HEAD
EOF'
# A `cd` or `-C` that may not run is not followed: such a command is not a canonical push, so the gate leaves it to the
# pre-push check.
expect 0 'if false; then cd /tmp; fi; git push origin HEAD'
expect 0 'true || cd /tmp; git push origin HEAD'
expect 0 'true || git -C /tmp push origin HEAD'
expect 0 '{ cd /tmp; git push origin HEAD; }'
# The shape rules apply where the gate does: a repo that has not opted in, or a remote that isn't GitHub's, is left alone.
mkdir -p "$tmp/offbin"
printf '#!/bin/sh\necho false\n' >"$tmp/offbin/gh"
chmod +x "$tmp/offbin/gh"
expect_off() {
	jq -nc --arg c "$2" --arg d "$repo" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
		PATH=$tmp/offbin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	if [ "$rc" != "$1" ]; then
		echo "FAIL (exit $rc, want $1; opted out): $2"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}
expect_off 0 'git push origin HEAD && echo done'
# A repo that never opted in is none of the gate's business, whatever its core.hooksPath says.
git -C "$repo" config core.hooksPath .husky
expect_off 0 'ls'
expect_off 0 'git commit -m x && git push'
git -C "$repo" config --unset core.hooksPath
git -C "$scan/husky" config core.hooksPath .husky
expect_off 0 'ls'
git -C "$scan/husky" config --unset core.hooksPath
expect_off 0 'git push origin HEAD > out.txt'
# ...but a directory the gate can't read could be an opted-in repo, so a canonical push from one blocks there too.
expect_off 2 'cd "$d" && git push origin HEAD'
expect_off 2 'git -C "$d" push origin HEAD'
expect_off 2 'cd a && cd b && git push origin HEAD'
# `cd DIR && git push` and `git -C DIR push` are judged in DIR: only acme/inrepo has opted in here, and it is reached as
# <cd target>/sub, while the session's own `sub` is another repo.
mkdir -p "$tmp/selbin" "$tmp/inrepo"
printf '#!/bin/sh\ncase "$*" in *acme/inrepo*) echo true ;; *) echo false ;; esac\n' >"$tmp/selbin/gh"
chmod +x "$tmp/selbin/gh"
git init -q -b feat "$tmp/inrepo/sub"
git -C "$tmp/inrepo/sub" remote add origin https://github.com/acme/inrepo.git
git init -q -b feat "$repo/sub"
git -C "$repo/sub" remote add origin https://github.com/acme/app.git
jq -nc --arg c "cd $tmp/inrepo && git -C sub push origin HEAD >out.txt" --arg d "$repo" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
	PATH=$tmp/selbin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
rc=$?
if [ "$rc" != 2 ] || ! grep -q 'reviews HEAD' "$tmp/err"; then
	echo "FAIL (exit $rc, want 2 for the shape): a relative -C after a cd"
	sed 's/^/  /' "$tmp/err"
	fail=1
fi
# The same push from the session's own `sub` (acme/app, not opted in under selbin) is none of the gate's business.
jq -nc --arg c "git -C sub push origin HEAD >out.txt" --arg d "$repo" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
	PATH=$tmp/selbin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
rc=$?
if [ "$rc" != 0 ]; then
	echo "FAIL (exit $rc, want 0): a relative -C in a repo that did not opt in"
	sed 's/^/  /' "$tmp/err"
	fail=1
fi
# A `gh api` write with gh's `{owner}/{repo}` placeholder goes to whichever repo gh finds where it runs, so a `cd` before it counts
# even when the command is no canonical push: here the session's repo has not opted in and the `cd` target has.
gh_here() {
	jq -nc --arg c "$2" --arg d "$repo" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
		PATH=$tmp/selbin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	if [ "$rc" != "$1" ]; then
		echo "FAIL (exit $rc, want $1): $2"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}
gh_here 0 'gh api -X POST repos/{owner}/{repo}/pulls'
gh_here 0 'cd sub && gh api -X POST repos/{owner}/{repo}/pulls'
gh_here 2 "cd $tmp/inrepo/sub && gh api -X POST repos/{owner}/{repo}/pulls"
gh_here 2 "cd $tmp/inrepo/sub; gh api -X POST repos/{owner}/{repo}/pulls | cat"
gh_here 2 "cd $tmp/inrepo && cd sub && gh api -X POST repos/{owner}/{repo}/pulls"
gh_here 2 "true || cd $tmp/inrepo/sub; gh api -X POST repos/{owner}/{repo}/pulls"
gh_here 2 "sh -c 'cd $tmp/inrepo/sub && gh api -X POST repos/{owner}/{repo}/pulls'"
gh_here 2 "sh -c \"echo x; cd $tmp/inrepo/sub; gh api -X POST repos/{owner}/{repo}/pulls\""
gh_here 0 'echo cd && gh api -X POST repos/{owner}/{repo}/pulls'
gh_here 2 'cd "$d" && gh api -X POST repos/{owner}/{repo}/pulls'
gh_here 2 "cd $tmp/inrepo/sub && cd - && gh api -X POST repos/{owner}/{repo}/pulls"
rm -rf "$repo/sub"
fixture /tmp/elsewhere.git
expect 0 'git push origin HEAD && echo done'
fixture https://github.com/acme/app.git
expect 0 'true || cd /tmp; gh pr create --title t'
expect 0 'if false; then cd /tmp; fi; gh pr create --title t'
expect 0 '{ cd /tmp; gh pr create --title t; }'
expect 2 'git push origin HEAD # x'
expect 2 'git push origin HEAD # && rm x'
expect 2 'git push origin HEAD
# x'
expect 2 '# x
git push origin HEAD'
expect 2 'git push --tags origin HEAD'
# A push of one existing tag to origin sends no HEAD, so HEAD needs no review here (this fixture has none): the pre-push
# check judges the tag's commit (claude-ship #230). Only these shapes: `git push [-f|--force] origin <tag>` and
# `... origin refs/tags/<tag>`, with `-C DIR` and `cd DIR &&` as for any push.
fixture https://github.com/acme/app.git nopass
git -C "$repo" tag v1
git -C "$repo" -c user.name=t -c user.email=t@t tag -a -m t v2
git -C "$repo" branch dev
git -C "$repo" tag dev
expect 0 'git push origin v1'
expect 0 'git push -f origin v1'
expect 0 'git push --force origin v1'
expect 0 'git push origin v1 -f'
expect 0 'git push origin refs/tags/v1'
expect 0 'git push -f origin refs/tags/v2'
expect 0 "cd $repo && git push -f origin v1"
expect 0 "git -C $repo push -f origin v1"
expect 0 'git push origin v1 2>&1 | tail -3'
expect 0 'git push origin refs/tags/dev'
# Anything else still blocks (nothing but HEAD reaches the review, which blocks a HEAD with no pass here).
expect 2 'git push origin v9'
expect 2 'git push origin refs/tags/v9'
expect 2 'git push origin refs/heads/v1'
expect 2 'git push origin HEAD:refs/tags/v1'
expect 2 'git push origin v1:refs/heads/main'
expect 2 'git push origin v1:refs/tags/v1'
expect 2 'git push origin v1 v2'
expect 2 'git push origin v1 HEAD'
expect 2 'git push origin tag v1'
expect 2 'git push upstream v1'
expect 2 'git push v1'
expect 2 'git push --tags origin'
expect 2 'git push origin v1 --tags'
expect 2 'git push --delete origin v1'
expect 2 'git push origin :v1'
expect 2 'git push origin +v1'
expect 2 'git push --force-with-lease origin v1'
expect 2 'git push -u origin v1'
expect 2 'git push --mirror origin v1'
expect 2 'git push --no-verify origin v1'
expect 2 'git push origin "$t"'
expect 2 'git push origin v*'
expect 2 'git -c push.followTags=false push origin v1'
expect 2 'git push origin v1 >/tmp/out'
# A tag push in a chain is no canonical push: the gate leaves it to the pre-push check, which judges the tag's commit.
expect 0 'git push origin v1; git push origin v1'
expect 0 'git status && git push origin v1'
expect 0 'git push origin v1 && git status'
# A bare name that is also a branch, or HEAD, isn't a tag (git calls the first ambiguous); the HEAD review applies.
expect 2 'git push origin dev'
git -C "$repo" tag HEAD
expect 2 'git push origin HEAD'
git -C "$repo" tag -d HEAD >/dev/null
# Settings that make a push send more than its words say still block a tag push.
git -C "$repo" config push.followTags true
expect 2 'git push origin v1'
git -C "$repo" config --unset push.followTags
git -C "$repo" config remote.origin.mirror true
expect 2 'git push origin v1'
git -C "$repo" config --unset remote.origin.mirror
expect 0 'git push origin v1'
git -C "$repo" remote add other https://github.com/acme/app.git
expect 2 'git push other v1'
# `-C` names the repo that is pushed from, quoted or not, so its state is the one that is checked.
fixture https://github.com/acme/app.git nopass
other=$repo
fixture https://github.com/acme/app.git
expect 2 "git -C $other push origin HEAD | tail -1"
expect 2 "git -C \"$other\" push origin HEAD"
# Quoted text that mentions a push is not a push.
expect 0 'gh pr create --title t --body "see git push"'
# (Blocked before the syntax-tree filter, which sees that no git runs: claude-ship #135.)
expect 0 'echo "git push" && echo done'
expect 0 'gh pr create --body "costs $5, see git push"'
expect 0 'gh pr create --body "see git push" && git config push.followTags true'
expect 0 'gh pr create --body "$(git config push.followTags true; git push origin HEAD)"'
# A gh comment/close body that mentions a push, however often or in whatever form, is data (#56).
expect 0 'gh issue comment 36 --body "a && git push origin HEAD and b && git push origin HEAD"'
expect 0 'gh issue comment 36 --body "./echo && git push origin HEAD and /tmp/ls && git push origin HEAD both exit 2"'
expect 0 'gh issue comment 36 --body '\''exits 2: `git push origin HEAD` exits 2'\'''
expect 0 'gh issue comment 36 --body "git push -c x upstream main"'
expect 0 'gh pr comment 7 --body "git push --force other main"'
expect 0 'gh issue close 36 --comment "fixed; git push origin HEAD was read twice: git push origin HEAD"'
expect 0 'gh pr close 7 -c "git push origin HEAD"'
# Outside that single command the chain is no canonical push: the gate lets it by and the pre-push check judges the push.
expect 0 'gh issue comment 1 --body "x" && git push origin main'
expect 0 'gh issue comment 1 --body "x" && git push origin HEAD'
expect 0 'gh issue comment 1 --body "$(git push)"'
expect 0 'gh issue comment 1 --body "`git push origin HEAD`"'
expect 0 'gh issue comment 1 --body "a git push origin HEAD b git push origin HEAD" ; git push origin main'
expect 0 'gh issue comment 1 --body x
git push origin main'
expect 0 'gh issue close 1 --comment "x" && git push origin main'
expect 0 'FOO=1 gh issue comment 1 --body "git push" && git push origin main'
expect 0 'gh -R o/r issue comment 1 --body "git push" && git push origin main'
expect 0 'gh issue comment 1 --body "git push" & git push origin main'
expect 0 'gh issue comment 1 --body "git push" | git push origin main'
expect 0 'gh issue comment 1 --body "git push" > out && git push origin main'
expect 0 'gh issue comment 1 --body-file <(git push origin main) --body "git push"'
expect 0 'gh pr merge 1 --body "git push origin HEAD and git push origin HEAD"'
# A quoted push still runs under `sh -c` and `eval`.
expect 0 'sh -c "git config push.followTags true; git push origin HEAD"'
expect 0 "bash -c 'git status && git push origin HEAD'"
expect 0 'eval "git status; git push origin HEAD"'

# Anything else in the command may change what the push sends after the gate read it.
# Codex round 2: `--output` rewrites the branch ref; an included config file can have any name.
expect 0 'git show --format=%H --no-patch --output=.git/refs/heads/feat evil && git push origin HEAD'
expect 0 "printf '[remote \"origin\"]\\nmirror = true\\n' > /tmp/settings && git push"
expect 0 'git status && git push origin HEAD'
expect 0 'git status; git push origin HEAD'
expect 0 'git ls-remote origin && git push origin HEAD'
expect 0 'git --no-pager log -1 && git -C . push origin HEAD'
expect 0 'git diff --output=.git/config && git push'
expect 0 'echo hi && git push origin HEAD'
expect 0 'true || git push origin HEAD'
expect 0 'git push origin HEAD && git status'
expect 0 'git push origin HEAD; echo done'
expect 2 'git push origin HEAD > out.txt'
expect 2 'git push origin HEAD 2>err.log'
expect 2 'git push origin HEAD >&2.txt'
expect 2 'git push origin HEAD >&1/x'
expect 2 'git push origin HEAD 2>&1.log'
expect 2 'git push origin HEAD >&2-x'
expect 2 'git push origin HEAD &>/dev/null.log'
expect 2 'git push origin HEAD >/dev/null,x'
expect 2 'git push origin HEAD 2>/dev/stderr:x'
expect 2 'git push origin HEAD &>/dev/stdout+x'
expect 2 'git push origin HEAD >&2,x'
expect 2 "git push origin HEAD >&2'.txt'"
expect 2 "git push origin HEAD >/dev/null'x'"
expect 2 "git push origin HEAD &>/dev/null'x'"
expect 0 'git push origin HEAD 2>&1; tail -1 x'
expect 2 'git push origin HEAD >> /dev/null.x'
expect 2 'git push origin HEAD | tee out.txt'
expect 2 'git push origin HEAD | sh'
expect 0 'git push origin HEAD | tail -3 && git status'
expect 0 "cd $repo && echo x && git push origin HEAD"
expect 2 'git push origin HEAD $(git status)'
expect 2 'git push origin HEAD `git status`'
expect 0 '(git status; git push origin HEAD)'
expect 2 'git push origin HEAD &'
expect 2 'git push origin HEAD < input'
expect 0 'git push origin HEAD
git status'
expect 2 'FOO=1 git push origin HEAD'
# A fetch can move the branch the gate just reviewed (`--update-head-ok`).
expect 0 'git fetch --update-head-ok origin main:feat && git push origin HEAD'
# Config written earlier in the same command is read by the push but not by the gate.
expect 0 'git config push.followTags true && git push origin HEAD'
expect 0 'git -C . config remote.origin.mirror true; git push origin HEAD'
expect 0 'git remote set-url --push origin https://github.com/acme/other.git && git push origin HEAD'
expect 0 'git branch -u origin/main && git push'
expect 0 'git commit -qm x && git push origin HEAD'
expect 0 'git symbolic-ref HEAD refs/heads/other && git push'
expect 0 'git --no-pager config push.followTags true && git push origin HEAD'
expect 0 'git -p remote set-url origin /tmp/x && git push origin HEAD'
expect 0 'git -C . --no-pager branch -u origin/main && git push'
expect 0 'sh -c "git config push.default matching" && git push'
expect 0 'echo "[push] followTags = true" >> .git/config && git push origin HEAD'
expect 0 'printf x >> ~/.gitconfig; git push origin HEAD'
expect 0 'cat x >> ~/.config/git/config; git push origin HEAD'
expect 0 'cat x >> /etc/gitconfig; git push'

# A fetch URL that isn't the pushed repo, even one that isn't GitHub's, supplies the review's base and rules.
fixture /tmp/base.git
git -C "$repo" remote set-url --add origin https://github.com/acme/app.git
git -C "$repo" remote set-url --push origin https://github.com/acme/app.git
expect 2 'git push origin HEAD'
# A push goes to every push URL, so one the gate can't check blocks too.
fixture https://github.com/acme/app.git
git -C "$repo" remote set-url --push origin https://github.com/acme/app.git
git -C "$repo" remote set-url --push --add origin /srv/mirror.git
expect 2 'git push origin HEAD'
fixture https://github.com/acme/app.git
git -C "$repo" remote set-url --add origin https://github.com/acme/other.git
expect 2 'git push origin HEAD'

# A trailing dot on the host is still GitHub: the gate reads the repo and goes on to block the dirty tree,
# rather than letting the push through or failing to read the URL.
for url in https://github.com./acme/app.git git@github.com.:acme/app.git ssh://git@ssh.github.com.:443/acme/app.git; do
	fixture "$url"
	: >"$repo/dirty"
	expect 2 'git push origin HEAD'
	grep -q 'uncommitted changes' "$tmp/err" || {
		echo "FAIL ($url): blocked for another reason"
		sed 's/^/  /' "$tmp/err"
		fail=1
	}
done

# A data-only gh command pushes nothing, so it never starts a review, even when HEAD has no pass (#91). A fake
# `claude` records that a review started and fails, so a started review exits 2. origin's URL must stay GitHub's
# for the gate's repo checks, so the fake git fetches from a local bare repo, and the fake gh names the default branch.
mkdir -p "$tmp/rbin"
cat >"$tmp/rbin/gh" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "repo view" ]; then
	echo master
	exit 0
fi
echo true
EOF
cat >"$tmp/rbin/git" <<EOF
#!/bin/sh
if [ "\$1 \$2 \$3" = "fetch -q origin" ]; then
	shift 3
	exec $(command -v git) fetch -q "$tmp/origin.git" "\$@"
fi
exec $(command -v git) "\$@"
EOF
printf '#!/bin/sh\ntouch "%s/reviewed"\nexit 1\n' "$tmp" >"$tmp/rbin/claude"
chmod +x "$tmp/rbin/gh" "$tmp/rbin/git" "$tmp/rbin/claude"
git init -q --bare -b master "$tmp/origin.git"

# fixture_unreviewed: a branch one commit ahead of origin's master, with review rules and no pass for HEAD.
fixture_unreviewed() {
	fixture https://github.com/acme/app.git nopass
	git -C "$repo" push -qf "$tmp/origin.git" HEAD:refs/heads/master
	printf '## Code Review Rules\n\n- P0: x\n' >"$repo/AGENTS.md"
	git -C "$repo" add AGENTS.md
	git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m rules
}

# expect_review <exit code> <command> <started|none>: runs the gate with the fake claude, then checks whether
# a review started.
expect_review() {
	rm -f "$tmp/reviewed"
	jq -nc --arg c "$2" --arg d "$repo" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
		PATH=$tmp/rbin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	if [ -e "$tmp/reviewed" ]; then got=started; else got=none; fi
	if [ "$rc" != "$1" ] || [ "$got" != "$3" ]; then
		echo "FAIL (exit $rc, want $1; review $got, want $3): $2"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}

fixture_unreviewed
expect_review 0 'gh pr comment 7 --body "git push --force other main"' none
expect_review 0 'gh issue create --title t --body "then git push"' none
expect_review 0 'gh issue close 36 --comment "fixed; git push origin HEAD"' none
# `gh pr create` starts no review: the PR covers a HEAD that the pre-push check already refused to push unreviewed.
expect_review 0 'gh pr create --title t --body "x"' none
expect_review 0 'gh pr create --title t --body "see git push"' none
# A real push still gets its review.
expect_review 2 'git push origin HEAD' started
expect_review 0 'gh pr comment 7 --body "x" && git push origin HEAD' none

# The gate starts a review only for a canonical push (docs/gate.md › Command reading); every other command passes, whatever
# its text says, because the pre-push check (hooks/git-hook.sh) refuses an unreviewed push however it started. None of
# these starts a review, though HEAD has no pass.
expect_review 0 'git add -A && git commit -qm x && git push' none
expect_review 0 'git add -A && git commit -qm x && git push origin HEAD 2>&1 | tail -5' none
expect_review 0 'cd /tmp && git add -A && git push' none
expect_review 0 '(cd x; git push)' none
expect_review 0 "bash -c 'git push'" none
expect_review 0 'eval "git push"' none
expect_review 0 'xargs git push </dev/null' none
expect_review 0 './scripts/release.sh' none
expect_review 0 'git p' none
expect_review 0 'gh pr create --fill' none
expect_review 0 'timeout 60 git push' none
expect_review 0 'sudo git push' none
expect_review 0 'env git push' none
expect_review 0 'time git push' none
expect_review 0 'flock /tmp/l git push' none
expect_review 0 'ssh host git push' none
expect_review 0 'find . -name x -exec git push \;' none
expect_review 0 'echo "git push" | sh' none
expect_review 0 'git push origin HEAD; echo done' none
expect_review 0 'git push origin HEAD && git status' none
expect_review 0 'git status && git push origin HEAD' none
expect_review 0 'true || git push origin HEAD' none
expect_review 0 'if true; then git push origin HEAD; fi' none
expect_review 0 'f(){ git push; }; f' none
expect_review 0 'cat x | git push origin HEAD' none
expect_review 0 'x=git; $x push' none
expect_review 0 '$(echo git) push' none
# A heredoc written to a file, whose body mentions a push or a PR (claude-ship #193), and a word shaped like an assignment
# (#192), are not a push either.
expect_review 0 'cat >/tmp/x <<'\''EOF'\''
## Plan

Run `gh pr create --title "x" | tee y; (cd z)` then $HOME and git push origin HEAD;
EOF
wc -l /tmp/x' none
expect_review 0 'd=/tmp; cat > "$d/plan.md" <<'\''EOF'\''
Never run gh api -X DELETE repos/a/b here.
EOF' none
expect_review 0 'git commit -m "Closes=1 note" && echo Foo=bar' none
expect_review 0 'echo "run git push later"' none
expect_review 0 'grep -n "gh api" hooks/review-gate.sh' none
expect_review 0 'echo "gh api -X DELETE repos/a/b"' none
expect_review 0 "printf '%s\\n' 'gh pr create' >/tmp/y" none
# A canonical push still gets its review, in each spelling the shape allows.
expect_review 2 'git push' started
expect_review 2 'git push -u origin HEAD' started
expect_review 2 "cd $repo && git push" started
expect_review 2 "git -C $repo push" started
expect_review 2 'git push 2>&1 | tail -5' started
expect_review 2 '/usr/bin/git push' started
expect_review 2 '"git" push' started
expect_review 2 'g\it push' started
# ...and one the shape can't read still blocks, before any review.
expect_review 2 'git push origin "$b"' none
expect_review 2 'cd "$d" && git push' none
expect_review 2 'cd a && cd b && git push' none
expect_review 2 'git push --all' none
expect_review 2 'git push --tags' none
expect_review 2 'git push --mirror' none
expect_review 2 'git push other HEAD' none
expect_review 2 'git push --no-verify' none
# A real gh call still gets the `gh api` scan.
expect_review 2 'gh api -X DELETE repos/acme/app/git/refs/heads/x' none
expect_review 2 'echo "gh api" && gh api -X DELETE repos/acme/app/git/refs/heads/x' none

# The reviewers share one time budget (claude-ship #103): REVIEW_GATE_BUDGET seconds from the gate's start, each
# run capped at 1100 s and at what is left, and no run starts with fewer than REVIEW_GATE_MIN_SECS left. A fake
# `timeout` logs the limit it was given, a fake `date` (FAKE_DATE_STEP) moves the clock a fixed step per call, and
# the fake claude in fbin returns one finding for the finder and fails the verifier.
cat >"$tmp/rbin/timeout" <<EOT
#!/bin/sh
echo "\$1" >>"$tmp/timeouts"
shift
exec "\$@"
EOT
mkdir -p "$tmp/fbin"
cat >"$tmp/fbin/date" <<EOT
#!/bin/sh
[ -n "\${FAKE_DATE_STEP:-}" ] || exec $(command -v date) "\$@"
n=\$(cat "$tmp/clock" 2>/dev/null || echo 0)
echo "\$n"
echo \$((n + FAKE_DATE_STEP)) >"$tmp/clock"
EOT
cat >"$tmp/fbin/claude" <<EOT
#!/bin/sh
touch "$tmp/reviewed"
case " \$* " in
*" sonnet "*) printf '{"structured_output":{"findings":[{"file":"a","line":1,"severity":"P2","summary":"s","failure_scenario":"f"}]}}' ;;
*) exit 1 ;;
esac
EOT
chmod +x "$tmp/rbin/timeout" "$tmp/fbin/date" "$tmp/fbin/claude"

# expect_budget <env assignments, or -> <exit code> <review started|none> <timeouts, space-separated, or none>
# <text in stderr>: runs a real push in a fresh unreviewed fixture with the fake claude, date and timeout.
expect_budget() {
	fixture_unreviewed
	# A change to a non-doc file, so it gets the finder and the verifier, not the docs check.
	echo 'echo x' >"$repo/x.sh"
	git -C "$repo" add x.sh
	git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m code
	rm -f "$tmp/reviewed" "$tmp/timeouts" "$tmp/clock"
	[ "$1" != - ] || set -- "FOO=1" "$2" "$3" "$4" "$5"
	jq -nc --arg c 'git push origin HEAD' --arg d "$repo" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
		env "$1" PATH="$tmp/fbin:$tmp/rbin:$PATH" sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	if [ -e "$tmp/reviewed" ]; then got=started; else got=none; fi
	limits=$(cat "$tmp/timeouts" 2>/dev/null | tr '\n' ' ')
	limits=${limits% }
	if [ "$rc" != "$2" ] || [ "$got" != "$3" ] || [ "${limits:-none}" != "$4" ] || ! grep -q "$5" "$tmp/err"; then
		echo "FAIL ($1): exit $rc (want $2), review $got (want $3), timeouts '${limits:-none}' (want '$4'), stderr wants '$5'"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}
# Within budget, each reviewer gets the full 1100 s (the fake verifier exits 1, so the review fails, not times out).
expect_budget - 2 started '1100 1100' 'verifier reviewer failed'
# The budget is spent before the first reviewer: it never starts.
expect_budget REVIEW_GATE_BUDGET=100 2 none none 'ran out of time'
expect_budget REVIEW_GATE_BUDGET=119 2 none none 'ran out of time'
# Time passed in the finder is gone from the verifier's allowance, and a verifier with nothing left never starts.
expect_budget FAKE_DATE_STEP=1100 2 started 1100 'ran out of time'
expect_budget FAKE_DATE_STEP=1000 2 started '1100 200' 'verifier reviewer failed'
expect_budget REVIEW_GATE_MIN_SECS=3000 2 none none 'ran out of time'
# A budget that isn't a number blocks rather than reading as zero or as no limit.
expect_budget REVIEW_GATE_BUDGET=abc 2 none none 'REVIEW_GATE_BUDGET'
expect_budget REVIEW_GATE_BUDGET=0100 2 none none 'REVIEW_GATE_BUDGET'
# Zero is a number but not a time limit: `timeout 0` means no limit at all, so a zero budget or minimum blocks too,
# and so does a clock that has already used the whole budget (left is 0, and was never allowed to reach timeout).
expect_budget REVIEW_GATE_BUDGET=0 2 none none 'at least 1'
expect_budget REVIEW_GATE_MIN_SECS=0 2 none none 'at least 1'
expect_budget FAKE_DATE_STEP=2200 2 none none 'ran out of time'

# A gate that can't read the tool call blocks it instead of reading it as nothing (claude-ship #103): with no jq at
# all (nojq holds only what the script runs before it looks for jq), with a jq that fails, and with input jq rejects.
mkdir -p "$tmp/nojq" "$tmp/jbin"
for t in cat dirname date; do
	ln -s "$(command -v "$t")" "$tmp/nojq/$t"
done
printf '#!/bin/sh\nexit 127\n' >"$tmp/jbin/jq"
chmod +x "$tmp/jbin/jq"

# expect_input <exit code> <stderr text> <bin dir, or - for the usual PATH> <input JSON>
expect_input() {
	if [ "$3" = - ]; then
		printf '%s' "$4" | PATH=$tmp/rbin:$PATH /bin/sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	else
		printf '%s' "$4" | PATH=$3 /bin/sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	fi
	rc=$?
	if [ "$rc" != "$1" ] || { [ -n "$2" ] && ! grep -q "$2" "$tmp/err"; }; then
		echo "FAIL (exit $rc, want $1; stderr wants '$2', bin $3): $4"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}
bash_call=$(jq -nc --arg d "$repo" '{tool_name: "Bash", tool_input: {command: "ls"}, cwd: $d}')
write_call=$(jq -nc '{tool_name: "Write", tool_input: {file_path: "/tmp/x", content: "x"}}')
mcp_call=$(jq -nc '{tool_name: "mcp__x__y", tool_input: {}}')
for call in "$bash_call" "$write_call" "$mcp_call"; do
	expect_input 2 'needs jq' "$tmp/nojq" "$call"
	expect_input 2 "couldn't read" "$tmp/jbin:$tmp/rbin:$PATH" "$call"
done
expect_input 2 "couldn't read" - 'not json'
expect_input 2 "couldn't read" - ''
expect_input 2 "couldn't read" - '{}'
# Valid JSON that jq reads but not as a tool call of that shape is as unreadable.
expect_input 2 "couldn't read" - '{"tool_name":"Bash","tool_input":"git push origin HEAD"}'
expect_input 2 "couldn't read" - '{"tool_name":"Write","tool_input":{"file_path":"/p/.claude/settings.json","edits":5}}'
expect_input 2 "couldn't read" - '{"tool_name":"mcp__x__push_files","tool_input":"x"}'
# A tool the gate doesn't look at still passes, and so does a Bash call that isn't a push.
expect_input 0 '' - '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
expect_input 0 '' - "$bash_call"
# Nothing is pushed, so a dirty tree is no reason to block a data-only command, but it still blocks a push.
: >"$repo/dirty"
expect_review 0 'gh pr comment 7 --body "git push origin HEAD"' none
expect_review 2 'git push origin HEAD' none

[ "$fail" = 0 ] && echo "gate-push: ok"
exit "$fail"
