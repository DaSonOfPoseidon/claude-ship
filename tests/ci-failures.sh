#!/bin/sh
# Tests ci-failures.sh: the failed checks of a PR with the tail of each failed Actions job's log, so the main
# session never reads CI logs (claude-ship #118). The fake gh serves a checks fixture and a job log, and records
# every call so the tests can assert what was (not) fetched.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >>"$tmp/calls"
case "\$*" in
'pr checks 1 -R o/r --json name,state,bucket,link,workflow')
	if [ -f "$tmp/checks.err" ]; then
		cat "$tmp/checks.err" >&2
		exit 1
	fi
	# the n-th call serves checks.<n>.json when there is one (a run that settles over time), else checks.json
	n=\$(( \$(cat "$tmp/n" 2>/dev/null || echo 0) + 1 ))
	echo \$n >"$tmp/n"
	f="$tmp/checks.\$n.json"
	[ -f "\$f" ] || f="$tmp/checks.json"
	cat "\$f"
	# gh exits non-zero when a check failed (1) or is pending (8): that is not an error
	grep -q '"bucket": *"fail"' "\$f" && exit 1
	grep -q '"bucket": *"pending"' "\$f" && exit 8
	exit 0
	;;
'run view 100 -R o/r --job 200 --log-failed')
	[ -f "$tmp/log.err" ] && { cat "$tmp/log.err" >&2; exit 1; }
	cat "$tmp/log.txt"
	;;
'repo view --json nameWithOwner --jq .nameWithOwner') echo o/r ;;
*) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
fail=0
esc=$(printf '\033')
tab=$(printf '\t')

# run <args>...: runs the script with the fake gh; sets out (stdout) and rc.
run() {
	: >"$tmp/calls"
	rm -f "$tmp/n"
	out=$(CI_WAIT_INTERVAL=0 CI_WAIT_POLLS=3 PATH=$tmp/bin:$PATH sh "$root/skills/ship/ci-failures.sh" "$@" 2>"$tmp/stderr")
	rc=$?
}

# want <label> <expected rc> <expected stdout>
want() {
	if [ "$rc" != "$2" ]; then
		echo "FAIL (exit $rc, want $2): $1"
		sed 's/^/  /' "$tmp/stderr"
		fail=1
	elif [ "$out" != "$3" ]; then
		echo "FAIL (output): $1"
		printf '%s\n' "$out" | sed 's/^/  got:  /'
		printf '%s\n' "$3" | sed 's/^/  want: /'
		fail=1
	fi
}

# called <label> <string>: the fake gh was called with this exact line.
called() {
	grep -qxF "$2" "$tmp/calls" || { echo "FAIL (no call '$2'): $1"; fail=1; }
}
notcalled() {
	if grep -qF "$2" "$tmp/calls"; then
		echo "FAIL (called '$2'): $1"
		fail=1
	fi
}

# A job log as gh prints it: job, step, then a timestamped line, tab separated, with ANSI colours.
i=1
: >"$tmp/log.txt"
while [ "$i" -le 100 ]; do
	printf 'test%sRun tests%s2026-10-30T10:00:%02d.1234567Z line %s\n' "$tab" "$tab" "$((i % 60))" "$i" >>"$tmp/log.txt"
	i=$((i + 1))
done
printf 'test%sRun tests%s2026-10-30T10:01:00.1234567Z %s[31mFAILED%s[0m tests/x.sh\r\n' "$tab" "$tab" "$esc" "$esc" >>"$tmp/log.txt"

failjob='{"name":"unit","state":"FAILURE","bucket":"fail","link":"https://github.com/o/r/actions/runs/100/job/200","workflow":"CI"}'
failext='{"name":"deploy/preview","state":"FAILURE","bucket":"fail","link":"https://ci.example.com/build/7","workflow":""}'
pass='{"name":"lint","state":"SUCCESS","bucket":"pass","link":"https://github.com/o/r/actions/runs/100/job/201","workflow":"CI"}'
pend='{"name":"slow","state":"IN_PROGRESS","bucket":"pending","link":"https://github.com/o/r/actions/runs/101/job/300","workflow":"CI"}'

# One failed Actions job: its header, then the last 60 lines of its log, indented, cleaned.
printf '[%s,%s]\n' "$failjob" "$pass" >"$tmp/checks.json"
run 1 o/r
last=$(printf '  line %s\n' 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 85 86 87 88 89 90 91 92 93 94 95 96 97 98 99 100)
want 'failed job, 60 lines, cleaned' 0 "CI / unit  https://github.com/o/r/actions/runs/100/job/200
$last
  FAILED tests/x.sh"
