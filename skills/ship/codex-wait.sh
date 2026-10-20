#!/bin/sh
# Waits for Codex to finish reviewing a PR's head: runs the repo's scripts/codex-status.sh with DRY_RUN=1
# every 60s until it stops printing `pending`, and prints its last line. A review of an older commit
# counts as pending, since the status only counts a review of the head.
# Any failure of the status script ends the wait with its error rather than reading as "not done yet".
# Usage: codex-wait.sh <pr>   (from anywhere in the checkout; CODEX_WAIT_SECS caps the wait, default 1800)
set -eu
# A missing PR number exits 2 (usage), so a caller never reads it as a result or a timeout.
if [ -z "${1:-}" ]; then
	echo "usage: codex-wait.sh <pr>" >&2
	exit 2
fi
pr=$1
status="$(git rev-parse --show-toplevel)/scripts/codex-status.sh"
if [ ! -x "$status" ]; then
	echo "No executable $status." >&2
	exit 2
fi
deadline=$(($(date +%s) + ${CODEX_WAIT_SECS:-1800}))
while :; do
	if ! out=$(DRY_RUN=1 "$status" "$pr"); then
		echo "codex-status.sh failed${out:+: $out}" >&2
		exit 2
	fi
	case $out in
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
