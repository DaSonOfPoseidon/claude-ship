#!/bin/sh
# Lists a PR's failed CI checks, compactly, so the implementer fixes CI without the main session reading logs.
# One block per failed check: "<workflow> / <name>  <link>", then, for a GitHub Actions job, the last 60 lines of
# its failed-step log, indented, without colours or timestamps. Other checks (external statuses): name and link.
# Then "no failed checks" when none failed, and "pending: <n> checks still running" if any. The `codex-review`
# status is the review, not CI (pending until Codex has reviewed, failed while a thread is open), so it is
# ignored. With --wait it first polls until no check is pending (CI_WAIT_POLLS polls, 18, CI_WAIT_INTERVAL
# seconds apart, 30: 9 minutes, under a 10-minute Bash timeout). Exit 0 when it printed a result, 3 when --wait
# gave up with checks still pending (the result is printed), 2 on usage, 1 on a gh failure it couldn't read.
# Log text is untrusted: it is only printed.
# Usage: ci-failures.sh <pr> [owner/repo] [--wait]   (repo defaults to the current checkout's)
set -eu
usage() {
	echo "usage: ci-failures.sh <pr> [owner/repo] [--wait]" >&2
	exit 2
}
# A missing or non-numeric PR number exits 2 (usage), so a caller never reads it as a result.
case ${1:-} in '' | *[!0-9]*) usage ;; esac
pr=$1
shift
slug=
wait=
for arg in "$@"; do
	case $arg in
	--wait) wait=1 ;;
	-* | '') usage ;;
	*)
		[ -z "$slug" ] || usage
		slug=$arg
		;;
	esac
done
[ -n "$slug" ] || slug=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The review status, set by the codex-review workflow; not a CI check.
review=codex-review
polls=${CI_WAIT_POLLS:-18}
interval=${CI_WAIT_INTERVAL:-30}
n=0
timedout=
while :; do
	n=$((n + 1))
	# gh pr checks exits non-zero when a check failed or is pending: that is a result, so only its output counts.
	rc=0
	gh pr checks "$pr" -R "$slug" --json name,state,bucket,link,workflow >"$tmp/checks" 2>"$tmp/err" || rc=$?
	if ! jq -e -s '.[0] | type == "array"' "$tmp/checks" >/dev/null 2>&1; then
		# No checks at all is not a failure: gh prints a message instead of JSON.
		if grep -q 'no checks reported' "$tmp/err"; then
			echo '[]' >"$tmp/checks"
		else
			echo "ci-failures.sh: gh pr checks failed (exit $rc): $(head -n 3 "$tmp/err")" >&2
			exit 1
		fi
	fi
	pending=$(jq --arg r "$review" '[.[] | select(.bucket == "pending" and .name != $r)] | length' "$tmp/checks")
	[ -n "$wait" ] && [ "$pending" -gt 0 ] || break
	if [ "$n" -ge "$polls" ]; then
		timedout=1
		break
	fi
	sleep "$interval"
done

esc=$(printf '\033')
tab=$(printf '\t')
us=$(printf '\037')
# One line per failed check: workflow, name, link, separated by the unit separator (not whitespace, so an empty
# workflow stays a field). Control characters become spaces first, so a name can't add lines, separators or
# escape sequences to the output.
jq -r --arg r "$review" '.[] | select(.bucket == "fail" and .name != $r)
	| [.workflow, .name, .link] | map((. // "") | gsub("[[:cntrl:]]"; " ")) | join("\u001f")' "$tmp/checks" >"$tmp/failed"
failed=0
while IFS=$us read -r workflow name link; do
	failed=$((failed + 1))
	if [ -n "$workflow" ]; then
		echo "$workflow / $name  $link"
	else
		echo "$name  $link"
	fi
	# An Actions job link ends in /actions/runs/<run>/job/<job>; both ids must be numbers, or the check is
	# treated as external and its link is never passed to gh.
	case $link in
	*/actions/runs/*/job/*)
		rest=${link#*/actions/runs/}
		run=${rest%%/*}
		job=${rest#*/job/}
		job=${job%%[/?#]*}
		;;
	*)
		run=
		job=
		;;
	esac
	case $run in '' | *[!0-9]*) continue ;; esac
	case $job in '' | *[!0-9]*) continue ;; esac
	if ! gh run view "$run" -R "$slug" --job "$job" --log-failed >"$tmp/log" 2>"$tmp/logerr"; then
		echo "  (log unavailable: $(head -n 1 "$tmp/logerr" | cut -c1-200))"
		continue
	fi
	# Lines are "<job><tab><step><tab><timestamp> <text>": keep the text, drop colours and carriage returns.
	tr -d '\r' <"$tmp/log" |
		sed -E "s/^[^${tab}]*${tab}[^${tab}]*${tab}//; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//; s/${esc}\\[[0-9;]*[A-Za-z]//g" |
		tail -n 60 | cut -c1-400 | sed 's/^/  /'
done <"$tmp/failed"

[ "$failed" -gt 0 ] || echo "no failed checks"
[ "$pending" -eq 0 ] || echo "pending: $pending checks still running"
[ -z "$timedout" ] || exit 3
exit 0
