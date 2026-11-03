#!/bin/sh
# Tests hooks/git-hook.sh, the git hook stubs' target: its pre-push refuses Claude's push of a commit with no `.pass`
# or `.waived` in the review state, whatever started the push, and chains the repo's own hooks (docs/gate.md ›
# Pre-push check). Real repos pushing to bare remotes, through git's own hook mechanism: core.hooksPath in a temporary
# global config points at stubs that run the hook. The GitHub URL is a rewrite (url.<bare>.insteadOf) of the bare
# remote; a stub gh answers the opt-in lookup; a stub ps stands in for the process tree.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/stubs"
. "$root/tests/lib/gitenv.sh"
isolate_git "$tmp"
git config --global core.hooksPath "$tmp/stubs"
git config --global user.name t
git config --global user.email t@t
git config --global init.defaultBranch main
fail=0

# One stub per hook the tests use, as install.sh writes them.
for h in pre-push pre-commit; do
	printf '#!/bin/sh\nexec sh '\''%s/hooks/git-hook.sh'\'' %s "$@"\n' "$root" "$h" >"$tmp/stubs/$h"
	chmod +x "$tmp/stubs/$h"
done

# gh: `variable get` answers by $GH_MODE (true, false, notfound or error) and logs the repo it was asked about.
cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
[ "$1 $2" = "variable get" ] || exit 2
echo "$*" >>"$GH_LOG"
case $GH_MODE in
true) echo true ;;
false) echo false ;;
notfound) echo "HTTP 404: Not Found (https://api.github.com/repos/o/r/actions/variables/CLAUDE_AUTONOMOUS)" >&2; exit 1 ;;
*) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
esac
EOF
# ps: the process tree is a stand-in (`-o ppid= -p N`, `-o comm= -p N`): with FAKE_ANCESTRY=claude, every process's parent
# is 4242, a process named claude whose parent is PID 1; with none, the parent is PID 1 and no process is named claude.
cat >"$tmp/bin/ps" <<'EOF'
#!/bin/sh
what=$2
pid=$4
case $what in
ppid=)
	if [ "$FAKE_ANCESTRY" = claude ] && [ "$pid" != 4242 ]; then echo 4242; else echo 1; fi
	;;
comm=)
	if [ "$pid" = 4242 ]; then echo claude; else echo sh; fi
	;;
esac
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/ps"
GH_LOG=$tmp/gh.log
export GH_LOG
: >"$GH_LOG"

n=0
# mkrepo: a repo $repo with one commit on main and `origin` = https://github.com/o/r.git, which really is a bare repo
# $bare. The first commit has passed review.
mkrepo() {
	n=$((n + 1))
	repo=$tmp/work$n
	bare=$tmp/bare$n.git
	git init -q --bare "$bare"
	git init -q "$repo"
	git -C "$repo" config url."$bare".insteadOf https://github.com/o/r.git
	git -C "$repo" remote add origin https://github.com/o/r.git
	git -C "$repo" commit -q --allow-empty -m first
	pass
}
# commit <message>: a new commit on the current branch; no review yet.
commit() {
	git -C "$repo" commit -q --allow-empty -m "$1"
}
# pass [<rev>]: a passing review for a commit (default HEAD); waive: the user's waiver of HEAD.
pass() {
	mkdir -p "$repo/.git/review-gate"
	: >"$repo/.git/review-gate/$(git -C "$repo" rev-parse "${1:-HEAD}").pass"
}
waive() {
	mkdir -p "$repo/.git/review-gate"
	: >"$repo/.git/review-gate/$(git -C "$repo" rev-parse HEAD).waived"
}

# who: claude (the variable), ancestor (a process named claude, from the stub ps), real (nothing faked: the caller
# supplies it), or user (neither). mode: what gh answers.
who=claude
mode=true
# gpush <dir> <args>...: a push in a directory, as $who; leaves the status in $rc and the output in $tmp/out.
gpush() {
	d=$1
	shift
	case $who in
	claude) e="env CLAUDE_CODE_CHILD_SESSION=1 FAKE_ANCESTRY=none" ;;
	ancestor) e="env -u CLAUDE_CODE_CHILD_SESSION FAKE_ANCESTRY=claude" ;;
	*) e="env -u CLAUDE_CODE_CHILD_SESSION FAKE_ANCESTRY=none" ;;
	esac
	# shellcheck disable=SC2086 # $e is a fixed command with words to split
	(cd "$d" && GH_MODE=$mode PATH=$tmp/bin:$PATH $e git push -q "$@" 2>&1) >"$tmp/out"
	rc=$?
}

