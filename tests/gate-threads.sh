#!/bin/sh
# Tests the gate's lookups for the reviewer's prompt (claude-ship #106): the branch's open PR and its unresolved
# Codex/collaborator threads. A lookup that fails blocks the push (it must not read as "no PR" or "no threads"), and
# so does a `git log` or `git diff` that fails while the prompt is built. "No PR" and "no unresolved threads" pass.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/lib/shfmt.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/rbin" "$tmp/home"
link_shfmt "$tmp/home"
export HOME="$tmp/home"
# PR_LIST: fail, empty, or a PR number. GQL: fail, empty, or thread (one thread line).
cat >"$tmp/rbin/gh" <<'EOT'
#!/bin/sh
if [ "$1 $2" = "repo view" ]; then
	echo master
	exit 0
fi
if [ "$1 $2" = "pr list" ]; then
	case ${PR_LIST:-empty} in
	fail)
		echo "gh: HTTP 502" >&2
		exit 1
		;;
	empty) exit 0 ;;
	*) echo "$PR_LIST" ;;
	esac
	exit 0
fi
if [ "$1 $2" = "api graphql" ]; then
	case ${GQL:-empty} in
	fail)
		echo "gh: HTTP 502" >&2
		exit 1
		;;
	empty) exit 0 ;;
	thread) printf '### x.sh:1\nCodex says: fix the quoting\n\n' ;;
	esac
	exit 0
fi
echo true
EOT
# FAIL_LOG makes `git log` fail; FAIL_DIFF makes `git diff <range>` fail (not the --name-only ones).
cat >"$tmp/rbin/git" <<EOT
#!/bin/sh
if [ "\$1 \$2 \$3" = "fetch -q origin" ]; then
	shift 3
	exec $(command -v git) fetch -q "$tmp/origin.git" "\$@"
fi
if [ -n "\${FAIL_LOG:-}" ] && [ "\$1" = log ]; then
	exit 1
fi
if [ -n "\${FAIL_DIFF:-}" ] && [ "\$1" = diff ]; then
	case \$2 in
	--*) ;;
	*) exit 1 ;;
	esac
fi
exec $(command -v git) "\$@"
EOT
# The fake reviewer logs each run and finds nothing, so a push that gets this far passes.
cat >"$tmp/rbin/claude" <<EOT
#!/bin/sh
echo run >>"$tmp/claude-runs"
printf '{"structured_output":{"findings":[]}}'
EOT
chmod +x "$tmp/rbin/gh" "$tmp/rbin/git" "$tmp/rbin/claude"
fail=0
n=0

g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }

# fixture: a repo on branch feat with a code change on top of the default branch (origin's master).
fixture() {
	n=$((n + 1))
	repo=$tmp/repo$n
	rm -rf "$tmp/origin.git" "$tmp/claude-runs"
	git init -q --bare -b master "$tmp/origin.git"
	git init -q -b feat "$repo"
	git -C "$repo" remote add origin https://github.com/acme/app.git
	printf '## Code Review Rules\n\n- P0: x\n' >"$repo/AGENTS.md"
	git -C "$repo" add AGENTS.md
	g commit -q -m rules
	git -C "$repo" push -qf "$tmp/origin.git" HEAD:refs/heads/master
	echo 'echo x' >"$repo/x.sh"
	git -C "$repo" add -A
	g commit -q -m change
}

# push <VAR=value>...: runs the gate on a push with those variables set for the fakes; sets rc and prompt, leaves
# stderr in $tmp/err.
push() {
	jq -nc --arg d "$repo" '{tool_name: "Bash", tool_input: {command: "git push origin HEAD"}, cwd: $d}' |
		env "$@" PATH="$tmp/rbin:$PATH" sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	prompt=$repo/.git/review-gate/$(git -C "$repo" rev-parse HEAD).prompt.md
}

# check <name> <want rc> <want reviewer runs so far>
check() {
	runs=0
	[ ! -e "$tmp/claude-runs" ] || runs=$(wc -l <"$tmp/claude-runs" | tr -d ' ')
	if [ "$rc" != "$2" ] || [ "$runs" != "$3" ]; then
		echo "FAIL ($1): exit $rc (want $2), $runs reviewer runs (want $3)"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}

errs() {
	grep -qF "$2" "$tmp/err" || {
		echo "FAIL ($1): stderr lacks '$2'"
		sed 's/^/  /' "$tmp/err"
		fail=1
	}
}

prompt_has() {
	grep -qF "$2" "$prompt" 2>/dev/null || {
		echo "FAIL ($1): the prompt lacks '$2'"
		fail=1
	}
}

prompt_lacks() {
	if grep -qF "$2" "$prompt" 2>/dev/null; then
		echo "FAIL ($1): the prompt has '$2'"
		fail=1
	fi
}

# No PR for the branch: reviewed, no threads section.
fixture
push PR_LIST=empty
check no-pr 0 1
prompt_lacks no-pr 'Unresolved review threads'

# The PR lookup fails: blocked before any reviewer runs, and no prompt is left behind.
fixture
push PR_LIST=fail
check pr-fails 2 0
errs pr-fails "couldn't read the open PR for feat"
[ ! -e "$prompt" ] || {
	echo "FAIL (pr-fails): a prompt was left behind"
	fail=1
}

# The next push, with GitHub working again, is reviewed normally: nothing stale from the blocked one.
push PR_LIST=empty
check pr-fails-then-ok 0 1

# A PR with an unresolved thread: the prompt quotes it.
fixture
push PR_LIST=7 GQL=thread
check threads 0 1
prompt_has threads '## Unresolved review threads on PR #7'
prompt_has threads 'Codex says: fix the quoting'

# A PR with no unresolved threads: reviewed, no section.
fixture
push PR_LIST=7 GQL=empty
check no-threads 0 1
prompt_lacks no-threads 'Unresolved review threads'

# The thread lookup fails: blocked; the next push, with GitHub back, quotes the thread.
fixture
push PR_LIST=7 GQL=fail
check threads-fail 2 0
errs threads-fail "couldn't read the unresolved review threads of PR #7"
push PR_LIST=7 GQL=thread
check threads-fail-then-ok 0 1
prompt_has threads-fail-then-ok 'Codex says: fix the quoting'

# A git log or git diff that fails while the prompt is built must not read as an empty section or an empty diff.
fixture
push FAIL_LOG=1
check log-fails 2 0
errs log-fails "couldn't list the commits"
fixture
push FAIL_DIFF=1
check diff-fails 2 0
errs diff-fails "couldn't read the diff"

[ "$fail" = 0 ] && echo "gate-threads: ok"
exit "$fail"