called 'failed job' 'run view 100 -R o/r --job 200 --log-failed'
printf '%s' "$out" | grep -q "$esc" && { echo "FAIL: an escape character reached the output"; fail=1; }
printf '%s' "$out" | grep -q 'T10:' && { echo "FAIL: a timestamp reached the output"; fail=1; }
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 61 ] || { echo "FAIL: want the header and 60 log lines"; fail=1; }

# A failed external status: name and link, and no log fetch. Pending checks are counted.
printf '[%s,%s]\n' "$failext" "$pend" >"$tmp/checks.json"
run 1 o/r
want 'external status and a pending check' 0 'deploy/preview  https://ci.example.com/build/7
pending: 1 checks still running'
notcalled 'external status' 'run view'

# Links that look like jobs but whose ids are not numeric are external: never passed to gh run view.
for link in 'https://github.com/o/r/actions/runs/1;id/job/2' 'https://github.com/o/r/actions/runs/100/job/$(id)' \
	'https://github.com/o/r/actions/runs/100/job/' 'https://github.com/o/r/actions/runs/-1/job/2' \
	'https://github.com/o/r/actions/runs/100' 'https://github.com/o/r/actions/runs//job/200'; do
	printf '[{"name":"x","bucket":"fail","state":"FAILURE","workflow":"CI","link":"%s"}]\n' "$link" >"$tmp/checks.json"
	run 1 o/r
	want "non-numeric ids: $link" 0 "CI / x  $link"
	notcalled "non-numeric ids: $link" 'run view'
done

# Query strings and fragments after the job id still parse.
printf '[{"name":"unit","bucket":"fail","state":"FAILURE","workflow":"CI","link":"https://github.com/o/r/actions/runs/100/job/200?pr=1"}]\n' >"$tmp/checks.json"
run 1 o/r
called 'job link with a query' 'run view 100 -R o/r --job 200 --log-failed'

# A name with control characters can't inject lines into the output.
printf '[{"name":"a\\nb\\u001b[31m","bucket":"fail","state":"FAILURE","workflow":"","link":"https://ci.example.com/x"}]\n' >"$tmp/checks.json"
run 1 o/r
want 'control characters in a name' 0 'a b [31m  https://ci.example.com/x'

# Nothing failed.
printf '[%s]\n' "$pass" >"$tmp/checks.json"
run 1 o/r
want 'all pass' 0 'no failed checks'
printf '[%s,%s]\n' "$pass" "$pend" >"$tmp/checks.json"
run 1 o/r
want 'pending, none failed' 0 'no failed checks
pending: 1 checks still running'
printf '[]\n' >"$tmp/checks.json"
run 1 o/r
want 'empty list' 0 'no failed checks'
# A failed and a pending check: both reported.
printf '[%s,%s]\n' "$failext" "$pend" >"$tmp/checks.json"
run 1 o/r
want 'failed and pending' 0 'deploy/preview  https://ci.example.com/build/7
pending: 1 checks still running'

# gh prints no JSON when the PR has no checks.
rm -f "$tmp/checks.json"
printf "no checks reported on the 'x' branch\n" >"$tmp/checks.err"
run 1 o/r
want 'no checks reported' 0 'no failed checks'
# Any other gh failure is exit 1 with gh's message on stderr, not a result.
printf 'HTTP 502: Bad Gateway\n' >"$tmp/checks.err"
run 1 o/r
want 'gh failure' 1 ''
grep -q 'Bad Gateway' "$tmp/stderr" || { echo "FAIL: gh's message was not passed on"; fail=1; }
rm -f "$tmp/checks.err"
printf 'not json\n' >"$tmp/checks.json"
run 1 o/r
want 'unreadable output' 1 ''

# A log that can't be fetched is said so, and the other checks still print.
printf '[%s,%s]\n' "$failjob" "$failext" >"$tmp/checks.json"
printf 'run still in progress\n' >"$tmp/log.err"
run 1 o/r
want 'log unavailable' 0 'CI / unit  https://github.com/o/r/actions/runs/100/job/200
  (log unavailable: run still in progress)
deploy/preview  https://ci.example.com/build/7'
rm -f "$tmp/log.err"

