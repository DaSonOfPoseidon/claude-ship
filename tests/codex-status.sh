#!/bin/sh
# Tests codex-status.sh, mostly against Codex summaries whose Code Review row names no commit (`—`, claude-ship
# #30 and #61; the rules are in docs/scripts.md). The fake gh below serves fixtures and applies the script's own
# --jq filters with real jq, so the filters are tested too.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
sha=7ca1cc33ba5b464f6d80256626fb4c96f1ddb721
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
expr=
prev=
for a in "\$@"; do
	[ "\$prev" = --jq ] && expr=\$a
	prev=\$a
done
case "\$*" in
*'graphql'*)
	# No unresolved threads unless a test writes threads.json (the response's shape, not the script's filter).
	[ -f "$tmp/threads.json" ] || exit 0
	f=threads
	;;
*'/activity'*) f=activity ;;
*'/issues/comments/'*'/reactions'*)
	# Only asked for when a request is old and nothing else shows Codex started: a missing file is a test failure.
	[ -f "$tmp/reactions.json" ] || { echo "unexpected reactions call: \$*" >&2; exit 1; }
	f=reactions
	;;
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
	"$1":*"$WANT_MSG"*) ;;
	*)
		echo "FAIL (want $1): $2"
		echo "  $out"
		fail=1
		;;
	esac
}

# HEAD_REPO is the PR head's repository ("null" for a deleted fork), APPROVALS lines "<time>|<association>|<user
# type>|<body>" of extra comments (the owner's approval phrase on a fork PR).
HEAD_REPO=o/r
APPROVALS=

# expect <state> <label> <commit cell> <pushed at> <completed at> <requests> <markers>
# requests: lines "<time> <author_association>"; markers: lines "receipt <time>" or "review <time>", the
# earlier completions Codex left behind (a clean review's receipt comment, a review with findings).
expect() {
	jq -n --arg s "$sha" --arg h "$HEAD_REPO" '{head:{sha:$s,ref:"b",repo:(if $h == "null" then null else {full_name:$h} end)}}' >"$tmp/pr.json"
	jq -n --arg t "$4" --arg s "$sha" \
		'[{activity_type:"push",after:$s,timestamp:$t}]' >"$tmp/activity.json"
	printf '%s\n' "$7" | jq -Rn '[inputs | split(" ") | select(.[0] == "review")
		| {user:{login:"chatgpt-codex-connector[bot]"},submitted_at:.[1]}]' >"$tmp/reviews.json"
	row=$(printf '| 📝 **Code Review** | ✅ **Completed** <relative-time datetime="%s">x</relative-time> | %s | Manual request |' "$5" "$3")
	# ROW replaces the row, for a review still running.
	row=${ROW:-$row}
	{
		# EYES is the 👀 count on every request (the list shows counts, not who reacted).
		printf '%s\n' "$6" | jq -Rn --argjson eyes "${EYES:-0}" '[inputs | split(" ") | select(length == 2)
			| {id:777,user:{login:"u",type:"User"},author_association:.[1],created_at:.[0],body:"@codex review",reactions:{eyes:$eyes}}]'
		printf '%s\n' "$7" | jq -Rn '[inputs | split(" ") | select(.[0] == "receipt")
			| {user:{login:"chatgpt-codex-connector[bot]",type:"Bot"},author_association:"NONE",created_at:.[1],
			body:"<!-- codex-review-receipt:v1 -->"}]'
		printf '%s\n' "$APPROVALS" | jq -Rn '[inputs | split("|") | select(length == 4)
			| {id:888,user:{login:"u",type:.[2]},author_association:.[1],created_at:.[0],body:.[3],reactions:{eyes:0}}]'
		# STATE is the summary's Code Review state (none by default), STATE_SHA the commit it names (null by
		# default), AGE how many seconds ago it was edited and SUMMARY_AT the exact edit time (overrides AGE).
		jq -n --arg r "$row" --arg st "$STATE" --arg ss "${STATE_SHA:-}" --argjson age "$AGE" --arg at "${SUMMARY_AT:-}" '[{user:{login:"chatgpt-codex-connector[bot]",type:"Bot"},
			author_association:"NONE",created_at:"2026-10-21T14:00:00Z",updated_at:(if $at != "" then $at else (now - $age | todate) end),
			body:("<!-- codex-pull-request-review-summary -->\n"
				+ (if $st == "" then "" else "<!-- codex-review-state:v1 {\"code_review\":{\"commit_sha\":" + (if $ss == "" then "null" else "\"" + $ss + "\"" end) + ",\"status\":\"" + $st + "\"}} -->\n" end)
				+ $r)}]'
	} | jq -s 'add' >"$tmp/comments.json"
	check "$1" "$2"
}