# on_remote <ref>: does the bare repo have it?
on_remote() {
	git -C "$bare" rev-parse --verify -q "$1" >/dev/null
}
# want <label> <pushed: yes or no>: the push's status, the remote's branch and (when refused) the message.
want_push() {
	if [ "$2" = yes ]; then
		if [ "$rc" != 0 ]; then
			echo "FAIL (refused, want pushed): $1"
			sed 's/^/  /' "$tmp/out"
			fail=1
		fi
	elif [ "$rc" = 0 ]; then
		echo "FAIL (pushed, want refused): $1"
		fail=1
	elif ! grep -q 'claude-ship: push refused' "$tmp/out" && [ "${3:-}" != other ]; then
		echo "FAIL (no refusal message): $1"
		sed 's/^/  /' "$tmp/out"
		fail=1
	fi
}

# --- the review state ---
mkrepo
who=claude
gpush "$repo" origin main
want_push "a reviewed commit" yes
on_remote refs/heads/main || {
	echo "FAIL: the reviewed commit didn't reach the remote"
	fail=1
}

mkrepo
commit second
gpush "$repo" origin main
want_push "an unreviewed commit" no
on_remote refs/heads/main && {
	echo "FAIL: the unreviewed commit reached the remote"
	fail=1
}
short=$(git -C "$repo" rev-parse --short HEAD)
grep -q "$short" "$tmp/out" || {
	echo "FAIL: the refusal doesn't name $short"
	sed 's/^/  /' "$tmp/out"
	fail=1
}
grep -q 'refs/heads/main' "$tmp/out" || {
	echo "FAIL: the refusal doesn't name the remote ref"
	fail=1
}
grep -q 'plain `git push`' "$tmp/out" && grep -q -- '--no-verify' "$tmp/out" && grep -q 'ask the user to waive' "$tmp/out" || {
	echo "FAIL: the refusal lacks its advice"
	sed 's/^/  /' "$tmp/out"
	fail=1
}

mkrepo
commit second
waive
gpush "$repo" origin main
want_push "a waived commit" yes

mkrepo
commit second
git -C "$repo" tag -a -m t v-good
gpush "$repo" origin refs/tags/v-good
want_push "an annotated tag on an unreviewed commit" no
mkrepo
git -C "$repo" tag -a -m t v-good
gpush "$repo" origin refs/tags/v-good
want_push "an annotated tag on a reviewed commit" yes
on_remote refs/tags/v-good || {
	echo "FAIL: the tag didn't reach the remote"
	fail=1
}

# Only another sha has a .pass: the pushed commit is the one that counts.
mkrepo
commit second
commit third
pass HEAD~2
gpush "$repo" origin main
want_push "a pass on another commit" no

# Two refs in one push, one unreviewed: nothing is pushed.
mkrepo
git -C "$repo" branch other
git -C "$repo" checkout -q other
commit unreviewed
git -C "$repo" checkout -q main
gpush "$repo" origin main other
want_push "two refs, one unreviewed" no
{ on_remote refs/heads/main || on_remote refs/heads/other; } && {
	echo "FAIL: part of a refused push reached the remote"
	fail=1
}

# A delete sends no commit.
mkrepo
git -C "$repo" branch gone
gpush "$repo" origin main gone
want_push "pushing the branches to delete" yes
gpush "$repo" origin :gone
want_push "a delete" yes
on_remote refs/heads/gone && {
	echo "FAIL: the delete didn't happen"
	fail=1
}

# A worktree reads the common directory's state.
mkrepo
git -C "$repo" worktree add -q -b wt "$tmp/wt$n"
git -C "$tmp/wt$n" commit -q --allow-empty -m on-worktree
pass "$(git -C "$tmp/wt$n" rev-parse HEAD)"
gpush "$tmp/wt$n" origin wt
want_push "a worktree's reviewed commit" yes
git -C "$tmp/wt$n" commit -q --allow-empty -m more
gpush "$tmp/wt$n" origin wt
want_push "a worktree's unreviewed commit" no

# --- whose push it is ---
mkrepo
commit second
who=user
: >"$GH_LOG"
gpush "$repo" origin main
want_push "the user's own push" yes
on_remote refs/heads/main || {
	echo "FAIL: the user's push didn't arrive"
	fail=1
}
[ ! -s "$GH_LOG" ] || {
	echo "FAIL: the user's push asked GitHub about the opt-in"
	fail=1
}

mkrepo
commit second
who=ancestor
gpush "$repo" origin main
want_push "a push under a process named claude (stub ps)" no

