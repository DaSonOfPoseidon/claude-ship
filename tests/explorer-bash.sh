#!/bin/sh
# Tests the ship-explorer's Bash hook: only its read-only git and gh forms run, and anything it can't tell
# denies (claude-ship #68).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

# check <exit code> <hook input>: runs the hook on the input.
check() {
	printf '%s' "$2" | sh "$root/hooks/explorer-bash.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	if [ "$rc" != "$1" ]; then
		echo "FAIL (exit $rc, want $1): $2"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}

# expect <exit code> <command>: runs the hook on a Bash call of the command.
expect() {
	check "$1" "$(jq -nc --arg c "$2" '{tool_name: "Bash", tool_input: {command: $c}}')"
}

# Allowed: the read-only git and gh forms.
expect 0 'git log --oneline -5 -- hooks/review-gate.sh'
expect 0 'git show HEAD:AGENTS.md'
expect 0 'git show HEAD~2^:AGENTS.md'
expect 0 'git diff origin/main...HEAD --stat'
expect 0 'git grep -n -e codex-status -- skills'
expect 0 'git ls-files hooks'
expect 0 'git log'
expect 0 'git blame -L 1,20 x.sh'
expect 0 'git diff --no-ext-diff HEAD'
expect 0 'gh issue view 68 --json body'
expect 0 'gh pr view 95 --comments'
expect 0 'gh pr diff 95'
expect 0 'gh api repos/o/r/pulls/1/comments'
expect 0 'gh api repos/o/r/pulls/1/comments --paginate --jq .title'
# Denied: options that write, run a program or leave the repository, however they are spelled (git accepts
# abbreviated long options, and bundles short ones).
expect 2 'git show --output=/tmp/x HEAD'
expect 2 'git show --out=/tmp/x HEAD'
expect 2 'git log --o /tmp/x'
expect 2 'git diff --ext-diff'
expect 2 'git diff --ext HEAD'
expect 2 'git log -p --textconv'
expect 2 'git diff --no-index a b'
expect 2 'git diff --no-i a b'
expect 2 'git grep -O less foo'
expect 2 'git grep -nOless foo'
expect 2 'git grep --open-files-in-pager=less foo'
expect 2 'git log -o x'
# Denied: a `--` is no terminator to trust. It can be an option's argument (-e's pattern), so words after it are
# checked like any other, and a pathspec that looks like a denied option is refused too.
expect 2 'git grep -e -- --open-files-in-pager=/tmp/helper'
expect 2 'git grep -e -- --output=x'
expect 2 'git log -- --output=x'
expect 2 'git diff -- --ext-diff'
expect 2 'git log -- -o x'
expect 2 'gh api x -- -X POST'
expect 2 'gh api x -- --method PATCH'
expect 2 'gh pr view 1 -- --web'
expect 0 'git log --oneline -- hooks/review-gate.sh'
expect 0 'git diff HEAD -- README.md docs'
# Denied: options before the subcommand.
expect 2 'git -c core.pager=sh log'
expect 2 'git -C /tmp log'
expect 2 'git --git-dir=/tmp/x log'
expect 2 'git --work-tree=/tmp/x log'
expect 2 'git'
expect 2 'git push origin HEAD'
expect 2 'git commit -m x'
expect 2 'git config alias.l log'
expect 2 'git branch -D x'
# Denied: gh writes.
expect 2 'gh api -X POST repos/o/r/issues'
expect 2 'gh api -XPOST repos/o/r/issues'
expect 2 'gh api --method PATCH repos/o/r/issues/1'
expect 2 'gh api --method=PATCH repos/o/r/issues/1'
expect 2 'gh api --input f repos/o/r/issues'
expect 2 'gh api -f title=x repos/o/r/issues'
expect 2 'gh api -F title=x repos/o/r/issues'
expect 2 'gh api -ifx repos/o/r/issues'
expect 2 'gh api --field title=x repos/o/r/issues'
expect 2 'gh api --raw-field title=x repos/o/r/issues'
expect 2 "gh api graphql -f query='mutation { x }'"
expect 2 'gh api graphql --raw-field query=mutation'
expect 2 'gh api graphql --paginate Mutation'
expect 2 'gh api'
expect 2 'gh issue edit 1'
expect 2 'gh issue comment 1 --body x'
expect 2 'gh pr merge 1'
expect 2 'gh pr view 1 --web'
expect 2 'gh issue view -w 1'
expect 2 'gh pr create'
expect 2 'gh -R o/r issue view 1'
expect 2 'gh'
# Denied: more than one command, or anything the shell would rewrite.
expect 2 'git log > out'
expect 2 'git log >> out'
expect 2 'git log < in'
expect 2 'git log; rm x'
expect 2 'git log && rm x'
expect 2 'git log || rm x'
expect 2 'git log | sh'
expect 2 'git log & rm x'
expect 2 'git log $(rm x)'
expect 2 'git log `rm x`'
expect 2 'git log ${HOME}'
expect 2 'git log $HOME'
expect 2 'git log "--output=x"'
expect 2 "git log '--output=x'"
expect 2 "git log --out''put=x"
expect 2 'git log --out{put,}=x'
expect 2 'git log *'
expect 2 'git log ?'
expect 2 'git log \--output=x'
expect 2 'git log
rm x'
expect 2 'git log (x)'
expect 2 'git log	--output=x'
# Denied: anything else.
expect 2 'rm -rf x'
expect 2 'sh -c git log'
expect 2 "sh -c 'git log'"
expect 2 'FOO=1 git log'
expect 2 '/usr/bin/git log'
expect 2 'env git log'
expect 2 'cat README.md'
expect 2 'ls'
expect 2 ''
expect 2 ' '
# Malformed or unexpected input denies (fail closed).
check 2 ''
check 2 'not json'
check 2 '{'
check 2 '{}'
check 2 '{"tool_input": {}}'
check 2 '{"tool_input": {"command": null}}'
check 2 '{"tool_input": {"command": 5}}'
check 2 '{"tool_input": {"command": ["git", "log"]}}'
check 2 '[]'
check 2 'null'

# A denial says what is allowed, on stderr.
printf '%s' '{"tool_input": {"command": "rm x"}}' | sh "$root/hooks/explorer-bash.sh" >/dev/null 2>"$tmp/err"
grep -q 'git log' "$tmp/err" || {
	echo "FAIL: a denial doesn't name the allowed forms"
	fail=1
}

[ "$fail" = 0 ] && echo "explorer-bash: all passed"
exit "$fail"
