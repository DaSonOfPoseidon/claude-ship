#!/bin/sh
# Waits for Codex to finish reviewing a PR's head: runs codex-status.sh (install.sh deploys it next to this
# script; in claude-ship's source it's scripts/codex-status.sh) with DRY_RUN=1 every 60s until it stops printing `pending`, and prints its last line. A review of an older commit
# counts as pending, since the status only counts a review of the head.
# Any failure of the status script ends the wait with its error rather than reading as "not done yet".
# A pending status that only a new request clears ends it with exit 3: a stalled review (its summary
# unchanged for CODEX_STALL_SECS, default 900), or a completion nobody asked for ("finished more than once").
# Usage: codex-wait.sh <pr>   (from anywhere in the checkout; CODEX_WAIT_SECS caps the wait, default 1200,
# so a stall shows before the cap)
set -eu
# A missing PR number exits 2 (usage), so a caller never reads it as a result or a timeout.
if [ -z "${1:-}" ]; then
	echo "usage: codex-wait.sh <pr>" >&2
	exit 2
fi
pr=$1
here=$(cd "$(dirname "$0")" && pwd)
status=$here/codex-status.sh
[ -x "$status" ] || status=$here/../../scripts/codex-status.sh
if [ ! -x "$status" ]; then
	echo "No executable codex-status.sh next to $0; run claude-ship's install.sh." >&2
	exit 2
fi
deadline=$(($(date +%s) + ${CODEX_WAIT_SECS:-1200}))
while :; do
	if ! out=$(DRY_RUN=1 "$status" "$pr"); then
		echo "codex-status.sh failed${out:+: $out}" >&2
		exit 2
	fi
	case $out in
	pending:*stalled* | pending:*'finished more than once'*)
		echo "$out"
		exit 3
		;;
	pending:*) ;;
	*)
		echo "$out"
		exit 0
		;;
	esac
	if [ "$(date +%s)" -ge "$deadline" ]; then
		echo "Timed out: $out" >&2
		exit 1
	fi
	# Never sleep past the deadline.
	left=$((deadline - $(date +%s)))
	if [ "$left" -gt 0 ]; then
		sleep $((left < 60 ? left : 60))
	fi
done
