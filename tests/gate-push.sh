#!/bin/sh
# Tests the review gate's checks on what a push sends and where: origin's URLs must all name the pushed repo
# (claude-ship #11, #13), and a pushing command may contain only the push (#14, #25).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/lib/shfmt.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
link_shfmt "$tmp/home"
printf '#!/bin/sh\necho true\n' >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
export HOME="$tmp/home"
fail=0
n=0

# fixture <origin URL> [nopass]: a new repo on branch feat with one commit, whose review already passed unless nopass.
fixture() {
	n=$((n + 1))
	repo=$tmp/repo$n
	git init -q -b feat "$repo"
	git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
	git -C "$repo" remote add origin "$1"
	mkdir -p "$repo/.git/review-gate"
	[ "${2:-}" = nopass ] || : >"$repo/.git/review-gate/$(git -C "$repo" rev-parse HEAD).pass"
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
expect 0 'git push origin HEAD >&2'
expect 0 'git push origin HEAD >&-'
expect 0 'git push origin HEAD 2>&1 | tail -3 2>&1'
expect 0 'git push origin HEAD 2>&1 | grep -v hint | head -5'
expect 0 'git -C . push origin HEAD | cat'
expect 0 "cd $repo && git push -u origin HEAD 2>&1 | tail -3"
# Quoted text that mentions a push is not a push.
expect 0 'gh pr create --title t --body "see git push"'
expect 2 'echo "git push" && echo done'
expect 0 'gh pr create --body "costs $5, see git push"'
expect 2 'gh pr create --body "see git push" && git config push.followTags true'
expect 2 'gh pr create --body "$(git config push.followTags true; git push origin HEAD)"'
# A gh comment/close body that mentions a push, however often or in whatever form, is data (#56).
expect 0 'gh issue comment 36 --body "a && git push origin HEAD and b && git push origin HEAD"'
expect 0 'gh issue comment 36 --body "./echo && git push origin HEAD and /tmp/ls && git push origin HEAD both exit 2"'
expect 0 'gh issue comment 36 --body '\''exits 2: `git push origin HEAD` exits 2'\'''
expect 0 'gh issue comment 36 --body "git push -c x upstream main"'
expect 0 'gh pr comment 7 --body "git push --force other main"'
expect 0 'gh issue close 36 --comment "fixed; git push origin HEAD was read twice: git push origin HEAD"'
expect 0 'gh pr close 7 -c "git push origin HEAD"'
# Outside that single command the push is real, or the gate can't tell, so it still blocks.
expect 2 'gh issue comment 1 --body "x" && git push origin main'
expect 2 'gh issue comment 1 --body "x" && git push origin HEAD'
expect 2 'gh issue comment 1 --body "$(git push)"'
expect 2 'gh issue comment 1 --body "`git push origin HEAD`"'
expect 2 'gh issue comment 1 --body "a git push origin HEAD b git push origin HEAD" ; git push origin main'
expect 2 'gh issue comment 1 --body x
git push origin main'
expect 2 'gh issue close 1 --comment "x" && git push origin main'
expect 2 'FOO=1 gh issue comment 1 --body "git push" && git push origin main'
expect 2 'gh -R o/r issue comment 1 --body "git push" && git push origin main'
expect 2 'gh issue comment 1 --body "git push" & git push origin main'
expect 2 'gh issue comment 1 --body "git push" | git push origin main'
expect 2 'gh issue comment 1 --body "git push" > out && git push origin main'
expect 2 'gh issue comment 1 --body-file <(git push origin main) --body "git push"'
expect 2 'gh pr merge 1 --body "git push origin HEAD and git push origin HEAD"'
# A quoted push still runs under `sh -c` and `eval`.
expect 2 'sh -c "git config push.followTags true; git push origin HEAD"'
expect 2 "bash -c 'git status && git push origin HEAD'"
expect 2 'eval "git status; git push origin HEAD"'

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
expect 2 'git push origin HEAD >&2.txt'
expect 2 'git push origin HEAD >&1/x'
expect 2 'git push origin HEAD 2>&1.log'
expect 2 'git push origin HEAD >&2-x'
expect 2 'git push origin HEAD &>/dev/null.log'
expect 2 'git push origin HEAD >/dev/null,x'
expect 2 'git push origin HEAD 2>/dev/stderr:x'
expect 2 'git push origin HEAD &>/dev/stdout+x'
expect 2 'git push origin HEAD >&2,x'
expect 2 "git push origin HEAD >&2'.txt'"
expect 2 "git push origin HEAD >/dev/null'x'"
expect 2 "git push origin HEAD &>/dev/null'x'"
expect 2 'git push origin HEAD 2>&1; tail -1 x'
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

# A data-only gh command pushes nothing, so it never starts a review, even when HEAD has no pass (#91). A fake
# `claude` records that a review started and fails, so a started review exits 2. origin's URL must stay GitHub's
# for the gate's repo checks, so the fake git fetches from a local bare repo, and the fake gh names the default branch.
mkdir -p "$tmp/rbin"
cat >"$tmp/rbin/gh" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "repo view" ]; then
	echo master
	exit 0
