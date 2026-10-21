#!/bin/sh
# Tests codex-status.sh against Codex summaries whose Code Review row names no commit (`—`), as on
# OBDCracker #145 (claude-ship #30). Such a row counts for the head only when exactly one trusted
# `@codex review` (owner, member or collaborator) was made since the previous completed review, that request
# came after the head's push, and the review finished after it. The fake gh below serves fixtures and applies
# the script's own --jq filters with real jq, so the filters are tested too.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
sha=7ca1cc33ba5b464f6d80256626fb4c96f1ddb721
cat >"$tmp/pr.json" <<EOT
{"head":{"sha":"$sha","ref":"b","repo":{"full_name":"o/r"}}}
EOT
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
expr=
prev=
for a in "\$@"; do
	[ "\$prev" = --jq ] && expr=\$a
	prev=\$a
done
case "\$*" in
*'graphql'*) exit 0 ;;
*'/activity'*) f=activity ;;
*'/pulls/1/reviews'*) f=reviews ;;
*'/pulls/1'*) f=pr ;;
*'/issues/1/comments'*) f=comments ;;
*) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
jq -r "\$expr" "$tmp/\$f.json"
EOF
chmod +x "$tmp/bin/gh"
fail=0

# check <state> <label>: runs the script on the fixtures in $tmp.
check() {
	out=$(REPO=o/r DRY_RUN=1 PATH=$tmp/bin:$PATH sh "$root/scripts/codex-status.sh" 1 2>&1)
	case $out in
	"$1":*"${WANT_MSG:-}"*) ;;
	*)
		echo "FAIL (want $1): $2"
		echo "  $out"
		fail=1
		;;
	esac
}

# expect <state> <label> <commit cell> <pushed at> <completed at> <requests> <markers>
# requests: lines "<time> <author_association>"; markers: lines "receipt <time>" or "review <time>", the
# earlier completions Codex left behind (a clean review's receipt comment, a review with findings).
expect() {
	jq -n --arg t "$4" --arg s "$sha" \
		'[{activity_type:"push",after:$s,timestamp:$t}]' >"$tmp/activity.json"
	printf '%s\n' "$7" | jq -Rn '[inputs | split(" ") | select(.[0] == "review")
		| {user:{login:"chatgpt-codex-connector[bot]"},submitted_at:.[1]}]' >"$tmp/reviews.json"
	row=$(printf '| 📝 **Code Review** | ✅ **Completed** <relative-time datetime="%s">x</relative-time> | %s | Manual request |' "$5" "$3")
	{
		printf '%s\n' "$6" | jq -Rn '[inputs | split(" ") | select(length == 2)
			| {user:{login:"u",type:"User"},author_association:.[1],created_at:.[0],body:"@codex review"}]'
		printf '%s\n' "$7" | jq -Rn '[inputs | split(" ") | select(.[0] == "receipt")
			| {user:{login:"chatgpt-codex-connector[bot]",type:"Bot"},author_association:"NONE",created_at:.[1],
			body:"<!-- codex-review-receipt:v1 -->"}]'
		jq -n --arg r "$row" '[{user:{login:"chatgpt-codex-connector[bot]",type:"Bot"},author_association:"NONE",
			created_at:"2026-10-21T14:00:00Z",body:("<!-- codex-pull-request-review-summary -->\n" + $r)}]'
	} | jq -s 'add' >"$tmp/comments.json"
	check "$1" "$2"
}

p=2026-10-21T15:25:00Z
c=2026-10-21T15:41:21.05Z
r1='2026-10-21T15:26:03Z OWNER'

# A named commit still works as before, with no request at all.
expect success 'commit named' '`7ca1cc3`' $p $c '' ''
# Another commit named.
expect pending 'other commit named' '`0b996f7`' $p $c "$r1" ''
# No commit named: asked for after the push, finished after the request.
expect success 'normal blank case' '—' $p $c "$r1" 'receipt 2026-10-21T15:41:19Z'
expect success 'member counts' '—' $p $c '2026-10-21T15:26:03Z MEMBER' ''
expect success 'collaborator counts' '—' $p $c '2026-10-21T15:26:03Z COLLABORATOR' ''
# Asked for before the push: the review may be of an older commit.
expect pending 'request before push' '—' 2026-10-21T15:30:00Z $c "$r1" ''
# Asked for again after the completion, which belongs to the earlier request.
expect pending 'request after completion' '—' $p $c "$r1
2026-10-21T15:45:00Z OWNER" ''
# No request at all.
expect pending 'no request' '—' $p $c '' ''
# Only requests from outsiders: anyone can comment, so they prove nothing...
expect pending 'untrusted request only' '—' $p $c '2026-10-21T15:26:03Z NONE' ''
expect pending 'contributor request only' '—' $p $c '2026-10-21T15:26:03Z CONTRIBUTOR' ''
# ...and an outsider's request can't reset a success.
expect success 'untrusted request ignored after' '—' $p $c "$r1
2026-10-21T15:50:00Z NONE" ''
expect success 'untrusted request ignored before' '—' $p $c "2026-10-21T15:20:00Z NONE
$r1" ''
# Round 2 after a review with findings: only the new request is outstanding.
expect success 'round 2 after findings' '—' $p $c "2026-10-21T14:50:00Z OWNER
$r1" 'review 2026-10-21T15:00:00Z'
# ...or after a clean review.
expect success 'round 2 after clean' '—' $p $c "2026-10-21T14:50:00Z OWNER
$r1" 'receipt 2026-10-21T15:00:00Z'
# The race: a review of the old head is still running when the new head is pushed and re-requested. Its
# completion comes after both, but it can't be told apart from the new one's, so two requests stay pending.
expect pending 'overlap race' '—' $p $c "2026-10-21T14:50:00Z OWNER
$r1" 'receipt 2026-10-21T15:41:19Z'
# Two requests after the push with one completion: also ambiguous, and the description says to push.
WANT_MSG='delete the failed' expect pending 'two requests after push' '—' $p $c "$r1
2026-10-21T15:27:00Z OWNER" ''
# A failed review leaves no marker, so a clean retry sees both requests: stuck until a new commit.
WANT_MSG='delete the failed' expect pending 'failed then retried' '—' $p $c "2026-10-21T15:00:00Z OWNER
$r1" ''
# A new commit doesn't clear it: the failed request is still outstanding. Deleting that comment does.
WANT_MSG='delete the failed' expect pending 'new commit after failure' '—' 2026-10-21T15:50:00Z 2026-10-21T16:05:00Z "2026-10-21T15:00:00Z OWNER
2026-10-21T15:55:00Z OWNER" ''
expect success 'stale request deleted' '—' 2026-10-21T15:50:00Z 2026-10-21T16:05:00Z '2026-10-21T15:55:00Z OWNER' ''
# A waiting review (no request yet) keeps the plain message.
WANT_MSG='Waiting for Codex' expect pending 'plain waiting' '—' $p $c '' ''
# Reviews less than a minute apart: the receipt nearest the completion is its own, the one before it is
# the previous completion.
expect success "close rounds" "—" $p $c "2026-10-21T15:20:00Z OWNER
2026-10-21T15:40:45Z OWNER" 'receipt 2026-10-21T15:40:40Z
receipt 2026-10-21T15:41:19Z'
# No receipt of its own near the completion: the latest marker is a previous one.
expect success 'no own receipt' '—' $p $c "$r1" 'receipt 2026-10-21T15:00:00Z'

exit $fail