# with_msg <text> expect …: also requires <text> in the output (a prefix assignment may persist in some shells).
WANT_MSG=
STATE=
AGE=0
with_msg() {
	WANT_MSG=$1
	shift
	"$@"
	WANT_MSG=
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
# A new request ends any review still running (claude-ship #61), so only the latest trusted request counts: a
# review of the old head that is running when the new head is pushed and re-requested ends there.
expect success 'overlap race' '—' $p $c "2026-10-21T14:50:00Z OWNER
$r1" "$m"
# R1 and R2 on the old head, R1 completes, the new head is pushed, R3 ends R2: the marker after R3 is R3's.
expect success 'R1 R2 push R3' '—' 2026-10-21T15:20:00Z $c "2026-10-21T15:00:00Z OWNER
2026-10-21T15:05:00Z OWNER
2026-10-21T15:30:00Z OWNER" "review 2026-10-21T15:10:00Z
$m"
# Two markers after the latest request (one unasked for, #49) can't be told apart: fail closed and say how to recover.
with_msg 'more than once' expect pending 'two markers after the request' '—' 2026-10-21T15:20:00Z 2026-10-21T15:50:00Z "2026-10-21T15:00:00Z OWNER
2026-10-21T15:30:00Z OWNER" "review 2026-10-21T15:10:00Z
receipt 2026-10-21T15:41:19Z
receipt 2026-10-21T15:49:50Z"
# Markers before the latest request belong to earlier requests or none; they don't matter.
expect success 'old unrequested review' '—' $p $c "$r1" "receipt 2026-10-21T15:00:00Z
$m"
# Two requests after the push with one completion: the second ended the first.
expect success 'two requests after push' '—' $p $c "$r1
2026-10-21T15:27:00Z OWNER" "$m"
# A stalled or failed review leaves no marker; its retry ends it, so nothing needs deleting.
expect success 'stalled then retried' '—' $p $c "2026-10-21T15:00:00Z OWNER
$r1" "$m"
expect success 'new commit after a stall' '—' 2026-10-21T15:50:00Z 2026-10-21T16:05:00Z "2026-10-21T15:00:00Z OWNER
2026-10-21T15:55:00Z OWNER" 'receipt 2026-10-21T16:04:50Z'
# The retry hasn't finished yet: no marker after it, so still waiting.
with_msg 'Waiting for Codex' expect pending 'retry still running' '—' $p $c "$r1
2026-10-21T15:42:00Z OWNER" "$m"
# Each request answered before the next.
expect success 'interleaved rounds' '—' $p $c "2026-10-21T14:50:00Z OWNER
$r1" "receipt 2026-10-21T15:00:00Z
$m"
# A marker at the same second as the latest request can't be told apart from one before it: fail closed.
expect pending 'marker ties request' '—' $p $c "$r1" 'receipt 2026-10-21T15:26:03Z'
# A waiting review (no request yet) keeps the plain message.
with_msg 'Waiting for Codex' expect pending 'plain waiting' '—' $p $c '' ''

# openai/codex#55890, claude-ship #61: a review that says running and hasn't changed for 15 min stalled.
# stall <state> <age> <row> expect …: the summary's state marker, its age in seconds, and its row ('' keeps
# expect's completed row).
ROW=
stall() {
	STATE=$1
	AGE=$2
	ROW=$3
	shift 3
	"$@"
	STATE=
	AGE=0
	ROW=
}
# The row of a running review names the commit but no completion yet.
running='| 📝 **Code Review** | ⏳ **Running** | `7ca1cc3` | Manual request |'
stall running 960 "$running" with_msg 'stalled' expect pending 'running for 16 min' '`7ca1cc3`' $p $c "$r1" ''
stall running 300 "$running" with_msg 'Waiting for Codex' expect pending 'running for 5 min' '`7ca1cc3`' $p $c "$r1" ''
# A stalled request next to a retry: the summary was edited when the retry started.
stall running 60 "$running" with_msg 'Waiting for Codex' expect pending 'retry running' '`7ca1cc3`' $p $c "$r1
2026-10-21T16:30:00Z OWNER" ''
# A completed review isn't stalled however old its summary is, and a stall never hides a finished one.
stall completed 960 '' expect success 'old completed summary' '—' $p $c "$r1" "$m"
stall running 960 '' expect success 'stale state, completed row' '`7ca1cc3`' $p $c '' ''
# A state marker that isn't JSON reads as not stalled.
stall 'x"}' 960 "$running" with_msg 'Waiting for Codex' expect pending 'unreadable state' '`7ca1cc3`' $p $c "$r1" ''

# Gate on #61: a retry Codex hasn't picked up yet isn't a stall (the summary is 16 min old, the latest request a minute old).
recent=$(jq -rn 'now - 60 | todate')
stall running 960 "$running" with_msg 'Waiting for Codex' expect pending 'retry not picked up yet' '`7ca1cc3`' $p $c "$r1
$recent OWNER" ''
# ...nor is a head pushed a minute ago.
stall running 960 "$running" with_msg 'Waiting for Codex' expect pending 'head just pushed' '`7ca1cc3`' "$recent" $c "$r1" ''
# A stale running state for another commit doesn't make the head stalled; one naming the head does.
STATE_SHA=0b996f7000000000000000000000000000000000
stall running 960 "$running" with_msg 'Waiting for Codex' expect pending 'running state of another commit' '`7ca1cc3`' $p $c "$r1" ''
STATE_SHA=$sha
stall running 960 "$running" with_msg 'stalled' expect pending 'running state of the head' '`7ca1cc3`' $p $c "$r1" ''
STATE_SHA=

# claude-ship #133: a request Codex never picked up. The latest trusted request, after the head's push, is
# CODEX_ACK_SECS (default 300) old and Codex has shown nothing since: no bot 👀 on it, no summary edit, receipt or
# review after it. The row names another commit, so the head has no review; the summary is 2 h old.
ago() { jq -rn --argjson s "$1" 'now - $s | todate'; }
pushed=$(ago 3600)
other='`0b996f7`'
AGE=7200
with_msg 'acknowledged' expect pending 'unacknowledged at 6 min' "$other" "$pushed" $c "$(ago 360) OWNER" ''
with_msg 'Waiting for Codex' expect pending 'not yet unacknowledged at 4 min' "$other" "$pushed" $c "$(ago 240) OWNER" ''
# CODEX_ACK_SECS moves the line.
CODEX_ACK_SECS=600
export CODEX_ACK_SECS
with_msg 'Waiting for Codex' expect pending 'ack secs raised' "$other" "$pushed" $c "$(ago 360) OWNER" ''
unset CODEX_ACK_SECS
# The bot's 👀 now is a sign of life (checked through the reactions list); anyone else's is not.
echo '[{"content":"eyes","user":{"login":"chatgpt-codex-connector[bot]"}}]' >"$tmp/reactions.json"
EYES=1
with_msg 'Waiting for Codex' expect pending 'bot eyes' "$other" "$pushed" $c "$(ago 360) OWNER" ''
echo '[{"content":"eyes","user":{"login":"u"}},{"content":"+1","user":{"login":"chatgpt-codex-connector[bot]"}}]' >"$tmp/reactions.json"
with_msg 'acknowledged' expect pending 'user eyes only' "$other" "$pushed" $c "$(ago 360) OWNER" ''
EYES=0
rm -f "$tmp/reactions.json"
# A review, a receipt or a summary edit after the request is a sign of life; before it, none.
with_msg 'Waiting for Codex' expect pending 'review after the request' "$other" "$pushed" $c "$(ago 360) OWNER" "review $(ago 100)"
with_msg 'Waiting for Codex' expect pending 'receipt after the request' "$other" "$pushed" $c "$(ago 360) OWNER" "receipt $(ago 100)"
with_msg 'acknowledged' expect pending 'review before the request' "$other" "$pushed" $c "$(ago 360) OWNER" "review $(ago 1000)"
AGE=60
with_msg 'Waiting for Codex' expect pending 'summary edited after the request' "$other" "$pushed" $c "$(ago 360) OWNER" ''
AGE=7200
# A request from before the push was for an earlier head, and an outsider's request proves nothing.
with_msg 'Waiting for Codex' expect pending 'request before push' "$other" "$(ago 200)" $c "$(ago 360) OWNER" ''
with_msg 'Waiting for Codex' expect pending 'untrusted request' "$other" "$pushed" $c "$(ago 360) NONE" ''
# A request in the push's own second belongs to this head (codex-request.sh counts it too), so it can be retried.
tie=$(ago 360)
with_msg 'acknowledged' expect pending 'request tied with the push' "$other" "$tie" $c "$tie OWNER" ''
# Only the latest request counts: an old unacknowledged one followed by a young one is waiting...
with_msg 'Waiting for Codex' expect pending 'older unacked, newer young' "$other" "$pushed" $c "$(ago 900) OWNER
$(ago 100) OWNER" ''
# ...and followed by an acknowledged one too.
with_msg 'Waiting for Codex' expect pending 'older unacked, newer acked' "$other" "$pushed" $c "$(ago 900) OWNER
$(ago 360) OWNER" "review $(ago 100)"
AGE=0
# #139: a running review whose request is 16 min old but whose summary was edited a minute ago is not stalled and
# was acknowledged, so it is plain pending (and codex-request.sh doesn't replace it).
stall running 60 "$running" with_msg 'Waiting for Codex' expect pending 'old request, fresh summary' '`7ca1cc3`' "$pushed" $c "$(ago 960) OWNER" ''
# A stall keeps its message when the request is unacknowledged too.
stall running 2000 "$running" with_msg 'stalled' expect pending 'stalled outranks unacknowledged' '`7ca1cc3`' "$pushed" $c "$(ago 960) OWNER" ''
# A finished review wins over everything.
AGE=7200
expect success 'finished beats unacknowledged' '`7ca1cc3`' "$pushed" "$(ago 100)" "$(ago 360) OWNER" ''
AGE=0

# claude-ship #126: fork PRs. Codex can't review them (openai/codex#47577), so a failed review says a retry won't
# help, and the repo owner can approve the head by commenting a set phrase after its push.
# fork <head repo> <approval lines> expect …: runs one case against that head repository and those comments.
fork() {
	HEAD_REPO=$1
	APPROVALS=$2
	shift 2
	"$@"
	HEAD_REPO=o/r
	APPROVALS=
}
failed='| 📝 **Code Review** | ❌ **Failed** <relative-time datetime="2026-10-21T15:41:21Z">x</relative-time> | `7ca1cc3` | Manual request |'
after='2026-10-21T15:30:00Z'
before='2026-10-21T15:20:00Z'
unresolved='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"}}]}}]}}}}}'
ROW=$failed
# 1. A fork PR whose review failed and with no approval: a retry won't help, and the owner is told how to approve.
with_msg "Codex can't review fork PRs" fork f/r '' expect failure 'fork, failed review' '`7ca1cc3`' $p $c '' ''
# The approval phrase is in the message, and the description fits GitHub's limit (check() enforces 140).
with_msg "comment 'Okay to merge' to approve 7ca1cc3" fork f/r '' expect failure 'fork, failed review, hint' '`7ca1cc3`' $p $c '' ''
# 2. The owner's phrase after the push approves it.
with_msg 'Owner approved 7ca1cc3 for merge (fork PR)' fork f/r "$after|OWNER|User|Okay to merge" expect success 'fork, owner approval' '`7ca1cc3`' $p $c '' ''
# ...with no Codex row at all, since Codex never reviews these.
ROW='| 📝 **Code Review** | ⏳ **Running** | `0b996f7` | Manual request |'
fork f/r "$after|OWNER|User|Okay to merge" expect success 'fork, approval, no review of the head' '`7ca1cc3`' $p $c '' ''
ROW=$failed
# 3. An approval from before the push doesn't carry over to the new head.
with_msg "Codex can't review fork PRs" fork f/r "$before|OWNER|User|Okay to merge" expect failure 'fork, approval before push' '`7ca1cc3`' $p $c '' ''
# ...and one in the push's own second can't be told apart from before it.
with_msg "Codex can't review fork PRs" fork f/r "$p|OWNER|User|Okay to merge" expect failure 'fork, approval ties push' '`7ca1cc3`' $p $c '' ''
# 4. Anyone but the owner is ignored, whatever the association.
for a in COLLABORATOR MEMBER CONTRIBUTOR NONE; do
	with_msg "Codex can't review fork PRs" fork f/r "$after|$a|User|Okay to merge" expect failure "fork, $a approval" '`7ca1cc3`' $p $c '' ''
done
# 5. The whole comment must be the phrase; case, whitespace and one trailing . or ! don't matter.
with_msg "Codex can't review fork PRs" fork f/r "$after|OWNER|User|Okay to merge after CI" expect failure 'fork, phrase inside a comment' '`7ca1cc3`' $p $c '' ''
with_msg "Codex can't review fork PRs" fork f/r "$after|OWNER|User|Okay to merge!!" expect failure 'fork, two trailing marks' '`7ca1cc3`' $p $c '' ''
with_msg "Codex can't review fork PRs" fork f/r "$after|OWNER|User|Not okay to merge" expect failure 'fork, negated phrase' '`7ca1cc3`' $p $c '' ''
for b in 'ready for prod!' 'READY FOR PROD.' '  Approved for merge  ' 'Owner approved' 'okay TO merge!'; do
	fork f/r "$after|OWNER|User|$b" expect success "fork, phrase variant: $b" '`7ca1cc3`' $p $c '' ''
done
# 6. A bot with the owner's association (an app acting as the owner) is not the owner.
with_msg "Codex can't review fork PRs" fork f/r "$after|OWNER|Bot|Okay to merge" expect failure 'fork, bot approval' '`7ca1cc3`' $p $c '' ''
# 7. A same-repo PR ignores the phrase: the old failure text, not success.
with_msg 'ask for another' fork o/r "$after|OWNER|User|Okay to merge" expect failure 'same repo, owner approval ignored' '`7ca1cc3`' $p $c '' ''
ROW='| 📝 **Code Review** | ⏳ **Running** | `0b996f7` | Manual request |'
with_msg 'Waiting for Codex' fork o/r "$after|OWNER|User|Okay to merge" expect pending 'same repo, approval, no review' '`7ca1cc3`' $p $c '' ''
ROW=$failed
# The repository names compare without regard to case.
with_msg 'ask for another' fork O/R "$after|OWNER|User|Okay to merge" expect failure 'same repo, other case' '`7ca1cc3`' $p $c '' ''
# 8. Unresolved Codex threads still fail a fork PR, approved or not.
echo "$unresolved" >"$tmp/threads.json"
with_msg 'unresolved Codex thread' fork f/r "$after|OWNER|User|Okay to merge" expect failure 'fork, approval and findings' '`7ca1cc3`' $p $c '' ''
rm -f "$tmp/threads.json"
# 9. A fork PR whose review completed clean is a success as before, with no approval.
ROW=
with_msg 'Codex reviewed 7ca1cc3 with no findings' fork f/r '' expect success 'fork, clean review' '`7ca1cc3`' $p $c '' ''
# 10. A deleted fork (no head repository) counts as a fork, and has no push record to compare an approval with.
ROW=$failed
with_msg "Codex can't review fork PRs" fork null '' expect failure 'null head repo' '`7ca1cc3`' $p $c '' ''
with_msg "Codex can't review fork PRs" fork null "$after|OWNER|User|Okay to merge" expect failure 'null head repo, approval' '`7ca1cc3`' $p $c '' ''
ROW=

# claude-ship #184: a trusted request after a failed review means a retry is running, so the failure no longer
# stands. The failure's time is the summary's last edit (SUMMARY_AT).
ROW=$failed
push=$(ago 7200)
SUMMARY_AT=$(ago 120)
# 1. A failed row with no request after it is a failure, as before.
with_msg 'ask for another' expect failure 'failed, no request' '`7ca1cc3`' "$push" $c '' ''
# ...and one whose only request came before the failure.
with_msg 'ask for another' expect failure 'failed, request before the failure' '`7ca1cc3`' "$push" $c "$(ago 150) OWNER" ''
# 2. An owner request 30 s after the failure is pending, not a failure.
with_msg 'Waiting for Codex' expect pending 'failed, fresh request after' '`7ca1cc3`' "$push" $c "$(ago 90) OWNER" ''
with_msg 'Waiting for Codex' expect pending 'failed, fresh collaborator request after' '`7ca1cc3`' "$push" $c "$(ago 90) COLLABORATOR" ''
# 3. A request in the failure's own second can't be told apart from before it.
tie=$(ago 120)
SUMMARY_AT=$tie
with_msg 'ask for another' expect failure 'failed, request ties the failure' '`7ca1cc3`' "$push" $c "$tie OWNER" ''
# 4. An old request with no sign of life is unacknowledged, so codex-wait.sh can still exit 3.
SUMMARY_AT=$(ago 3600)
with_msg 'acknowledged' expect pending 'failed, request unacknowledged' '`7ca1cc3`' "$push" $c "$(ago 3000) OWNER" ''
# ...but one Codex answered with a receipt is waiting.
with_msg 'Waiting for Codex' expect pending 'failed, request answered' '`7ca1cc3`' "$push" $c "$(ago 3000) OWNER" "receipt $(ago 2900)"
# 5. An outsider's request doesn't count.
SUMMARY_AT=$(ago 120)
with_msg 'ask for another' expect failure 'failed, untrusted request' '`7ca1cc3`' "$push" $c "$(ago 90) NONE" ''
with_msg 'ask for another' expect failure 'failed, member request' '`7ca1cc3`' "$push" $c "$(ago 90) MEMBER" ''
# 6. A fork PR with a request after the failure is pending too; an owner approval still wins.
with_msg 'Waiting for Codex' fork f/r '' expect pending 'fork, failed, request after' '`7ca1cc3`' "$push" $c "$(ago 90) OWNER" ''
with_msg "Codex can't review fork PRs" fork f/r '' expect failure 'fork, failed, no request' '`7ca1cc3`' "$push" $c '' ''
with_msg 'Owner approved 7ca1cc3 for merge (fork PR)' fork f/r "$(ago 3500)|OWNER|User|Okay to merge" expect success 'fork, failed, request and approval' '`7ca1cc3`' "$push" $c "$(ago 90) OWNER" ''
# Unresolved Codex threads still fail it.
echo "$unresolved" >"$tmp/threads.json"
with_msg 'unresolved Codex thread' expect failure 'failed, request after, findings' '`7ca1cc3`' "$push" $c "$(ago 90) OWNER" ''
rm -f "$tmp/threads.json"
SUMMARY_AT=
ROW=

exit $fail