# The real process tree: a copy of sh named claude runs the push, with the variable unset and the real ps.
mkrepo
commit second
cp "$(command -v sh)" "$tmp/claude"
mkdir -p "$tmp/realbin"
ln -sf "$tmp/bin/gh" "$tmp/realbin/gh"
(cd "$repo" && env -u CLAUDE_CODE_CHILD_SESSION GH_MODE=true PATH=$tmp/realbin:$PATH "$tmp/claude" -c 'git push -q origin main 2>&1; s=$?; exit $s') >"$tmp/out" 2>&1
rc=$?
want_push "a push under a real process named claude" no
who=claude

# --- the opt-in ---
mkrepo
commit second
mode=notfound
gpush "$repo" origin main
want_push "a repo that never opted in (variable not found)" yes
mkrepo
commit second
mode=false
gpush "$repo" origin main
want_push "a repo whose variable isn't true" yes
mkrepo
commit second
mode=error
gpush "$repo" origin main
want_push "a gh error" no
grep -q 'CLAUDE_AUTONOMOUS for o/r' "$tmp/out" || {
	echo "FAIL: the gh error's refusal doesn't name the repo"
	sed 's/^/  /' "$tmp/out"
	fail=1
}
mode=true

# gh missing: a PATH with the tools the hook needs, but no gh.
mkrepo
commit second
mkdir -p "$tmp/nogh"
for t in git sh sed sort grep mktemp cat rm dirname basename head tail tr wc cut awk env id uname expr; do
	p=$(command -v "$t") && ln -sf "$p" "$tmp/nogh/$t"
done
ln -sf "$tmp/bin/ps" "$tmp/nogh/ps"
(cd "$repo" && CLAUDE_CODE_CHILD_SESSION=1 FAKE_ANCESTRY=none PATH=$tmp/nogh git push -q origin main 2>&1) >"$tmp/out"
rc=$?
want_push "gh missing" no

# A destination that isn't GitHub is not checked (and GitHub isn't asked).
mkrepo
commit second
git -C "$repo" remote set-url origin "$bare"
: >"$GH_LOG"
mode=error
gpush "$repo" origin main
want_push "a non-GitHub destination" yes
[ ! -s "$GH_LOG" ] || {
	echo "FAIL: a non-GitHub destination asked GitHub"
	fail=1
}
mode=true

# pushurl is GitHub while url isn't: enforced (both sides of the pair).
mkrepo
commit second
git -C "$repo" remote set-url origin "$tmp/elsewhere.git"
git init -q --bare "$tmp/elsewhere.git"
git -C "$repo" config remote.origin.pushurl https://github.com/o/r.git
gpush "$repo" origin main
want_push "a GitHub pushurl next to a local url" no
mkrepo
git -C "$repo" remote set-url origin "$tmp/elsewhere2.git"
git init -q --bare "$tmp/elsewhere2.git"
git -C "$repo" config remote.origin.pushurl https://github.com/o/r.git
gpush "$repo" origin main
want_push "a GitHub pushurl, reviewed" yes
mkrepo
commit second
git -C "$repo" remote set-url origin https://github.com/o/r.git
git -C "$repo" config remote.origin.pushurl "$bare"
gpush "$repo" origin main
want_push "a GitHub url with a local pushurl (pushes to the local one)" yes

# --- called directly, with the arguments and lines git documents ---
# hook <remote> <url> <lines>: pre-push in $repo, with the lines on stdin.
hook() {
	r=$1
	u=$2
	printf '%s' "$3" | (cd "$repo" && env CLAUDE_CODE_CHILD_SESSION=1 FAKE_ANCESTRY=none GH_MODE=$mode PATH=$tmp/bin:$PATH sh "$root/hooks/git-hook.sh" pre-push "$r" "$u" >"$tmp/out" 2>&1)
	rc=$?
}
zero=0000000000000000000000000000000000000000
mkrepo
commit second
good=$(git -C "$repo" rev-parse HEAD~1)
bad=$(git -C "$repo" rev-parse HEAD)
hook origin https://github.com/o/r.git ''
want_push "empty stdin" yes
hook origin https://github.com/o/r.git "refs/heads/main $good refs/heads/main $zero
"
want_push "direct: a reviewed line" yes
hook origin https://github.com/o/r.git "refs/heads/main $bad refs/heads/main $zero
"
want_push "direct: an unreviewed line" no
hook origin https://github.com/o/r.git "refs/heads/main $good refs/heads/main $zero
refs/heads/x $bad refs/heads/x $zero
"
want_push "direct: the second line is unreviewed" no
hook origin https://github.com/o/r.git "(delete) $zero refs/heads/main $bad
"
want_push "direct: a delete" yes
hook origin https://github.com/o/r.git "refs/heads/main $good refs/heads/main $zero"
want_push "direct: a last line without a newline" yes
for bogus in 'garbage' 'refs/heads/main' 'refs/heads/main zzzz refs/heads/main 0' "refs/heads/main $good refs/heads/main" \
	'refs/heads/main 1234567890123456789012345678901234567890 refs/heads/main 0' "refs/heads/main $good$good refs/heads/main $zero" ''; do
	if [ -z "$bogus" ]; then
		hook origin https://github.com/o/r.git "
