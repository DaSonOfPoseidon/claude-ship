#!/bin/sh
# shellcheck disable=SC2034 # the lib's inputs are set here, for the sourced lib to read
# Tests hooks/review-lib.sh, the reviewer pieces the gate shares with the eval runner (tests/evals/run.sh): the prompt
# the gate writes for a fixture is the one build_prompt writes for the same inputs (so a runner measures what the gate
# sends), the small rules lifted out of the gate behave as they did, and a gate that can't read its lib blocks.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/rbin" "$tmp/home"
export HOME="$tmp/home"
export GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z"
cat >"$tmp/rbin/gh" <<'EOT'
#!/bin/sh
if [ "$1 $2" = "repo view" ]; then
	echo master
	exit 0
fi
if [ "$1 $2" = "pr list" ]; then
	echo 7
	exit 0
fi
if [ "$1 $2" = "api graphql" ]; then
	if [ -n "${THREADS:-}" ]; then
		printf '### x.sh:1\nCodex says: fix the quoting\n\n'
	fi
	exit 0
fi
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
# The fake reviewer fails, so the gate blocks; the prompt it built is left in the gate's state directory.
printf '#!/bin/sh\nexit 1\n' >"$tmp/rbin/claude"
chmod +x "$tmp/rbin/gh" "$tmp/rbin/git" "$tmp/rbin/claude"
fail=0
n=0

g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }

# fixture: a repo on branch feat whose default branch (origin's master) has the rules, a checklist and the pitfalls.
fixture() {
	n=$((n + 1))
	repo=$tmp/repo$n
	rm -rf "$tmp/origin.git"
	git init -q --bare -b master "$tmp/origin.git"
	git init -q -b feat "$repo"
	git -C "$repo" remote add origin https://github.com/acme/app.git
	printf '## Code Review Rules\n\n- P0: x\n\n## Other\n' >"$repo/AGENTS.md"
	printf '## Reviews\n\n- check a\n\n## Other\n' >"$repo/CONTRIBUTING.md"
	mkdir -p "$repo/docs"
	printf '# Pitfalls\n\n- p1\n' >"$repo/docs/pitfalls.md"
	git -C "$repo" add -A
	g commit -q -m base
	git -C "$repo" push -qf "$tmp/origin.git" HEAD:refs/heads/master
}

# gate: runs the gate on a push; it blocks, since the reviewer fails.
gate() {
	jq -nc --arg d "$repo" '{tool_name: "Bash", tool_input: {command: "git push origin HEAD"}, cwd: $d}' |
		PATH=$tmp/rbin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	prompt=$repo/.git/review-gate/$(git -C "$repo" rev-parse HEAD).prompt.md
}

# same <name>: the prompt the gate left equals build_prompt's, from inputs read here without the gate's code.
# Needs $kind, $checklist, $pitfalls, $threads, $scoped, $base and $filed_text set by the case.
same() {
	if [ "$rc" != 2 ] || [ ! -e "$prompt" ]; then
		echo "FAIL ($1): the gate exited $rc (want 2) and built no prompt"
		sed 's/^/  /' "$tmp/err"
		fail=1
		return
	fi
	(
		cd "$repo" || exit 1
		dir=$root/hooks
		. "$root/hooks/review-lib.sh"
		rules=$(printf '\n- P0: x')
		checklist_src='CONTRIBUTING.md on refs/remotes/origin/master'
		pitfalls_src='docs/pitfalls.md on refs/remotes/origin/master'
		pr=7
		main=master
		upstream=refs/remotes/origin/master
		range=$upstream...HEAD
		branch_stat=
		if [ -n "$scoped" ]; then
			range=$base..HEAD
			branch_stat=$(git diff --stat "$upstream"...HEAD)
		fi
		filed=$tmp/filed
		printf '%s' "$filed_text" >"$filed"
		commits=$(git log --format='%h %s' "$upstream"..HEAD)
		diff_text=$(git diff "$range")
		build_prompt "$tmp/lib-prompt.md"
	)
	cmp -s "$prompt" "$tmp/lib-prompt.md" || {
		echo "FAIL ($1): the gate's prompt differs from build_prompt's:"
		diff "$prompt" "$tmp/lib-prompt.md" | sed 's/^/  /' | head -20
		fail=1
	}
}

# A code change: the finder's prompt with the checklist and the pitfalls, no scope section.
fixture
echo 'echo 1' >"$repo/x.sh"
git -C "$repo" add -A
g commit -q -m "add x"
gate
kind=code checklist='## Reviews

- check a' pitfalls='# Pitfalls

- p1' threads='' scoped='' base='' filed_text=''
same code
grep -qF 'Known pitfalls from past reviews' "$prompt" || {
	echo "FAIL (code): the gate's prompt has no pitfalls section"
	fail=1
}

# A docs change: the claims check's prompt, with neither the checklist nor the pitfalls.
fixture
echo 'hello' >"$repo/README.md"
git -C "$repo" add -A
g commit -q -m docs
gate
kind=docs checklist='' pitfalls='' threads='' scoped='' base='' filed_text=''
same docs
if grep -qF 'Known pitfalls' "$prompt"; then
	echo "FAIL (docs): the docs prompt has the pitfalls"
	fail=1
fi

