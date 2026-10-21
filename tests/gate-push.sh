#!/bin/sh
# Tests the review gate's checks on what a push sends and where: origin's URLs must all name the pushed repo
# (claude-ship #11, #13), and nothing earlier in the command may change the git config the gate read (#14).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
printf '#!/bin/sh\necho true\n' >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
export HOME="$tmp/home"
fail=0
n=0

# fixture <origin URL>: a new repo on branch feat with one commit, whose review already passed.
fixture() {
	n=$((n + 1))
	repo=$tmp/repo$n
	git init -q -b feat "$repo"
	git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
	git -C "$repo" remote add origin "$1"
	mkdir -p "$repo/.git/review-gate"
	: >"$repo/.git/review-gate/$(git -C "$repo" rev-parse HEAD).pass"
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
expect 0 'git status && git push origin HEAD 2>&1 | tail -3'
expect 0 'git fetch -q origin main && git push origin HEAD'
# Config written earlier in the same command is read by the push but not by the gate.
expect 2 'git config push.followTags true && git push origin HEAD'
expect 2 'git -C . config remote.origin.mirror true; git push origin HEAD'
expect 2 'git remote set-url --push origin https://github.com/acme/other.git && git push origin HEAD'
expect 2 'git branch -u origin/main && git push'
expect 2 'git commit -qm x && git push origin HEAD'
expect 2 'sh -c "git config push.default matching" && git push'
expect 2 'echo "[push] followTags = true" >> .git/config && git push origin HEAD'
expect 2 'printf x >> ~/.gitconfig; git push origin HEAD'
expect 2 'cat x >> ~/.config/git/config; git push origin HEAD'

# A fetch URL that isn't the pushed repo, even one that isn't GitHub's, supplies the review's base and rules.
fixture /tmp/base.git
git -C "$repo" remote set-url --add origin https://github.com/acme/app.git
git -C "$repo" remote set-url --push origin https://github.com/acme/app.git
expect 2 'git push origin HEAD'
fixture https://github.com/acme/app.git
git -C "$repo" remote set-url --add origin https://github.com/acme/other.git
expect 2 'git push origin HEAD'

# A trailing dot on the host is still GitHub; a dirty tree shows the gate reached its checks.
for url in https://github.com./acme/app.git git@github.com.:acme/app.git ssh://git@ssh.github.com.:443/acme/app.git; do
	fixture "$url"
	: >"$repo/dirty"
	expect 2 'git push origin HEAD'
done

[ "$fail" = 0 ] && echo "gate-push: ok"
exit "$fail"
