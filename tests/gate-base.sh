#!/bin/sh
# Tests the branch the review gate diffs against: the repo's default branch as GitHub reports it, not a
# hardcoded main (claude-ship #51), fetched over whatever the local tracking ref says.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
export HOME="$tmp/home"
# The fake gh reports $DEFAULT as the default branch (and fails when it's empty); every repo opted in.
cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "repo view" ]; then
	[ -n "${DEFAULT:-}" ] || exit 1
	echo "$DEFAULT"
	exit 0
fi
echo true
EOF
# origin's URL must stay GitHub's for the gate's repo checks, so the fake git fetches from a local bare repo.
cat >"$tmp/bin/git" <<EOF
#!/bin/sh
if [ "\$1 \$2 \$3" = "fetch -q origin" ]; then
	shift 3
	exec $(command -v git) fetch -q "$tmp/origin.git" "\$@"
fi
exec $(command -v git) "\$@"
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/git"
fail=0

# A repo on branch feat whose one commit is also the tip of origin's master; no review has passed.
repo=$tmp/repo
git init -q -b feat "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
git -C "$repo" remote add origin https://github.com/acme/app.git
git init -q --bare -b master "$tmp/origin.git"
git -C "$repo" push -q "$tmp/origin.git" HEAD:refs/heads/master

# expect <exit code> <default branch>: runs the gate on `git push -u origin HEAD` in the repo.
expect() {
	jq -nc --arg d "$repo" '{tool_name: "Bash", tool_input: {command: "git push -u origin HEAD"}, cwd: $d}' |
		DEFAULT=$2 PATH=$tmp/bin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	if [ "$rc" != "$1" ]; then
		echo "FAIL (exit $rc, want $1) with default branch '$2'"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}

# HEAD is master's tip, so there's nothing to review once the gate diffs against master.
expect 0 master
# GitHub must say which branch: a missing one, one origin doesn't have, or a bad ref name blocks.
expect 2 ''
expect 2 main
expect 2 'a..b'
# A new commit on the branch needs review (this repo has no rules, so it blocks), even when the local
# tracking ref was moved onto HEAD to make the diff empty: the fetch resets it to origin's master.
echo y >"$repo/y"
git -C "$repo" add y
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m y
git -C "$repo" update-ref refs/remotes/origin/master HEAD
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/feat
expect 2 master
grep -q 'Code Review Rules' "$tmp/err" || {
	echo "FAIL: the new commit wasn't diffed against origin's master"
	sed 's/^/  /' "$tmp/err"
	fail=1
}

[ "$fail" = 0 ] && echo "gate-base: ok"
exit "$fail"