fi
echo true
EOF
cat >"$tmp/rbin/git" <<EOF
#!/bin/sh
if [ "\$1 \$2 \$3" = "fetch -q origin" ]; then
	shift 3
	exec $(command -v git) fetch -q "$tmp/origin.git" "\$@"
fi
exec $(command -v git) "\$@"
EOF
printf '#!/bin/sh\ntouch "%s/reviewed"\nexit 1\n' "$tmp" >"$tmp/rbin/claude"
chmod +x "$tmp/rbin/gh" "$tmp/rbin/git" "$tmp/rbin/claude"
git init -q --bare -b master "$tmp/origin.git"

# fixture_unreviewed: a branch one commit ahead of origin's master, with review rules and no pass for HEAD.
fixture_unreviewed() {
	fixture https://github.com/acme/app.git nopass
	git -C "$repo" push -qf "$tmp/origin.git" HEAD:refs/heads/master
	printf '## Code Review Rules\n\n- P0: x\n' >"$repo/AGENTS.md"
	git -C "$repo" add AGENTS.md
	git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m rules
}

# expect_review <exit code> <command> <started|none>: runs the gate with the fake claude, then checks whether
# a review started.
expect_review() {
	rm -f "$tmp/reviewed"
	jq -nc --arg c "$2" --arg d "$repo" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
		PATH=$tmp/rbin:$PATH sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	if [ -e "$tmp/reviewed" ]; then got=started; else got=none; fi
	if [ "$rc" != "$1" ] || [ "$got" != "$3" ]; then
		echo "FAIL (exit $rc, want $1; review $got, want $3): $2"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}

fixture_unreviewed
expect_review 0 'gh pr comment 7 --body "git push --force other main"' none
expect_review 0 'gh issue create --title t --body "then git push"' none
expect_review 0 'gh issue close 36 --comment "fixed; git push origin HEAD"' none
# `gh pr create` is gated like a push (the PR would cover an unreviewed HEAD), so it still gets its review.
expect_review 2 'gh pr create --title t --body "x"' started
expect_review 2 'gh pr create --title t --body "see git push"' started
# A real push still gets its review, and a command that is not data-only is still blocked (before any review).
expect_review 2 'git push origin HEAD' started
expect_review 2 'gh pr comment 7 --body "x" && git push origin HEAD' none

# The reviewers share one time budget (claude-ship #103): REVIEW_GATE_BUDGET seconds from the gate's start, each
# run capped at 1100 s and at what is left, and no run starts with fewer than REVIEW_GATE_MIN_SECS left. A fake
# `timeout` logs the limit it was given, a fake `date` (FAKE_DATE_STEP) moves the clock a fixed step per call, and
# the fake claude in fbin returns one finding for the finder and fails the verifier.
cat >"$tmp/rbin/timeout" <<EOT
#!/bin/sh
echo "\$1" >>"$tmp/timeouts"
shift
exec "\$@"
EOT
mkdir -p "$tmp/fbin"
cat >"$tmp/fbin/date" <<EOT
#!/bin/sh
[ -n "\${FAKE_DATE_STEP:-}" ] || exec $(command -v date) "\$@"
n=\$(cat "$tmp/clock" 2>/dev/null || echo 0)
echo "\$n"
echo \$((n + FAKE_DATE_STEP)) >"$tmp/clock"
EOT
cat >"$tmp/fbin/claude" <<EOT
#!/bin/sh
touch "$tmp/reviewed"
case " \$* " in
*" sonnet "*) printf '{"structured_output":{"findings":[{"file":"a","line":1,"severity":"P2","summary":"s","failure_scenario":"f"}]}}' ;;
*) exit 1 ;;
esac
EOT
chmod +x "$tmp/rbin/timeout" "$tmp/fbin/date" "$tmp/fbin/claude"

