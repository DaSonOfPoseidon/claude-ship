#!/bin/sh
# Tests codex-status.sh against Codex summaries whose Code Review row names no commit (`—`), as on
# OBDCracker #145 (claude-ship #30): the review counts for the head only when it was asked for after the
# head's push and finished after that request.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
sha=7ca1cc33ba5b464f6d80256626fb4c96f1ddb721
# A fake gh: answers each call codex-status.sh makes from files in $tmp, ignoring --jq.
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
case "\$*" in
*'graphql'*) ;;
*'.head.sha'*) echo $sha ;;
*'.head.repo.full_name'*) echo o/r ;;
*'.head.ref'*) echo b ;;
*'/activity'*) cat "$tmp/pushed" ;;
*'codex-pull-request-review-summary'*) cat "$tmp/summary" ;;
*'/comments'*) cat "$tmp/requests" ;;
*) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
fail=0

# expect <state> <commit cell> <pushed at> <requested at> <completed at>
expect() {
	echo "$3" >"$tmp/pushed"
	printf '%s\n' "$4" >"$tmp/requests"
	printf '| 📝 **Code Review** | ✅ **Completed** <relative-time datetime="%s">x</relative-time> | %s | Manual request |\n' \
		"$5" "$2" >"$tmp/summary"
	out=$(REPO=o/r DRY_RUN=1 PATH=$tmp/bin:$PATH sh "$root/scripts/codex-status.sh" 1 2>&1)
	case $out in
	"$1":*) ;;
	*)
		echo "FAIL (want $1): commit $2, pushed $3, requested $4, completed $5"
		echo "  $out"
		fail=1
		;;
	esac
}

# A named commit still works as before.
expect success '`7ca1cc3`' 2026-10-21T15:25:00Z 2026-10-21T15:26:03Z 2026-10-21T15:41:21.05Z
# No commit named: asked for after the push, finished after the request.
expect success '—' 2026-10-21T15:25:00Z 2026-10-21T15:26:03Z 2026-10-21T15:41:21.05Z
# The latest request counts: an older one before the push doesn't hide it.
expect success '—' 2026-10-21T15:25:00Z "$(printf '2026-10-21T15:00:00Z\n2026-10-21T15:26:03Z')" 2026-10-21T15:41:21.05Z
# Asked for before the push: the review may be of an older commit.
expect pending '—' 2026-10-21T15:30:00Z 2026-10-21T15:26:03Z 2026-10-21T15:41:21.05Z
# Asked for again after the push but the finished review is the earlier one.
expect pending '—' 2026-10-21T15:25:00Z 2026-10-21T15:45:00Z 2026-10-21T15:41:21.05Z
# No request at all.
expect pending '—' 2026-10-21T15:25:00Z '' 2026-10-21T15:41:21.05Z
# Another commit named.
expect pending '`0b996f7`' 2026-10-21T15:25:00Z 2026-10-21T15:26:03Z 2026-10-21T15:41:21.05Z

exit $fail
