#!/bin/sh
# Tests codex-wait.sh's exits against a fake codex-status.sh next to a copy of it: a result exits 0, a
# pending status that only a new request clears exits 3 (claude-ship #61), and a failing status exits 2.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/skills/ship/codex-wait.sh" "$tmp/"
fail=0

# expect <exit> <label> <status line> [status exit]
expect() {
	printf '#!/bin/sh\necho "%s"\nexit %s\n' "$3" "${4:-0}" >"$tmp/codex-status.sh"
	chmod +x "$tmp/codex-status.sh"
	CODEX_WAIT_SECS=1 sh "$tmp/codex-wait.sh" 1 >/dev/null 2>&1
	got=$?
	if [ "$got" != "$1" ]; then
		echo "FAIL (want exit $1, got $got): $2"
		fail=1
	fi
}

expect 0 'success' 'success: Codex reviewed abc with no findings (abc)'
expect 0 'failure' 'failure: 1 unresolved Codex thread(s); fix or answer each, then resolve it (abc)'
expect 3 'stalled' "pending: Codex's review of abc stalled (no update in 15 min, openai/codex#55890); ask again with @codex review (abc)"
expect 3 'finished more than once' 'pending: Codex finished more than once since the last request for abc, so neither is tied to it; ask again with @codex review (abc)'
expect 3 'not acknowledged' "pending: Codex hasn't acknowledged the request for abc in 5 min; ask again with @codex review (abc)"
expect 1 'still waiting' 'pending: Waiting for Codex to review abc (abc)'
expect 2 'status error' 'boom' 1

# A pending status is shown when the cap is hit (exit 1): the foreground agent reads it to decide to call again
# (claude-ship #147).
printf '#!/bin/sh\necho "pending: Waiting for Codex to review abc (abc)"\n' >"$tmp/codex-status.sh"
chmod +x "$tmp/codex-status.sh"
CODEX_WAIT_SECS=1 sh "$tmp/codex-wait.sh" 1 >"$tmp/out" 2>&1
got=$?
if [ "$got" != 1 ] || ! grep -q 'Timed out: pending: Waiting for Codex to review abc' "$tmp/out"; then
	echo "FAIL (want exit 1 and the pending status in the output, got exit $got): pending cap shows its status"
	fail=1
fi
exit $fail