# expect_budget <env assignments, or -> <exit code> <review started|none> <timeouts, space-separated, or none>
# <text in stderr>: runs a real push in a fresh unreviewed fixture with the fake claude, date and timeout.
expect_budget() {
	fixture_unreviewed
	# A change to a non-doc file, so it gets the finder and the verifier, not the docs check.
	echo 'echo x' >"$repo/x.sh"
	git -C "$repo" add x.sh
	git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m code
	rm -f "$tmp/reviewed" "$tmp/timeouts" "$tmp/clock"
	[ "$1" != - ] || set -- "FOO=1" "$2" "$3" "$4" "$5"
	jq -nc --arg c 'git push origin HEAD' --arg d "$repo" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' |
		env "$1" PATH="$tmp/fbin:$tmp/rbin:$PATH" sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
	if [ -e "$tmp/reviewed" ]; then got=started; else got=none; fi
	limits=$(cat "$tmp/timeouts" 2>/dev/null | tr '\n' ' ')
	limits=${limits% }
	if [ "$rc" != "$2" ] || [ "$got" != "$3" ] || [ "${limits:-none}" != "$4" ] || ! grep -q "$5" "$tmp/err"; then
		echo "FAIL ($1): exit $rc (want $2), review $got (want $3), timeouts '${limits:-none}' (want '$4'), stderr wants '$5'"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}
# Within budget, each reviewer gets the full 1100 s (the fake verifier exits 1, so the review fails, not times out).
expect_budget - 2 started '1100 1100' 'verifier reviewer failed'
# The budget is spent before the first reviewer: it never starts.
expect_budget REVIEW_GATE_BUDGET=100 2 none none 'ran out of time'
expect_budget REVIEW_GATE_BUDGET=119 2 none none 'ran out of time'
# Time passed in the finder is gone from the verifier's allowance, and a verifier with nothing left never starts.
expect_budget FAKE_DATE_STEP=1100 2 started 1100 'ran out of time'
expect_budget FAKE_DATE_STEP=1000 2 started '1100 200' 'verifier reviewer failed'
expect_budget REVIEW_GATE_MIN_SECS=3000 2 none none 'ran out of time'
# A budget that isn't a number blocks rather than reading as zero or as no limit.
expect_budget REVIEW_GATE_BUDGET=abc 2 none none 'REVIEW_GATE_BUDGET'
expect_budget REVIEW_GATE_BUDGET=0100 2 none none 'REVIEW_GATE_BUDGET'

# A gate that can't read the tool call blocks it instead of reading it as nothing (claude-ship #103): with no jq at
# all (nojq holds only what the script runs before it looks for jq), with a jq that fails, and with input jq rejects.
mkdir -p "$tmp/nojq" "$tmp/jbin"
for t in cat dirname date; do
	ln -s "$(command -v "$t")" "$tmp/nojq/$t"
done
printf '#!/bin/sh\nexit 127\n' >"$tmp/jbin/jq"
chmod +x "$tmp/jbin/jq"

# expect_input <exit code> <stderr text> <bin dir, or - for the usual PATH> <input JSON>
expect_input() {
	if [ "$3" = - ]; then
		printf '%s' "$4" | PATH=$tmp/rbin:$PATH /bin/sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	else
		printf '%s' "$4" | PATH=$3 /bin/sh "$root/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	fi
	rc=$?
	if [ "$rc" != "$1" ] || { [ -n "$2" ] && ! grep -q "$2" "$tmp/err"; }; then
		echo "FAIL (exit $rc, want $1; stderr wants '$2', bin $3): $4"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}
bash_call=$(jq -nc --arg d "$repo" '{tool_name: "Bash", tool_input: {command: "ls"}, cwd: $d}')
write_call=$(jq -nc '{tool_name: "Write", tool_input: {file_path: "/tmp/x", content: "x"}}')
mcp_call=$(jq -nc '{tool_name: "mcp__x__y", tool_input: {}}')
for call in "$bash_call" "$write_call" "$mcp_call"; do
	expect_input 2 'needs jq' "$tmp/nojq" "$call"
	expect_input 2 "couldn't read" "$tmp/jbin:$tmp/rbin:$PATH" "$call"
done
expect_input 2 "couldn't read" - 'not json'
expect_input 2 "couldn't read" - ''
expect_input 2 "couldn't read" - '{}'
# Valid JSON that jq reads but not as a tool call of that shape is as unreadable.
expect_input 2 "couldn't read" - '{"tool_name":"Bash","tool_input":"git push origin HEAD"}'
expect_input 2 "couldn't read" - '{"tool_name":"Write","tool_input":{"file_path":"/p/.claude/settings.json","edits":5}}'
expect_input 2 "couldn't read" - '{"tool_name":"mcp__x__push_files","tool_input":"x"}'
# A tool the gate doesn't look at still passes, and so does a Bash call that isn't a push.
expect_input 0 '' - '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
expect_input 0 '' - "$bash_call"
# Nothing is pushed, so a dirty tree is no reason to block a data-only command, but it still blocks a push.
: >"$repo/dirty"
expect_review 0 'gh pr comment 7 --body "git push origin HEAD"' none
expect_review 2 'git push origin HEAD' none

[ "$fail" = 0 ] && echo "gate-push: ok"
exit "$fail"
