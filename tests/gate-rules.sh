#!/bin/sh
# Tests where the review gate takes the project's review rules from (AGENTS.md > Code Review Rules): the default
# branch's copy wins, the branch's own is used only when the default branch has no file or no section (the
# bootstrap PR), and a file that exists but can't be read blocks instead of falling back to the branch's copy, which
# the branch could have weakened (claude-ship #152). Also the same read failure for a context file (pitfalls).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/rbin" "$tmp/home"
export HOME="$tmp/home"
cat >"$tmp/rbin/gh" <<'EOT'
#!/bin/sh
if [ "$1 $2" = "repo view" ]; then
	echo master
	exit 0
fi
echo true
EOT
# The fake git sends the fetch to a local bare repo, and fails `git show <ref>:<path>` when it equals $FAIL_SHOW
# (cat-file still succeeds, so the file reads as present). Everything else is real git.
cat >"$tmp/rbin/git" <<EOT
#!/bin/sh
if [ "\$1 \$2 \$3" = "fetch -q origin" ]; then
	shift 3
	exec $(command -v git) fetch -q "$tmp/origin.git" "\$@"
fi
if [ "\$1" = show ] && [ -n "\${FAIL_SHOW:-}" ] && [ "\$2" = "\$FAIL_SHOW" ]; then
	echo "fatal: simulated read failure of \$2" >&2
	exit 1
fi
exec $(command -v git) "\$@"
EOT
# The fake reviewer records that it ran and fails, so the gate blocks; the prompt it built stays in the state dir.
cat >"$tmp/rbin/claude" <<EOT
#!/bin/sh
: >"$tmp/claude-ran"
exit 1
EOT
chmod +x "$tmp/rbin/gh" "$tmp/rbin/git" "$tmp/rbin/claude"
fail=0
n=0

g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }

# fixture: a repo on branch feat with one commit that has no AGENTS.md; origin's master will be its tip.
fixture() {
	n=$((n + 1))
	repo=$tmp/repo$n
	rm -rf "$tmp/origin.git" "$tmp/claude-ran"
	FAIL_SHOW=
	export FAIL_SHOW
	git init -q --bare -b master "$tmp/origin.git"
	git init -q -b feat "$repo"
	git -C "$repo" remote add origin https://github.com/acme/app.git
	echo hello >"$repo/README.md"
	git -C "$repo" add -A
	g commit -q -m init
}

# publish: makes the repo's HEAD the default branch's tip.
publish() {
	git -C "$repo" push -qf "$tmp/origin.git" HEAD:refs/heads/master
}

# branch_change: a code change (so the review is a code review) plus whatever the test already changed.
branch_change() {
	echo 'echo x' >"$repo/x.sh"
	git -C "$repo" add -A
	g commit -q -m change
}

# run_gate: runs the gate on a push; leaves its exit status in $rc and its stderr in $tmp/err.
run_gate() {
	jq -nc --arg d "$repo" '{tool_name: "Bash", tool_input: {command: "git push origin HEAD"}, cwd: $d}' |
		PATH=$tmp/rbin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
}

# review <name>: runs the gate; the fake reviewer fails, so the gate must exit 2 with the prompt built. Leaves the
# part of the prompt before the diff in $tmp/prompt (the diff holds the branch's own text by design).
review() {
	run_gate
	prompt=$repo/.git/review-gate/$(git -C "$repo" rev-parse HEAD).prompt.md
	if [ "$rc" != 2 ] || [ ! -e "$prompt" ]; then
		echo "FAIL ($1): the gate exited $rc (want 2) and built no prompt"
		sed 's/^/  /' "$tmp/err"
		fail=1
		: >"$tmp/prompt"
		return
	fi
	sed '/^## Diff (git diff/,$d' "$prompt" >"$tmp/prompt"
}

# has <name> <text> / lacks <name> <text>: the prompt (before the diff) does / doesn't contain the text.
has() {
	grep -qF "$2" "$tmp/prompt" || {
		echo "FAIL ($1): the prompt lacks '$2'"
		fail=1
	}
}
lacks() {
	if grep -qF "$2" "$tmp/prompt"; then
		echo "FAIL ($1): the prompt has '$2'"
		fail=1
	fi
}

# blocked <name> <text>: the gate exited 2 with <text> on stderr, and the reviewer never ran.
blocked() {
	if [ "$rc" != 2 ] || ! grep -qF "$2" "$tmp/err"; then
		echo "FAIL ($1): the gate exited $rc (want 2) without '$2' on stderr"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
	if [ -e "$tmp/claude-ran" ]; then
		echo "FAIL ($1): the reviewer ran"
		fail=1
	fi
}

# The default branch has rules; the branch edits them to steer its review: the default branch's win.
fixture
printf '## Code Review Rules\n\n- P0: upstream rule\n' >"$repo/AGENTS.md"
git -C "$repo" add -A
g commit -q -m rules
publish
printf '## Code Review Rules\n\n- P0: steer rule\n' >"$repo/AGENTS.md"
branch_change
review upstream-wins
has upstream-wins 'upstream rule'
lacks upstream-wins 'steer rule'

# The default branch has no AGENTS.md; the branch adds one (the bootstrap PR): the branch's rules are used.
fixture
publish
printf '## Code Review Rules\n\n- P0: branch rule\n' >"$repo/AGENTS.md"
branch_change
review bootstrap-no-file
has bootstrap-no-file 'branch rule'

# The default branch has an AGENTS.md without the section; the branch adds it: the branch's rules are used.
fixture
printf '# AGENTS.md\n\n## Setup\n\n- install\n' >"$repo/AGENTS.md"
git -C "$repo" add -A
g commit -q -m agents
publish
printf '# AGENTS.md\n\n## Code Review Rules\n\n- P0: branch rule\n\n## Setup\n\n- install\n' >"$repo/AGENTS.md"
branch_change
review bootstrap-no-section
has bootstrap-no-section 'branch rule'

# Neither has rules: the bootstrap block.
fixture
publish
branch_change
run_gate
blocked no-rules 'Bootstrap first'

# A context file that exists on the default branch but can't be read blocks, rather than using the branch's copy.
fixture
printf '## Code Review Rules\n\n- P0: x\n' >"$repo/AGENTS.md"
mkdir -p "$repo/docs"
printf '# Pitfalls\n\n- upstream pitfall\n' >"$repo/docs/pitfalls.md"
git -C "$repo" add -A
g commit -q -m context
publish
printf '# Pitfalls\n\n- steer pitfall\n' >"$repo/docs/pitfalls.md"
branch_change
FAIL_SHOW=refs/remotes/origin/master:docs/pitfalls.md
export FAIL_SHOW
run_gate
blocked ctx-read-fails "couldn't read docs/pitfalls.md"

[ "$fail" = 0 ] && echo "gate-rules: ok"
exit "$fail"