"
	else
		hook origin https://github.com/o/r.git "$bogus
"
	fi
	want_push "direct: malformed line '$bogus'" no
done
# Push by URL: both arguments are the URL, and it is the destination.
hook https://github.com/o/r.git https://github.com/o/r.git "refs/heads/main $bad refs/heads/main $zero
"
want_push "direct: a push by URL, unreviewed" no
grep -q 'o/r' "$GH_LOG" || {
	echo "FAIL: a push by URL didn't look up its repo"
	fail=1
}
# A URL that is GitHub's but unreadable is refused; a local path isn't GitHub.
hook origin 'https://github.com/justone' "refs/heads/main $good refs/heads/main $zero
"
want_push "direct: an unreadable GitHub URL" no
hook "$bare" "$bare" "refs/heads/main $bad refs/heads/main $zero
"
want_push "direct: a local path" yes

# --- the repo's own hooks ---
# pre-push runs with the same arguments and stdin, for Claude's push and the user's; its failure fails the push.
for who in claude user; do
	mkrepo
	mkdir -p "$repo/.git/hooks"
	cat >"$repo/.git/hooks/pre-push" <<EOF
#!/bin/sh
echo "\$@" >"$tmp/own.args"
cat >"$tmp/own.stdin"
exit \${OWN_STATUS:-0}
EOF
	chmod +x "$repo/.git/hooks/pre-push"
	rm -f "$tmp/own.args" "$tmp/own.stdin"
	gpush "$repo" origin main
	want_push "the repo's own pre-push ($who)" yes
	[ "$(cat "$tmp/own.args" 2>/dev/null)" = "origin $bare" ] || [ "$(cat "$tmp/own.args" 2>/dev/null)" = "origin https://github.com/o/r.git" ] || {
		echo "FAIL ($who): the repo's pre-push got the wrong arguments: $(cat "$tmp/own.args" 2>/dev/null)"
		fail=1
	}
	grep -q "^refs/heads/main $(git -C "$repo" rev-parse HEAD) refs/heads/main " "$tmp/own.stdin" 2>/dev/null || {
		echo "FAIL ($who): the repo's pre-push didn't get the ref lines on stdin"
		fail=1
	}
	commit again
	pass
	OWN_STATUS=1 gpush "$repo" origin main
	want_push "the repo's own failing pre-push ($who)" no other
	on_remote refs/heads/main && [ "$(git -C "$bare" rev-parse refs/heads/main)" = "$(git -C "$repo" rev-parse HEAD)" ] && {
		echo "FAIL ($who): a failing pre-push didn't stop the push"
		fail=1
	}
done
who=claude
# A refusal comes first: the repo's own hook doesn't run for a refused push.
mkrepo
commit second
mkdir -p "$repo/.git/hooks"
printf '#!/bin/sh\n: >"%s/own.ran"\n' "$tmp" >"$repo/.git/hooks/pre-push"
chmod +x "$repo/.git/hooks/pre-push"
rm -f "$tmp/own.ran"
gpush "$repo" origin main
want_push "a refused push with the repo's own pre-push" no
# Every other hook is chained with its arguments; its failure fails the command.
mkrepo
mkdir -p "$repo/.git/hooks"
printf '#!/bin/sh\necho "$@" >"%s/own.commit"\nexit 0\n' "$tmp" >"$repo/.git/hooks/pre-commit"
chmod +x "$repo/.git/hooks/pre-commit"
rm -f "$tmp/own.commit"
git -C "$repo" commit -q --allow-empty -m viahook || {
	echo "FAIL: a commit with a passing pre-commit failed"
	fail=1
}
[ -e "$tmp/own.commit" ] || {
	echo "FAIL: the repo's pre-commit didn't run"
	fail=1
}
printf '#!/bin/sh\nexit 1\n' >"$repo/.git/hooks/pre-commit"
if git -C "$repo" commit -q --allow-empty -m blocked 2>/dev/null; then
	echo "FAIL: a failing pre-commit didn't fail the commit"
	fail=1
fi
rm -f "$repo/.git/hooks/pre-commit"
git -C "$repo" commit -q --allow-empty -m nohook || {
	echo "FAIL: a commit with no pre-commit failed"
	fail=1
}
# No arguments: usage error.
if sh "$root/hooks/git-hook.sh" >/dev/null 2>&1; then
	echo "FAIL: git-hook.sh with no hook name succeeded"
	fail=1
fi

[ "$fail" = 0 ] && echo "git-hook: ok"
exit "$fail"
