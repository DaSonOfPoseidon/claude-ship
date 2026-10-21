#!/bin/sh
# Tests codex-status.sh against Codex summaries whose Code Review row names no commit (`—`), as on
# OBDCracker #145 (claude-ship #30). Such a row counts for the head only when the trusted `@codex review`
# requests (owner or collaborator) are as many as the completion markers (receipts and Codex reviews, the
# current one included), the latest request came after the head's push, and the review finished after it.
# The fake gh below serves fixtures and applies
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
	# GitHub rejects a commit status description over 140 characters.
	desc=${out#*: }
	desc=${desc% (*}
	if [ "${#desc}" -gt 140 ]; then
		echo "FAIL: description is ${#desc} characters (max 140): $2"
		fail=1
	fi
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
# The current review's own receipt, a few seconds before the summary's completion time.
m='receipt 2026-10-21T15:41:19Z'

# A named commit still works as before, with no request at all.
expect success 'commit named' '`7ca1cc3`' $p $c '' ''
# Another commit named.
expect pending 'other commit named' '`0b996f7`' $p $c "$r1" 'receipt 2026-10-21T15:41:19Z'
# No commit named: asked for after the push, finished after the request.
expect success 'normal blank case' '—' $p $c "$r1" "$m"
# Members are not trusted (an org member needn't have access to the repo); collaborators are.
expect pending 'member does not count' '—' $p $c '2026-10-21T15:26:03Z MEMBER' "$m"
expect success 'collaborator counts' '—' $p $c '2026-10-21T15:26:03Z COLLABORATOR' "$m"
# Asked for before the push: the review may be of an older commit.
expect pending 'request before push' '—' 2026-10-21T15:30:00Z $c "$r1" "$m"
# Asked for again after the completion, which belongs to the earlier request.
expect pending 'request after completion' '—' $p $c "$r1
2026-10-21T15:45:00Z OWNER" "$m"
# No request at all.
expect pending 'no request' '—' $p $c '' "$m"
# Only requests from outsiders: anyone can comment, so they prove nothing...
expect pending 'untrusted request only' '—' $p $c '2026-10-21T15:26:03Z NONE' "$m"
expect pending 'contributor request only' '—' $p $c '2026-10-21T15:26:03Z CONTRIBUTOR' "$m"
# ...and an outsider's request can't reset a success or hide one.
expect success 'untrusted request ignored after' '—' $p $c "$r1
2026-10-21T15:50:00Z NONE" "$m"
expect success 'untrusted request ignored before' '—' $p $c "2026-10-21T15:20:00Z NONE
$r1" "$m"
# Round 2 after a review with findings, or after a clean one: every request has its completion.
expect success 'round 2 after findings' '—' $p $c "2026-10-21T14:50:00Z OWNER
$r1" "review 2026-10-21T15:00:00Z
$m"
expect success 'round 2 after clean' '—' $p $c "2026-10-21T14:50:00Z OWNER
$r1" "receipt 2026-10-21T15:00:00Z
$m"
# The race: a review of the old head is still running when the new head is pushed and re-requested. Its
# completion comes after both, but one marker for two requests stays pending.
expect pending 'overlap race' '—' $p $c "2026-10-21T14:50:00Z OWNER
$r1" "$m"
# Codex's scenario: R1 and R2 on the old head, R1 completes, the new head is pushed, R3 is requested, then
# R2's blank completion arrives. Three requests, two markers.
WANT_MSG='if one failed' expect pending 'R1 R2 push R3 R2 completes' '—' 2026-10-21T15:20:00Z $c "2026-10-21T15:00:00Z OWNER
2026-10-21T15:05:00Z OWNER
2026-10-21T15:30:00Z OWNER" "review 2026-10-21T15:10:00Z
$m"
# Once R3's review completes too, every request is matched.
expect success 'R3 completes as well' '—' 2026-10-21T15:20:00Z 2026-10-21T15:50:00Z "2026-10-21T15:00:00Z OWNER
2026-10-21T15:05:00Z OWNER
2026-10-21T15:30:00Z OWNER" "review 2026-10-21T15:10:00Z
receipt 2026-10-21T15:41:19Z
receipt 2026-10-21T15:49:50Z"
# More markers than requests (an unrequested review): not matched either, stay pending.
expect pending 'unrequested review' '—' $p $c "$r1" "receipt 2026-10-21T15:00:00Z
$m"
# Two requests after the push with one completion: ambiguous, and the description says how to recover.
WANT_MSG='if one failed' expect pending 'two requests after push' '—' $p $c "$r1
2026-10-21T15:27:00Z OWNER" "$m"
# A failed review leaves no marker, so a clean retry sees more requests than completions: stuck until the
# failed review's request comment is deleted and the workflow rerun (never while a review is still running).
WANT_MSG='if one failed' expect pending 'failed then retried' '—' $p $c "2026-10-21T15:00:00Z OWNER
$r1" "$m"
# A new commit doesn't clear it: the failed request is still counted. Deleting that comment does.
WANT_MSG='if one failed' expect pending 'new commit after failure' '—' 2026-10-21T15:50:00Z 2026-10-21T16:05:00Z "2026-10-21T15:00:00Z OWNER
2026-10-21T15:55:00Z OWNER" 'receipt 2026-10-21T16:04:50Z'
expect success 'stale request deleted' '—' 2026-10-21T15:50:00Z 2026-10-21T16:05:00Z '2026-10-21T15:55:00Z OWNER' 'receipt 2026-10-21T16:04:50Z'
# A waiting review (no request yet) keeps the plain message.
WANT_MSG='Waiting for Codex' expect pending 'plain waiting' '—' $p $c '' ''

exit $fail
