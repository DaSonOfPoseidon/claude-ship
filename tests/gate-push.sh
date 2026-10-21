#!/bin/sh
# Tests the review gate's checks on what a push sends and where: origin's URLs must all name the pushed repo
# (claude-ship #11, #13), and a pushing command may contain only the push (#14, #25).
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
# Allowed next to a push: a leading `cd <dir> &&`, harmless redirects, and trailing pipes into read-only filters.
expect 0 "cd $repo && git push origin HEAD"
expect 0 'git push origin HEAD 2>&1'
expect 0 'git push origin HEAD >/dev/null 2>&1'
expect 0 'git push origin HEAD 2>/dev/null'
expect 0 'git push origin HEAD > /dev/stdout'
expect 0 'git push origin HEAD 2>&1 | tail -3'
expect 0 'git push origin HEAD 2>&1 | grep -v hint | head -5'
expect 0 'git -C . push origin HEAD | cat'
expect 0 "cd $repo && git push -u origin HEAD 2>&1 | tail -3"
# Quoted text that mentions a push is not a push.
expect 0 'gh pr create --title t --body "see git push"'
expect 0 'echo "git push" && echo done'

# Anything else in the command may change what the push sends after the gate read it.
# Codex round 2: `--output` rewrites the branch ref; an included config file can have any name.
expect 2 'git show --format=%H --no-patch --output=.git/refs/heads/feat evil && git push origin HEAD'
expect 2 "printf '[remote \"origin\"]\\nmirror = true\\n' > /tmp/settings && git push"
expect 2 'git status && git push origin HEAD'
expect 2 'git status; git push origin HEAD'
expect 2 'git ls-remote origin && git push origin HEAD'
expect 2 'git --no-pager log -1 && git -C . push origin HEAD'
expect 2 'git diff --output=.git/config && git push'
expect 2 'echo hi && git push origin HEAD'
expect 2 'true || git push origin HEAD'
expect 2 'git push origin HEAD && git status'
expect 2 'git push origin HEAD; echo done'
expect 2 'git push origin HEAD > out.txt'
expect 2 'git push origin HEAD 2>err.log'
expect 2 'git push origin HEAD >> /dev/null.x'
expect 2 'git push origin HEAD | tee out.txt'
expect 2 'git push origin HEAD | sh'
expect 2 'git push origin HEAD | tail -3 && git status'
expect 2 "cd $repo && echo x && git push origin HEAD"
expect 2 'git push origin HEAD $(git status)'
expect 2 'git push origin HEAD `git status`'
expect 2 '(git status; git push origin HEAD)'
expect 2 'git push origin HEAD &'
expect 2 'git push origin HEAD < input'
expect 2 'git push origin HEAD
git status'
expect 2 'FOO=1 git push origin HEAD'
# A fetch can move the branch the gate just reviewed (`--update-head-ok`).
expect 2 'git fetch --update-head-ok origin main:feat && git push origin HEAD'
# Config written earlier in the same command is read by the push but not by the gate.
expect 2 'git config push.followTags true && git push origin HEAD'
expect 2 'git -C . config remote.origin.mirror true; git push origin HEAD'
expect 2 'git remote set-url --push origin https://github.com/acme/other.git && git push origin HEAD'
expect 2 'git branch -u origin/main && git push'
expect 2 'git commit -qm x && git push origin HEAD'
expect 2 'git symbolic-ref HEAD refs/heads/other && git push'
expect 2 'git --no-pager config push.followTags true && git push origin HEAD'
expect 2 'git -p remote set-url origin /tmp/x && git push origin HEAD'
expect 2 'git -C . --no-pager branch -u origin/main && git push'
expect 2 'sh -c "git config push.default matching" && git push'
expect 2 'echo "[push] followTags = true" >> .git/config && git push origin HEAD'
expect 2 'printf x >> ~/.gitconfig; git push origin HEAD'
expect 2 'cat x >> ~/.config/git/config; git push origin HEAD'
expect 2 'cat x >> /etc/gitconfig; git push'

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

[ "$fail" = 0 ] && echo "gate-push: ok"
exit "$fail"