# A follow-up review of a branch whose first commit passed, with a filed P3 and an unresolved thread.
fixture
echo 'echo 1' >"$repo/x.sh"
git -C "$repo" add -A
g commit -q -m "add x"
first=$(git -C "$repo" rev-parse HEAD)
mkdir -p "$repo/.git/review-gate"
: >"$repo/.git/review-gate/$first.pass"
printf 'k1\tfiled thing (u)\n' >"$repo/.git/review-gate/p3-filed.tsv"
echo 'echo 2' >>"$repo/x.sh"
git -C "$repo" add -A
g commit -q -m "more x"
THREADS=1 gate
kind=code checklist='## Reviews

- check a' pitfalls='# Pitfalls

- p1' threads='### x.sh:1
Codex says: fix the quoting' scoped=1 base=$first filed_text='k1	filed thing (u)
'
same scoped
for text in 'follow-up review' 'filed thing (u)' 'Unresolved review threads on PR #7' 'Branch files (git diff --stat origin/master...HEAD)'; do
	grep -qF "$text" "$prompt" || {
		echo "FAIL (scoped): the gate's prompt lacks '$text'"
		fail=1
	}
done

# The rules lifted out of the gate.
(
	# shellcheck disable=SC1091
	. "$root/hooks/review-lib.sh"
	check() {
		if [ "$2" != "$3" ]; then
			echo "FAIL ($1): got '$2', want '$3'"
			exit 1
		fi
	}
	check kind-empty "$(kind_of '')" code
	check kind-readme "$(kind_of 'README.md')" docs
	check kind-docs-dir "$(kind_of 'docs/img.png')" docs
	check kind-mixed "$(kind_of 'README.md
x.sh')" code
	check kind-prompt "$(kind_of 'hooks/review-prompt.md')" code
	check kind-skill "$(kind_of 'skills/ship/SKILL.md')" code
	check kind-nested-claude "$(kind_of 'docs/CLAUDE.md')" code
	check kind-agents "$(kind_of 'AGENTS.md')" code
	check checklist "$(checklist_of '# C

## Reviews

- a

## Other

- b')" '## Reviews

- a'
	verdicts='[{"index":0,"verdict":"rejected","evidence":"x.sh:2","reason":"r"},{"index":1,"verdict":"rejected","evidence":"no line cited","reason":"r"},{"index":2,"verdict":"confirmed","reason":"r"}]'
	findings='[{"severity":"P1"},{"severity":"P2"},{"severity":"P2"},{"severity":"P3"}]'
	marked=$(mark_rejected "$findings" "$verdicts")
	check rejected "$(printf '%s' "$marked" | jq -c '[.[].rejected]')" '[true,false,false,false]'
	check unverified "$(printf '%s' "$marked" | jq -r '.[3].verdict.verdict')" unverified
	check blocking "$(blocking_of "$marked")" 2
	check blocking-none "$(blocking_of '[]')" 0
	printf '{"structured_output":{"findings":[{"a":1}]}}' >"$tmp/o1"
	printf '{"result":"{\\"findings\\":[]}"}' >"$tmp/o2"
	printf 'not json' >"$tmp/o3"
	check findings-structured "$(findings_of "$tmp/o1")" '[{"a":1}]'
	check findings-result "$(findings_of "$tmp/o2")" '[]'
	check findings-garbage "$(findings_of "$tmp/o3")" ''
) || fail=1

# A gate that can't read its lib blocks the push (a shell that fails to source a file exits with a status that lets
# the call through).
fixture
echo 'echo 1' >"$repo/x.sh"
git -C "$repo" add -A
g commit -q -m "add x"
mkdir "$tmp/hooks-copy"
cp "$root"/hooks/* "$tmp/hooks-copy/"
rm "$tmp/hooks-copy/review-lib.sh"
jq -nc --arg d "$repo" '{tool_name: "Bash", tool_input: {command: "git push origin HEAD"}, cwd: $d}' |
	PATH=$tmp/rbin:$PATH sh "$tmp/hooks-copy/review-gate.sh" >/dev/null 2>"$tmp/err"
rc=$?
if [ "$rc" != 2 ] || ! grep -q 'review-lib.sh' "$tmp/err"; then
	echo "FAIL (no-lib): exit $rc (want 2) with a message naming review-lib.sh"
	sed 's/^/  /' "$tmp/err"
	fail=1
fi

# A gate whose prompt file is missing blocks too: build_prompt's status was its last echo's, so the reviewer would have
# run without its instructions.
cp "$root/hooks/review-lib.sh" "$tmp/hooks-copy/"
rm -f "$tmp/hooks-copy/review-prompt.md"
rm -rf "$repo/.git/review-gate"
jq -nc --arg d "$repo" '{tool_name: "Bash", tool_input: {command: "git push origin HEAD"}, cwd: $d}' |
	PATH=$tmp/rbin:$PATH sh "$tmp/hooks-copy/review-gate.sh" >/dev/null 2>"$tmp/err"
rc=$?
if [ "$rc" != 2 ] || ! grep -q "couldn't build the reviewer's prompt" "$tmp/err"; then
	echo "FAIL (no-prompt): exit $rc (want 2) with a message about the prompt"
	sed 's/^/  /' "$tmp/err"
	fail=1
fi

[ "$fail" = 0 ] && echo "gate-lib: ok"
exit "$fail"
