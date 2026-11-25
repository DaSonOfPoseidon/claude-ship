#!/bin/sh
# Tests the gate's P3 handling. A confirmed P3 is kept pending for the branch (claude-ship #352), not filed: p3-pending.sh
# holds it until the PR is done. The dedupe is claude-ship #112's: a P3 is not kept again when the repo already has an open
# P3 issue with the same title (up to case and whitespace) or the same file:line in its first body line, or when the P3
# file has its key. The match is exact, and a failed read of the open issues falls back on the P3 file without changing
# the gate's exit code. On a detached HEAD there is no branch to keep one for, and the gate files it as before. The gate
# runs from a copy of hooks/ whose p3-issue.sh is a fake, so nothing is filed for real.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/lib/shfmt.sh"
. "$root/tests/lib/gitenv.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/rbin" "$tmp/home" "$tmp/hooks"
link_shfmt "$tmp/home"
gate_git_hooks "$tmp/home"
export HOME="$tmp/home"
export GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z"
cp "$root"/hooks/* "$tmp/hooks/"
# The fake filer logs the title it is given and prints a URL, as p3-issue.sh does.
cat >"$tmp/hooks/p3-issue.sh" <<EOT
#!/bin/sh
jq -r .title "\$2" >>"$tmp/filed-log"
echo https://github.com/acme/app/issues/99
EOT
# ISSUES: unset = no open issues, fail = the read fails, else the path of the JSON to serve.
cat >"$tmp/rbin/gh" <<'EOT'
#!/bin/sh
if [ "$1 $2" = "repo view" ]; then
	echo master
	exit 0
fi
if [ "$1 $2" = "pr list" ]; then
	exit 0
fi
if [ "$1 $2 $3" = "variable get CLAUDE_P3_LABELS" ]; then
	echo "HTTP 404: Not Found" >&2
	exit 1
fi
if [ "$1 $2" = "issue list" ]; then
	case ${ISSUES:-} in
	fail)
		echo "gh: HTTP 502" >&2
		exit 1
		;;
	'') echo '[]' ;;
	*) cat "$ISSUES" ;;
	esac
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
# The finder reports the findings in $FINDINGS (a JSON array), the verifier confirms them all by rejecting none.
cat >"$tmp/rbin/claude" <<'EOT'
#!/bin/sh
case " $* " in
*" sonnet "*) printf '{"structured_output":{"findings":%s}}' "$(cat "$FINDINGS")" ;;
*) printf '{"structured_output":{"verdicts":[]}}' ;;
esac
EOT
chmod +x "$tmp/rbin/gh" "$tmp/rbin/git" "$tmp/rbin/claude" "$tmp/hooks/p3-issue.sh"
fail=0
n=0

g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }

# fixture: a repo on branch feat with a code change on top of the default branch (origin's master).
fixture() {
	n=$((n + 1))
	repo=$tmp/repo$n
	rm -rf "$tmp/origin.git" "$tmp/filed-log"
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
	mkdir -p "$repo/.git/review-gate"
	state=$repo/.git/review-gate
}

# push <VAR=value>...: runs the gate on a push with those variables set for the fakes; leaves stderr in $tmp/err.
push() {
	jq -nc --arg d "$repo" '{tool_name: "Bash", tool_input: {command: "git push origin HEAD"}, cwd: $d}' |
		env "$@" PATH="$tmp/rbin:$PATH" sh "$tmp/hooks/review-gate.sh" >/dev/null 2>"$tmp/err"
	rc=$?
}

# p3 <file> <line> <summary>: a P3 finding.
p3() {
	jq -nc --arg f "$1" --argjson l "$2" --arg s "$3" '{file: $f, line: $l, severity: "P3", summary: $s, failure_scenario: "f"}'
}

key_of() { printf '%s' "$1" | cksum | cut -d' ' -f1; }

filed_log() { cat "$tmp/filed-log" 2>/dev/null; }

expect_filed() {
	if ! filed_log | grep -qxF "$2"; then
		echo "FAIL ($1): '$2' wasn't filed; filed: $(filed_log | tr '\n' '|')"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}

expect_not_filed() {
	if filed_log | grep -qxF "$2"; then
		echo "FAIL ($1): '$2' was filed"
		fail=1
	fi
}

# pending: the titles kept pending for the branch feat of the current fixture, one per line.
pending() { (cd "$repo" && sh "$tmp/hooks/p3-pending.sh" titles feat); }

expect_pending() {
	if ! pending | grep -qxF "$2"; then
		echo "FAIL ($1): '$2' isn't pending; pending: $(pending | tr '\n' '|')"
		sed 's/^/  /' "$tmp/err"
		fail=1
	fi
}

expect_not_pending() {
	if pending | grep -qxF "$2"; then
		echo "FAIL ($1): '$2' is pending"
		fail=1
	fi
}

# Nothing is filed by the gate while a branch is checked out.
expect_nothing_filed() {
	if [ -n "$(filed_log)" ]; then
		echo "FAIL ($1): the gate filed: $(filed_log | tr '\n' '|')"
		fail=1
	fi
}

errs() {
	grep -qF -- "$2" "$tmp/err" || {
		echo "FAIL ($1): stderr lacks '$2'"
		sed 's/^/  /' "$tmp/err"
		fail=1
	}
}

# The open issues: one whose title is a P3's up to case and whitespace, one that cites a site, one whose title only
# starts like a P3's.
cat >"$tmp/open.json" <<'EOT'
[
 {"number":1,"title":"X.SH:   Quoting  bug ","body":"Found by the pre-push review gate (P3, verified) at `x.sh:5` in abc.\n\nsummary","url":"https://github.com/acme/app/issues/1"},
 {"number":2,"title":"y.sh: some other words","body":"Found by the pre-push review gate (P3, verified) at `y.sh:10` in abc.\n\nsummary","url":"https://github.com/acme/app/issues/2"},
 {"number":3,"title":"w.sh: prefix and more","body":"Found by the pre-push review gate (P3, verified) at `w.sh:99` in abc.\n\nBody mentions at `v.sh:1` in the second line","url":"https://github.com/acme/app/issues/3"},
 {"number":4,"title":null,"body":null,"url":"https://github.com/acme/app/issues/4"},
 {"number":5,"title":"later line","body":"first line\nFound by the pre-push review gate (P3, verified) at `u.sh:4` in abc.","url":"https://github.com/acme/app/issues/5"}
]
EOT

# Matching open issues skip the P3 and cache its key; anything that only looks alike is kept pending. Nothing is filed.
fixture
{
	p3 x.sh 5 'quoting BUG'
	p3 y.sh 10 'a different summary'
	p3 z.sh 3 'novel thing'
	p3 w.sh 1 'prefix'
	p3 y.sh 11 'same file, another line'
	p3 v.sh 1 'cited only in a later body line'
	p3 u.sh 4 'cited only on a later line of the body'
} | jq -s . >"$tmp/findings.json"
push FINDINGS="$tmp/findings.json" ISSUES="$tmp/open.json"
[ "$rc" = 0 ] || {
	echo "FAIL (open): exit $rc (want 0)"
	sed 's/^/  /' "$tmp/err"
	fail=1
}
expect_nothing_filed open
expect_not_pending title-case-whitespace 'x.sh: quoting BUG'
expect_not_pending same-site 'y.sh: a different summary'
expect_pending novel 'z.sh: novel thing'
expect_pending title-prefix 'w.sh: prefix'
expect_pending same-file-other-line 'y.sh: same file, another line'
expect_pending site-in-later-body-line 'v.sh: cited only in a later body line'
expect_pending site-on-later-line 'u.sh: cited only on a later line of the body'
errs skip-title 'review-gate: skipped P3 "x.sh: quoting BUG": already filed as https://github.com/acme/app/issues/1'
errs skip-site 'review-gate: skipped P3 "y.sh: a different summary": already filed as https://github.com/acme/app/issues/2'
errs kept-novel 'review-gate: P3 kept pending for feat: z.sh: novel thing'
# The skipped ones are in the P3 file with the open issue's URL; the pending ones are not in it (nothing is filed).
grep -qF "$(key_of 'x.sh: quoting BUG')	x.sh: quoting BUG (https://github.com/acme/app/issues/1)" "$state/p3-filed.tsv" || {
	echo "FAIL (open): the P3 file lacks the skipped title match"
	fail=1
}
grep -qF "$(key_of 'y.sh: a different summary')	y.sh: a different summary (https://github.com/acme/app/issues/2)" "$state/p3-filed.tsv" || {
	echo "FAIL (open): the P3 file lacks the skipped site match"
	fail=1
}
if grep -qF "$(key_of 'z.sh: novel thing')" "$state/p3-filed.tsv"; then
	echo "FAIL (open): the P3 file has a P3 that is only pending"
	fail=1
fi
# The pending entry has what filing needs: the reviewed commit, the site and the issue's body.
entry=$(jq -c 'select(.title == "z.sh: novel thing")' "$state/p3-pending/feat.jsonl")
[ "$(printf '%s' "$entry" | jq -r .head)" = "$(git -C "$repo" rev-parse HEAD)" ] || {
	echo "FAIL (open): the pending entry's head isn't the reviewed commit: $entry"
	fail=1
}
printf '%s' "$entry" | jq -e '.file == "z.sh" and .line == 3 and (.body | startswith("Found by the pre-push review gate (P3, verified) at `z.sh:3` in "))' >/dev/null || {
	echo "FAIL (open): the pending entry lacks its site or body: $entry"
	fail=1
}

# The same P3 found on a later push is pending once.
fixture
p3 z.sh 3 'novel thing' | jq -s . >"$tmp/findings.json"
push FINDINGS="$tmp/findings.json"
rm -f "$state"/*.pass "$state"/*.json
push FINDINGS="$tmp/findings.json"
[ "$(pending | grep -cxF 'z.sh: novel thing')" = 1 ] || {
	echo "FAIL (twice): 'z.sh: novel thing' isn't pending exactly once: $(pending | tr '\n' '|')"
	fail=1
}

# A P3 whose key is in the P3 file is not kept, with a good read and with a failed one (today's rule still holds).
for issues in "" fail; do
	fixture
	p3 t.sh 1 seen | jq -s . >"$tmp/findings.json"
	printf '%s\t%s\n' "$(key_of 't.sh: seen')" 't.sh: seen (u)' >"$state/p3-filed.tsv"
	push FINDINGS="$tmp/findings.json" ISSUES="$issues"
	[ "$rc" = 0 ] || {
		echo "FAIL (tsv ${issues:-ok}): exit $rc (want 0)"
		sed 's/^/  /' "$tmp/err"
		fail=1
	}
	expect_not_filed "tsv ${issues:-ok}" 't.sh: seen'
	expect_not_pending "tsv ${issues:-ok}" 't.sh: seen'
done

# A failed read warns and changes nothing else: the P3 is kept pending and the exit code is the one a good read gives.
fixture
{
	p3 x.sh 5 'quoting BUG'
} | jq -s . >"$tmp/findings.json"
push FINDINGS="$tmp/findings.json" ISSUES=fail
[ "$rc" = 0 ] || {
	echo "FAIL (failed read): exit $rc (want 0)"
	sed 's/^/  /' "$tmp/err"
	fail=1
}
errs failed-read "review-gate: couldn't read the open P3 issues, so the dedupe uses only $state/p3-filed.tsv."
expect_pending failed-read 'x.sh: quoting BUG'
expect_nothing_filed failed-read

# A blocking finding still blocks, whatever the read did. The message lists the P2 and the branch's pending P3, with
# the rule for them, and the P3 is kept (not filed).
fixture
{
	p3 x.sh 5 'quoting BUG'
	jq -nc '{file: "b.sh", line: 1, severity: "P2", summary: "s", failure_scenario: "f"}'
} | jq -s . >"$tmp/findings.json"
push FINDINGS="$tmp/findings.json" ISSUES=fail
[ "$rc" = 2 ] || {
	echo "FAIL (blocking): exit $rc (want 2)"
	fail=1
}
errs blocking-p2 '- [P2] b.sh:1 s'
errs blocking-pending-rule 'Pending P3s: fix the ones that are relevant and easy in this commit too. The rest are filed when the PR is done.'
errs blocking-pending-p3 'x.sh:5 quoting BUG'
errs blocking-pending-failure '    Failure: f'
expect_pending blocking 'x.sh: quoting BUG'
expect_nothing_filed blocking

# A block with no pending P3 has no "Pending P3s" line.
fixture
jq -nc '{file: "b.sh", line: 1, severity: "P2", summary: "s", failure_scenario: "f"}' | jq -s . >"$tmp/findings.json"
push FINDINGS="$tmp/findings.json"
[ "$rc" = 2 ] || {
	echo "FAIL (blocking, no P3): exit $rc (want 2)"
	fail=1
}
if grep -qF 'Pending P3s' "$tmp/err"; then
	echo "FAIL (blocking, no P3): the message has a pending P3 line"
	fail=1
fi

# A detached HEAD has no branch to keep a P3 for: it is filed now, as before, and nothing is pending.
fixture
git -C "$repo" checkout -q --detach
p3 z.sh 3 'novel thing' | jq -s . >"$tmp/findings.json"
push FINDINGS="$tmp/findings.json"
[ "$rc" = 0 ] || {
	echo "FAIL (detached): exit $rc (want 0)"
	sed 's/^/  /' "$tmp/err"
	fail=1
}
expect_filed detached 'z.sh: novel thing'
errs detached-filed 'review-gate: filed P3 https://github.com/acme/app/issues/99'
if [ -e "$state/p3-pending" ]; then
	echo "FAIL (detached): the gate wrote pending state"
	fail=1
fi

[ "$fail" = 0 ] && echo "gate-p3: ok"
exit "$fail"
