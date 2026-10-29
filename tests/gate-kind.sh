#!/bin/sh
# Tests which reviewer a push gets (claude-ship #105): a change of only docs gets the Haiku claims check, but a
# .md file that steers Claude (a prompt, skill, agent, AGENTS.md or CLAUDE.md) is behaviour and gets the Sonnet
# finder. A rename counts by both paths, and a `git diff` that fails blocks the push.
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
# FAIL_DIFF=<n> makes the nth `git diff --name-only` of a push fail (the gate lists the changed paths twice: to see
# whether anything changed, then to classify it); the fetch of origin goes to the local bare repo.
cat >"$tmp/rbin/git" <<EOT
#!/bin/sh
if [ "\$1 \$2 \$3" = "fetch -q origin" ]; then
	shift 3
	exec $(command -v git) fetch -q "$tmp/origin.git" "\$@"
fi
if [ -n "\${FAIL_DIFF:-}" ] && [ "\$1 \$2" = "diff --name-only" ]; then
	echo x >>"$tmp/diffs"
	[ "\$(wc -l <"$tmp/diffs")" -ne "\$FAIL_DIFF" ] || exit 1
fi
exec $(command -v git) "\$@"
EOT
# The fake reviewer logs its model and finds nothing, so the push passes.
cat >"$tmp/rbin/claude" <<EOT
#!/bin/sh
while [ \$# -gt 0 ]; do
	if [ "\$1" = --model ]; then
		echo "\$2" >>"$tmp/models"
	fi
	shift
done
printf '{"structured_output":{"findings":[]}}'
EOT
chmod +x "$tmp/rbin/gh" "$tmp/rbin/git" "$tmp/rbin/claude"
fail=0
n=0

g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }

# fixture: a repo on branch feat whose default branch (origin's master) has the rules and a script x.sh.
fixture() {
	n=$((n + 1))
	repo=$tmp/repo$n
	rm -rf "$tmp/origin.git"
	git init -q --bare -b master "$tmp/origin.git"
	git init -q -b feat "$repo"
	git -C "$repo" remote add origin https://github.com/acme/app.git
	printf '## Code Review Rules\n\n- P0: x\n' >"$repo/AGENTS.md"
	echo 'echo x' >"$repo/x.sh"
	git -C "$repo" add -A
	g commit -q -m base
	git -C "$repo" push -qf "$tmp/origin.git" HEAD:refs/heads/master
}

# push <name> <exit code> <reviewer model, or none>: runs the gate on a push of the current branch and checks the
# exit code and the model of the first reviewer that ran.
push() {
	rm -f "$tmp/models" "$tmp/diffs"
	jq -nc --arg d "$repo" '{tool_name: "Bash", tool_input: {command: "git push origin HEAD"}, cwd: $d}' |
		PATH=$tmp/rbin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	got=$(head -n 1 "$tmp/models" 2>/dev/null)
	if [ "$rc" != "$2" ] || [ "${got:-none}" != "$3" ]; then
		echo "FAIL ($1): exit $rc (want $2), first reviewer '${got:-none}' (want $3)"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}

# change <name> <reviewer model> <path>...: a branch that adds a file at each path.
change() {
	name=$1
	want=$2
	shift 2
	fixture
	for p in "$@"; do
		mkdir -p "$repo/$(dirname "$p")"
		echo "text of $p" >"$repo/$p"
	done
	git -C "$repo" add -A
	g commit -q -m change
	push "$name" 0 "$want"
}

# Docs only: the claims check.
change readme haiku README.md
change docs-md haiku docs/x.md
change docs-image haiku docs/img.png
change docs-two haiku README.md docs/guide.md
# Behaviour in a .md file, or any other file: the finder.
change prompt sonnet hooks/review-prompt.md
change skill sonnet skills/ship/SKILL.md
change agent sonnet agents/a.md
change claude-skill sonnet .claude/skills/x/SKILL.md
change agents-md sonnet AGENTS.md
change nested-claude-md sonnet sub/CLAUDE.md
change docs-agents-md sonnet docs/AGENTS.md
change docs-claude-md sonnet docs/CLAUDE.md
change mixed sonnet README.md skills/ship/SKILL.md
change script sonnet scripts/tool.sh
change image sonnet pic.png

# A script renamed to .md is a change to the script, and so code.
fixture
g mv x.sh x.md
g commit -q -m rename
push rename 0 sonnet

# A git diff that fails must block the push, not count as an empty (unchanged, or docs-only) change.
for nth in 1 2; do
	fixture
	echo 'text' >"$repo/README.md"
	git -C "$repo" add -A
	g commit -q -m docs
	FAIL_DIFF=$nth
	export FAIL_DIFF
	push "diff-fails-$nth" 2 none
	unset FAIL_DIFF
done

[ "$fail" = 0 ] && echo "gate-kind: ok"
exit "$fail"