# The repo defaults to the checkout's.
printf '[%s]\n' "$pass" >"$tmp/checks.json"
run 1
want 'default repo' 0 'no failed checks'
called 'default repo' 'repo view --json nameWithOwner --jq .nameWithOwner'

# The codex-review status is the review, not CI: it is pending until Codex has reviewed (which waits for the CI
# read) and failed while a Codex thread is open, so it never counts as a failed or pending check.
cr_fail='{"name":"codex-review","state":"FAILURE","bucket":"fail","link":"","workflow":""}'
cr_pend='{"name":"codex-review","state":"PENDING","bucket":"pending","link":"","workflow":""}'
printf '[%s,%s]\n' "$cr_fail" "$pass" >"$tmp/checks.json"
run 1 o/r
want 'codex-review failed is not a CI failure' 0 'no failed checks'
printf '[%s,%s]\n' "$cr_pend" "$pass" >"$tmp/checks.json"
run 1 o/r
want 'codex-review pending is not pending CI' 0 'no failed checks'
printf '[%s,%s]\n' "$cr_fail" "$failext" >"$tmp/checks.json"
run 1 o/r
want 'codex-review failed beside a real failure' 0 'deploy/preview  https://ci.example.com/build/7'
# Only the exact name is the review: a lookalike is a check.
printf '[{"name":"codex-review-lint","state":"FAILURE","bucket":"fail","link":"https://ci.example.com/y","workflow":""}]\n' >"$tmp/checks.json"
run 1 o/r
want 'a check named like the review' 0 'codex-review-lint  https://ci.example.com/y'

# --wait polls until nothing is pending (the review status aside), then prints the result.
printf '[%s,%s]\n' "$cr_pend" "$pass" >"$tmp/checks.json"
run 1 o/r --wait
want '--wait with only the review pending' 0 'no failed checks'
[ "$(grep -c 'pr checks' "$tmp/calls")" = 1 ] || { echo "FAIL: --wait polled although nothing was pending"; fail=1; }
printf '[%s,%s]\n' "$pend" "$cr_pend" >"$tmp/checks.1.json"
printf '[%s,%s]\n' "$pend" "$failext" >"$tmp/checks.2.json"
printf '[%s,%s]\n' "$pass" "$failext" >"$tmp/checks.json"
run 1 o/r --wait
want '--wait settles on the third poll' 0 'deploy/preview  https://ci.example.com/build/7'
[ "$(grep -c 'pr checks' "$tmp/calls")" = 3 ] || { echo "FAIL: --wait made $(grep -c 'pr checks' "$tmp/calls") polls, want 3"; fail=1; }
rm -f "$tmp/checks.1.json" "$tmp/checks.2.json"
# Still pending at the cap: the same result, exit 3 so a caller can tell.
printf '[%s,%s]\n' "$pend" "$pass" >"$tmp/checks.json"
run 1 o/r --wait
want '--wait pending at the cap' 3 'no failed checks
pending: 1 checks still running'
[ "$(grep -c 'pr checks' "$tmp/calls")" = 3 ] || { echo "FAIL: --wait made $(grep -c 'pr checks' "$tmp/calls") polls, want the cap of 3"; fail=1; }
printf '[%s,%s]\n' "$pend" "$failext" >"$tmp/checks.json"
run 1 --wait
want '--wait pending at the cap with a failure, default repo' 3 'deploy/preview  https://ci.example.com/build/7
pending: 1 checks still running'
# Without --wait it never polls and never exits 3.
run 1 o/r
want 'no --wait, pending' 0 'deploy/preview  https://ci.example.com/build/7
pending: 1 checks still running'
[ "$(grep -c 'pr checks' "$tmp/calls")" = 1 ] || { echo "FAIL: polled without --wait"; fail=1; }
# A gh failure while waiting is exit 1, not a timeout.
printf 'HTTP 502: Bad Gateway\n' >"$tmp/checks.err"
run 1 o/r --wait
want '--wait gh failure' 1 ''
rm -f "$tmp/checks.err"
run 1 o/r --nowait
want 'unknown option' 2 ''
run 1 o/r --wait extra
want 'extra argument' 2 ''

# Usage errors exit 2, never 0 or 1.
run
want 'no arguments' 2 ''
run ''
want 'empty PR' 2 ''
run x o/r
want 'non-numeric PR' 2 ''

exit $fail
