#!/bin/sh
# Pins claude-ship #349: a canonical push from a linked worktree whose branch tracks origin/main (the default for
# `git worktree add -b <branch> <dir> origin/main`) is reviewed like any other, and the pass lands in the repository's common
# directory, where the pre-push check reads it. The refusals #349 blamed on that upstream came from compound commands
# (`git status && git push`), which the gate now blocks up front (tests/gate-push.sh). The reviewer, gh and the fetch are fakes.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/lib/shfmt.sh"
. "$root/tests/lib/gitenv.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/rbin" "$tmp/home"
link_shfmt "$tmp/home"
export HOME="$tmp/home" GIT_TERMINAL_PROMPT=0
gate_git_hooks "$HOME"
export GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z"
cat >"$tmp/rbin/gh" <<'EOT'
#!/bin/sh
case "$1 $2" in
"repo view")
	echo main
	exit 0
	;;
"pr list") exit 0 ;;
"issue list")
	echo '[]'
	exit 0
	;;
esac
case "$1 $2 $3" in "variable get CLAUDE_P3_LABELS") exit 1 ;; esac
echo true
EOT
cat >"$tmp/rbin/git" <<EOT
#!/bin/sh
if [ "\$1 \$2 \$3" = "fetch -q origin" ]; then
	shift 3
	exec $(command -v git) fetch -q "$tmp/origin.git" "\$@"
fi
exec $(command -v git) "\$@"
EOT
cat >"$tmp/rbin/claude" <<'EOT'
#!/bin/sh
case " $* " in
*" sonnet "*) printf '{"structured_output":{"findings":[]}}' ;;
*) printf '{"structured_output":{"verdicts":[]}}' ;;
esac
EOT
chmod +x "$tmp/rbin/gh" "$tmp/rbin/git" "$tmp/rbin/claude"
fail=0

git init -q --bare -b main "$tmp/origin.git"
main=$tmp/main
git init -q -b main "$main"
git -C "$main" remote add origin https://github.com/acme/app.git
printf '## Code Review Rules\n\n- P0: x\n' >"$main/AGENTS.md"
git -C "$main" add AGENTS.md
git -C "$main" -c user.name=t -c user.email=t@t commit -q -m rules
git -C "$main" push -q "$tmp/origin.git" HEAD:refs/heads/main
git -C "$main" fetch -q "$tmp/origin.git" +refs/heads/main:refs/remotes/origin/main
git -C "$main" worktree add -q "$tmp/wt" -b fix/x origin/main 2>/dev/null
echo 'echo x' >"$tmp/wt/x.sh"
git -C "$tmp/wt" add -A
git -C "$tmp/wt" -c user.name=t -c user.email=t@t commit -q -m change
[ "$(git -C "$tmp/wt" rev-parse --abbrev-ref '@{u}')" = origin/main ] || {
	echo "FAIL: the worktree's branch doesn't track origin/main, so this test pins nothing"
	fail=1
}
state=$(git -C "$main" rev-parse --path-format=absolute --git-common-dir)/review-gate

# run <session directory> <command>: the gate on a Bash call, with no pass yet.
run() {
	rm -rf "$state"
	jq -nc --arg c "$2" --arg d "$1" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
		PATH=$tmp/rbin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	head=$(git -C "$tmp/wt" rev-parse HEAD)
	if [ "$rc" != 0 ] || [ ! -e "$state/$head.pass" ]; then
		echo "FAIL (exit $rc, pass: $([ -e "$state/$head.pass" ] && echo yes || echo no)): $2 (from $1)"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}
run "$tmp/wt" 'git push -u origin fix/x'
run "$main" "cd $tmp/wt && git push -u origin fix/x"
run "$tmp/wt" 'git push'
run "$tmp/wt" 'git push origin HEAD 2>&1 | tail -15'
# With the upstream gone, as the agents in #349 did by hand, nothing changes.
git -C "$tmp/wt" branch -q --unset-upstream
run "$tmp/wt" 'git push -u origin fix/x'

[ "$fail" = 0 ] && echo "gate-worktree-upstream: ok"
exit "$fail"
