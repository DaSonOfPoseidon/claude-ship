#!/bin/sh
# Tests that install.sh runs origin/main's installer, not the checkout's: a checkout one commit behind a main
# whose installer deploys one more file still deploys it (claude-ship #20).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/src/scripts"
git() { command git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
fail=0

# main: this tree's installer, then a commit whose installer also deploys a marker file.
cp -R "$root/agents" "$root/hooks" "$root/skills" "$root/install.sh" "$tmp/src/"
cp "$root/scripts/codex-status.sh" "$tmp/src/scripts/"
git init -q "$tmp/src"
git -C "$tmp/src" add -A
git -C "$tmp/src" commit -qm old
printf ': >"$dest/main-installer-ran"\n' >>"$tmp/src/install.sh"
git -C "$tmp/src" commit -qam new
git clone -q --bare "$tmp/src" "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/checkout"
git -C "$tmp/checkout" reset -q --hard HEAD~1

# The user's own agents stay.
mkdir -p "$tmp/dest/agents"
: >"$tmp/dest/agents/mine.md"
if ! CLAUDE_HOME="$tmp/dest" sh "$tmp/checkout/install.sh" >"$tmp/out" 2>&1; then
	echo "FAIL: install.sh exited non-zero"
	sed 's/^/  /' "$tmp/out"
	fail=1
fi
for f in main-installer-ran hooks/review-gate.sh hooks/orchestrate-hint.sh skills/ship/SKILL.md \
	skills/ship/orchestrate.md skills/ship/codex-status.sh agents/ship-explorer.md agents/ship-implementer.md \
	agents/ship-codex.md hooks/codex-bash.sh agents/mine.md; do
	[ -e "$tmp/dest/$f" ] || {
		echo "FAIL: $f wasn't deployed"
		fail=1
	}
done
# Hooks and skill scripts are registered or run as commands, so every deployed script is executable.
for f in "$tmp"/dest/hooks/*.sh "$tmp"/dest/skills/ship/*.sh; do
	[ -x "$f" ] || {
		echo "FAIL: ${f#"$tmp"/dest/} isn't executable"
		fail=1
	}
done
# What's deployed is main's, not the checkout's.
grep -q "Deployed claude-ship $(git -C "$tmp/src" rev-parse --short HEAD)" "$tmp/out" || {
	echo "FAIL: didn't deploy main's commit"
	sed 's/^/  /' "$tmp/out"
	fail=1
}

[ "$fail" = 0 ] && echo "install: ok"
exit "$fail"
