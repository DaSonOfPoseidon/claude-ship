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
	# One line per call: its endpoint (the repos/ path, or graphql).
	case \$a in repos/*) echo "\$a" >>"$tmp/calls" ;; esac
done
case "\$*" in *graphql*) echo graphql >>"$tmp/calls" ;; esac
case "\$*" in
*'graphql'*)
	# No unresolved threads unless a test writes threads.json (the response's shape, not the script's filter);
	# fail.threads still makes the call fail.
	[ -f "$tmp/threads.json" ] || [ -f "$tmp/fail.threads" ] || exit 0
	f=threads
	;;
*'/activity'*) f=activity ;;
*'/issues/comments/'*'/reactions'*)
	# Only asked for when a request is old and nothing else shows Codex started: a missing file is a test failure.
	[ -f "$tmp/reactions.json" ] || { echo "unexpected reactions call: \$*" >&2; exit 1; }
	f=reactions
	;;
*'/statuses/'*)
	# Setting the status: log the state and context sent, and succeed.
	st=; cx=
	for a in "\$@"; do
		case \$a in state=*) st=\${a#state=} ;; context=*) cx=\${a#context=} ;; esac
	done
	echo "statuses state=\$st context=\$cx" >>"$tmp/calls"
	exit 0
	;;
*'/pulls/1/reviews'*) f=reviews ;;
*'/pulls/1'*) f=pr ;;
*'/issues/1/comments'*) f=comments ;;
*) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
# A test makes one endpoint fail by creating fail.<name> (pr, comments, reviews, activity, threads or reactions):
# empty, it fails every call; holding a number N, it fails the next N calls and then lets them through.
if [ -f "$tmp/fail.\$f" ]; then
	n=\$(cat "$tmp/fail.\$f")
	if [ -z "\$n" ]; then
		echo "gh: HTTP 502 (\$f)" >&2
		exit 1
	elif [ "\$n" -gt 0 ]; then
		echo \$((n - 1)) >"$tmp/fail.\$f"
		echo "gh: HTTP 502 (\$f)" >&2
		exit 1
	fi
fi
jq -r "\$expr" "$tmp/\$f.json"
EOF
chmod +x "$tmp/bin/gh"
fail=0

# check <state> <label>: runs the script on the fixtures in $tmp.
check() {
	: >"$tmp/calls"
	out=$(REPO=o/r DRY_RUN=1 GITHUB_ACTIONS='' PATH=$tmp/bin:$PATH sh "$root/scripts/codex-status.sh" 1 2>&1)
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
	# A review line is "review <time> [head|other]": the commit it reviewed (none by default); a time of "null"
	# is a review nobody has submitted yet.
	printf '%s\n' "$7" | jq -Rn --arg s "$sha" '[inputs | split(" ") | select(.[0] == "review")
		| {user:{login:"chatgpt-codex-connector[bot]"},submitted_at:(if .[1] == "null" then null else .[1] end),
		commit_id:(if .[2] == "head" then $s elif .[2] == "other" then "0b996f7000000000000000000000000000000000" else null end)}]' >"$tmp/reviews.json"
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
		# default), STATE_ANY its has_any_findings (true, false or null; left out by default), AGE how many seconds ago
			# it was edited and SUMMARY_AT the exact edit time (overrides AGE).
		jq -n --arg r "$row" --arg st "$STATE" --arg ss "${STATE_SHA:-}" --arg any "${STATE_ANY:-}" --argjson age "$AGE" --arg at "${SUMMARY_AT:-}" '[{user:{login:"chatgpt-codex-connector[bot]",type:"Bot"},
			author_association:"NONE",created_at:"2026-10-21T14:00:00Z",updated_at:(if $at != "" then $at else (now - $age | todate) end),
			body:("<!-- codex-pull-request-review-summary -->\n"
				+ (if $st == "" then "" else "<!-- codex-review-state:v1 {\"code_review\":{\"commit_sha\":" + (if $ss == "" then "null" else "\"" + $ss + "\"" end) + ",\"status\":\"" + $st + "\"" + (if $any == "" then "" else ",\"has_any_findings\":" + $any end) + "}} -->\n" end)
				+ $r)}]'
	} | jq -s 'add' >"$tmp/comments.json"
	# RAW_COMMENTS replaces the generated comments (a test of its own comments).
	[ -z "${RAW_COMMENTS:-}" ] || printf '%s\n' "$RAW_COMMENTS" >"$tmp/comments.json"
	check "$1" "$2"
}

# with_msg <text> expect …: also requires <text> in the output (a prefix assignment may persist in some shells).
WANT_MSG=
STATE=
STATE_ANY=
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

# Shared by the sections below: an owner approval's time after the push and one before it, and the response of one
# unresolved Codex thread.
after='2026-10-21T15:30:00Z'
before='2026-10-21T15:20:00Z'
unresolved='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"}}]}}]}}}}}'

# claude-ship #229: Codex can mark its summary completed (with has_any_findings: true in the state JSON) before the
# review with the findings posts, so a completed row alone isn't a success yet. The head p is pushed at 15:25:00, the
# trusted request r1 is at 15:26:03 and the row says completed at 15:41:21.
# summary <state> <commit it names> <has_any_findings> expect …: sets the summary's state JSON for one case.
summary() {
	STATE=$1
	STATE_SHA=$2
	STATE_ANY=$3
	shift 3
	"$@"
	STATE=
	STATE_SHA=
	STATE_ANY=
}
posting='waiting for its review to post'
h='`7ca1cc3`'
# 1. Findings reported, no review posted yet: pending, with a message of its own.
with_msg "Codex finished 7ca1cc3 with findings; $posting" summary completed "$sha" true expect pending 'findings, no review yet' "$h" $p $c "$r1" ''
# ...a receipt isn't a review...
with_msg "$posting" summary completed "$sha" true expect pending 'findings, only a receipt' "$h" $p $c "$r1" "$m"
# ...and a name-less row waits the same way.
with_msg "$posting" summary completed "$sha" true expect pending 'findings, blank row, no review' '—' $p $c "$r1" "$m"
# 2. The review for the head, after the request, ends the wait: success while its threads are resolved...
summary completed "$sha" true expect success 'findings, review posted' "$h" $p $c "$r1" 'review 2026-10-21T15:41:10Z head'
summary completed "$sha" true expect success 'findings, blank row, review posted' '—' $p $c "$r1" 'review 2026-10-21T15:41:10Z head'
# ...and failure while a thread is open (an open thread outranks it, unless the request for the head is still
# unanswered, #282: then the review is still to come and the status waits for it).
echo "$unresolved" >"$tmp/threads.json"
with_msg 'unresolved Codex thread' summary completed "$sha" true expect failure 'findings, review posted, thread open' "$h" $p $c "$r1" 'review 2026-10-21T15:41:10Z head'
with_msg "$posting" summary completed "$sha" true expect pending 'findings, no review, thread open' "$h" $p $c "$r1" ''
rm -f "$tmp/threads.json"
# 3. A review of the head from before the latest request (a re-review of the same head) doesn't answer it...
with_msg "$posting" summary completed "$sha" true expect pending 'findings, review before the request' "$h" $p $c "$r1
2026-10-21T15:35:00Z OWNER" 'review 2026-10-21T15:30:00Z head'
# ...nor does one from before the push...
with_msg "$posting" summary completed "$sha" true expect pending 'findings, review before the push' "$h" $p $c '' 'review 2026-10-21T15:20:00Z head'
# ...but one in the second of the request or the push does (at or after, to the second)...
summary completed "$sha" true expect success 'findings, review in the request second' "$h" $p $c "$r1" 'review 2026-10-21T15:26:03Z head'
summary completed "$sha" true expect success 'findings, review in the push second, no request' "$h" $p $c '' 'review 2026-10-21T15:25:00Z head'
# ...and with no request at all (an automatic review) the push is the line.
summary completed "$sha" true expect success 'findings, automatic review after the push' "$h" $p $c '' 'review 2026-10-21T15:41:10Z head'
# 4. A review of another commit doesn't count, and neither does one nobody has submitted yet.
with_msg "$posting" summary completed "$sha" true expect pending 'findings, review of another commit' "$h" $p $c "$r1" 'review 2026-10-21T15:41:10Z other'
with_msg "$posting" summary completed "$sha" true expect pending 'findings, review with no commit' "$h" $p $c "$r1" 'review 2026-10-21T15:41:10Z'
with_msg "$posting" summary completed "$sha" true expect pending 'findings, unsubmitted review' "$h" $p $c "$r1" 'review null head'
# One review on the head after the request is enough, whatever else is there.
summary completed "$sha" true expect success 'findings, old and new reviews' "$h" $p $c "$r1" 'review 2026-10-21T15:00:00Z head
review 2026-10-21T15:41:10Z head'
# 5. No findings reported, or no way to tie the state to the head: nothing changes.
summary completed "$sha" false expect success 'no findings reported' "$h" $p $c "$r1" ''
summary completed "$sha" null expect success 'findings null' "$h" $p $c "$r1" ''
summary completed "$sha" '' expect success 'findings key missing' "$h" $p $c "$r1" ''
summary completed 0b996f7000000000000000000000000000000000 true expect success 'state of another commit' "$h" $p $c "$r1" ''
summary completed '' true expect success 'state names no commit' "$h" $p $c "$r1" ''
summary 'x"}' '' true expect success 'unreadable state' "$h" $p $c "$r1" ''
# 6. #231: the review never posts. With the summary's last edit, the latest request and the push all older than
# CODEX_STALL_SECS (900), the status stays pending but says so (codex-wait.sh exits 3 on it, so the loop asks again).
stalled_posting='review never posted (stalled, no update in 15 min); ask again with @codex review'
AGE=960
with_msg "Codex finished 7ca1cc3 with findings but its $stalled_posting" summary completed "$sha" true expect pending 'findings, no review, 16 min old' "$h" $p $c "$r1" ''
with_msg "$stalled_posting" summary completed "$sha" true expect pending 'findings, blank row, no review, 16 min old' '—' $p $c "$r1" "$m"
# ...a fresh summary edit (14 min) is still the plain wait...
AGE=840
with_msg "$posting" summary completed "$sha" true expect pending 'findings, no review, 14 min old' "$h" $p $c "$r1" ''
# ...and so is an old summary with a recent request or push (a re-review in flight).
AGE=960
with_msg "$posting" summary completed "$sha" true expect pending 'findings, recent request' "$h" $p $c "$r1
$(jq -nr 'now - 60 | todate') OWNER" ''
# A review that did post ends it, however old the summary is (success while its threads are resolved)...
summary completed "$sha" true expect success 'findings, review posted, 16 min old' "$h" $p $c "$r1" 'review 2026-10-21T15:41:10Z head'
# ...and an open thread still fails first, once the request is answered (an unanswered one keeps it stalled, #282).
echo "$unresolved" >"$tmp/threads.json"
with_msg 'unresolved Codex thread' summary completed "$sha" true expect failure 'findings, review posted, thread open, 16 min old' "$h" $p $c "$r1" 'review 2026-10-21T15:41:10Z head'
with_msg "$stalled_posting" summary completed "$sha" true expect pending 'findings, thread open, 16 min old' "$h" $p $c "$r1" ''
rm -f "$tmp/threads.json"
AGE=0
# A state that isn't completed adds nothing here (a running state of the head is a stall, above).
summary running "$sha" true expect success 'running state, completed row' "$h" $p $c "$r1" ''
# (An approved fork PR goes through the owner-approval branch first: see the fork cases below.)
# A row that isn't completed after the push is never a success, with or without the state.
with_msg 'Waiting for Codex' summary completed "$sha" true expect pending 'findings, other commit named' '`0b996f7`' $p $c "$r1" ''

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
# 11. #229: an owner's approval outranks a completed review whose findings haven't posted.
with_msg 'Owner approved 7ca1cc3 for merge (fork PR)' summary completed "$sha" true fork f/r "$after|OWNER|User|Okay to merge" expect success 'fork, approved, findings, no review' '`7ca1cc3`' $p $c '' ''
# ...and without an approval a fork PR waits for the review like any other.
with_msg 'waiting for its review to post' summary completed "$sha" true fork f/r '' expect pending 'fork, findings, no review' '`7ca1cc3`' $p $c '' ''

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
# Unresolved Codex threads still fail it once the request is answered; while it waits for Codex, the retry is
# what the status says (#282).
echo "$unresolved" >"$tmp/threads.json"
with_msg 'unresolved Codex thread' expect failure 'failed, request answered, findings' '`7ca1cc3`' "$push" $c "$(ago 90) OWNER" "receipt $(ago 60)"
with_msg 'Waiting for Codex' expect pending 'failed, request after, findings' '`7ca1cc3`' "$push" $c "$(ago 90) OWNER" ''
rm -f "$tmp/threads.json"
SUMMARY_AT=
ROW=

# claude-ship #282: an unanswered request for the head (made at or after its push, with no receipt or review of
# Codex's after it) outranks open threads from an earlier review: the verdict is the pending one, so
# codex-request.sh waits for the running review instead of asking again. The threads count again once it answers.
echo "$unresolved" >"$tmp/threads.json"
ROW='| 📝 **Code Review** | ⏳ **Running** | `7ca1cc3` | Manual request |'
# The summary was edited after the request (a sign of life): plain wait.
with_msg 'Waiting for Codex to review 7ca1cc3' expect pending 'threads, request for the head, summary edited' '`7ca1cc3`' $p $c "$r1" ''
# Codex's own 👀 on the request, summary older than it: still plain wait.
SUMMARY_AT=2026-10-21T15:20:00Z
echo '[{"content":"eyes","user":{"login":"chatgpt-codex-connector[bot]"}}]' >"$tmp/reactions.json"
EYES=1
with_msg 'Waiting for Codex to review 7ca1cc3' expect pending 'threads, request for the head, 👀' '`7ca1cc3`' $p $c "$r1" ''
rm -f "$tmp/reactions.json"
EYES=
# No sign of life from Codex since the request: not acknowledged (codex-wait.sh exits 3 and the loop asks again).
with_msg 'acknowledged' expect pending 'threads, request for the head, nothing from Codex' '`7ca1cc3`' $p $c "$r1" ''
# A running review that is quiet: stalled.
STATE=running
with_msg 'stalled' expect pending 'threads, request for the head, stalled' '`7ca1cc3`' $p $c "$r1" ''
STATE=
SUMMARY_AT=
# A request tied with the push belongs to this head.
with_msg 'Waiting for Codex to review 7ca1cc3' expect pending 'threads, request in the push second' '`7ca1cc3`' $p $c "$p OWNER" ''
# An untrusted request is no request.
with_msg 'unresolved Codex thread' expect failure 'threads, untrusted request' '`7ca1cc3`' $p $c '2026-10-21T15:26:03Z NONE' ''
# A review after the request answers it: the threads fail it, as before.
with_msg 'unresolved Codex thread' expect failure 'threads, request answered by a review' '`7ca1cc3`' $p $c "$r1" 'review 2026-10-21T15:41:10Z head'
# ...and so does a receipt.
with_msg 'unresolved Codex thread' expect failure 'threads, request answered by a receipt' '`7ca1cc3`' $p $c "$r1" "$m"
# A review that failed after the request answers it with a failure, not a wait (Codex round 1 on #292): the
# retry is the user's to ask for, so the verdict is the failed one, not "Waiting" (which would block a retry).
ROW=$failed
SUMMARY_AT=$(ago 120)
with_msg 'ask for another' expect failure 'threads, request failed' '`7ca1cc3`' "$(ago 7200)" $c "$(ago 150) OWNER" ''
# ...a retry after the failure is a wait again...
with_msg 'Waiting for Codex' expect pending 'threads, request after failure' '`7ca1cc3`' "$(ago 7200)" $c "$(ago 90) OWNER" ''
# ...and on a fork PR the failure keeps its own message.
with_msg "Codex can't review fork PRs" fork f/r '' expect failure 'threads, fork, request failed' '`7ca1cc3`' "$(ago 7200)" $c "$(ago 150) OWNER" ''
SUMMARY_AT=
ROW='| 📝 **Code Review** | ⏳ **Running** | `7ca1cc3` | Manual request |'
# No request since the head's push (it was for an earlier head): the threads fail it.
with_msg 'unresolved Codex thread' expect failure 'threads, request before the push' '`7ca1cc3`' 2026-10-21T15:30:00Z $c "$r1" ''
with_msg 'unresolved Codex thread' expect failure 'threads, no request' '`7ca1cc3`' $p $c '' ''
rm -f "$tmp/threads.json"
ROW=

# claude-ship #111: one run reads each endpoint at most once, so every value comes from one snapshot (a push or an
# edit between two reads would pair values from different moments). The fake gh logs one line per call.
# count <endpoint>: how many calls the last run made to repos/o/r/<endpoint> (graphql: its own).
count() { grep -c -x "$1" "$tmp/calls" || true; }
# reads <label> <max reviews>: the last run read the PR once, the comments once and the reviews at most <max> times.
reads() {
	for ep in repos/o/r/pulls/1 repos/o/r/issues/1/comments; do
		if [ "$(count "$ep")" -ne 1 ]; then
			echo "FAIL: $(count "$ep") reads of $ep (want 1): $1"
			fail=1
		fi
	done
	if [ "$(count repos/o/r/pulls/1/reviews)" -gt "$2" ]; then
		echo "FAIL: $(count repos/o/r/pulls/1/reviews) reads of the reviews (want at most $2): $1"
		fail=1
	fi
}
# A normal run: the named commit needs no review list at all...
expect success 'reads: commit named' '`7ca1cc3`' $p $c '' ''
reads 'commit named' 0
# ...a blank row reads receipts and reviews to find the one that follows the request...
expect success 'reads: blank row' '—' $p $c "$r1" "$m"
reads 'blank row' 1
# ...a request nobody acknowledged looks at both again...
AGE=7200
with_msg 'acknowledged' expect pending 'reads: unacknowledged' "$other" "$pushed" $c "$(ago 360) OWNER" ''
reads 'unacknowledged' 1
AGE=0
# ...so does findings that are still posting, with an open request and the threads (three paths, one read).
echo "$unresolved" >"$tmp/threads.json"
ROW='| 📝 **Code Review** | ⏳ **Running** | `7ca1cc3` | Manual request |'
SUMMARY_AT=2026-10-21T15:20:00Z
with_msg 'acknowledged' expect pending 'reads: open request' '`7ca1cc3`' $p $c "$r1" ''
reads 'open request' 1
if [ "$(count graphql)" -ne 1 ]; then
	echo "FAIL: $(count graphql) threads reads (want 1): open request"
	fail=1
fi
SUMMARY_AT=
rm -f "$tmp/threads.json"
ROW=
summary completed "$sha" true expect success 'reads: posted findings' "$h" $p $c "$r1" 'review 2026-10-21T15:41:10Z head'
reads 'posted findings' 1
# A fork PR also reads the owner's approvals from the same comments.
fork f/r "$after|OWNER|User|Okay to merge" expect success 'reads: fork approval' '`7ca1cc3`' $p $c '' ''
reads 'fork approval' 0
ROW=$failed
with_msg "Codex can't review fork PRs" fork f/r '' expect failure 'reads: fork, failed' '`7ca1cc3`' $p $c '' ''
reads 'fork failed' 0
ROW=

# A failed read is retried (#338), and a read that still fails stops the run before any status is set, whichever
# endpoint it was (set -e on each read). Run as in Actions, which is the path that posts. The sleep between tries is 0.
CODEX_STATUS_RETRY_SLEEP=0
export CODEX_STATUS_RETRY_SLEEP
# fixtures <endpoint>: the state in which the script reads that endpoint. A blank row with a request reads the reviews
# too; the reactions are read only for a request that is old, with a 👀 on it and nothing else from Codex to see.
EMPTY_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
fixtures() {
	rm -f "$tmp/reactions.json"
	echo "$EMPTY_THREADS" >"$tmp/threads.json"
	if [ "$1" = reactions ]; then
		echo '[{"content":"eyes","user":{"login":"chatgpt-codex-connector[bot]"}}]' >"$tmp/reactions.json"
		AGE=7200
		EYES=1
		expect pending 'reads: fixtures for the reactions' "$other" "$pushed" $c "$(ago 360) OWNER" ''
		AGE=0
		EYES=0
	else
		expect success 'reads: fixtures for the failing reads' '—' $p $c "$r1" "$m"
	fi
}
# call_re <endpoint>: the call log's line for it.
call_re() {
	case $1 in
	pr) echo '^repos/o/r/pulls/1$' ;;
	reviews) echo '^repos/o/r/pulls/1/reviews$' ;;
	comments) echo '^repos/o/r/issues/1/comments$' ;;
	activity) echo '^repos/o/r/activity?' ;;
	threads) echo '^graphql$' ;;
	reactions) echo '^repos/o/r/issues/comments/777/reactions$' ;;
	esac
}
# what <endpoint>: how the error names the read.
what() {
	case $1 in
	pr) echo 'the pull request' ;;
	activity) echo 'push activity' ;;
	threads) echo 'review threads' ;;
	*) echo "$1" ;;
	esac
}
# run_in_actions <endpoint>: runs the script as in Actions; sets rc, out (stdout), err (stderr) and attempts (the
# calls to that endpoint).
run_in_actions() {
	: >"$tmp/calls"
	out=$(REPO=o/r GITHUB_ACTIONS=true PATH=$tmp/bin:$PATH sh "$root/scripts/codex-status.sh" 1 2>"$tmp/err")
	rc=$?
	err=$(cat "$tmp/err")
	attempts=$(grep -c "$(call_re "$1")" "$tmp/calls")
}
for ep in pr comments reviews activity threads reactions; do
	fixtures "$ep"
	# Always failing: three tries, then a failed run that says which read it was and what gh said, and no status.
	: >"$tmp/fail.$ep"
	run_in_actions "$ep"
	[ "$rc" -ne 0 ] || {
		echo "FAIL: the run succeeded with $ep failing"
		fail=1
	}
	case $out in
	*success:* | *pending:* | *failure:*)
		echo "FAIL: a state was printed with $ep failing: $out"
		fail=1
		;;
	esac
	if grep -q statuses "$tmp/calls"; then
		echo "FAIL: a status was posted with $ep failing"
		fail=1
	fi
	case $err in
	*"codex-status: reading $(what "$ep") for #1 failed after 3 tries: gh: HTTP 502 ($ep)"*) ;;
	*)
		echo "FAIL: the error doesn't name the $ep read and gh's message: $err"
		fail=1
		;;
	esac
	[ "$attempts" -eq 3 ] || {
		echo "FAIL: $ep always failing was tried $attempts times, not 3"
		fail=1
	}
	# Failing once, or twice, then answering: the normal result, after 2 or 3 tries.
	for n in 1 2; do
		echo "$n" >"$tmp/fail.$ep"
		run_in_actions "$ep"
		[ "$rc" -eq 0 ] || {
			echo "FAIL: the run failed with $ep failing $n time(s): $err"
			fail=1
		}
		case $out in
		success:* | pending:* | failure:*) ;;
		*)
			echo "FAIL: no state line with $ep failing $n time(s): $out"
			fail=1
			;;
		esac
		grep -q 'statuses state=' "$tmp/calls" || {
			echo "FAIL: no status posted with $ep failing $n time(s)"
			fail=1
		}
		[ "$attempts" -eq $((n + 1)) ] || {
			echo "FAIL: $ep failing $n time(s) was tried $attempts times, not $((n + 1))"
			fail=1
		}
	done
	rm -f "$tmp/fail.$ep"
done
# A read that succeeds is made once, an empty answer included (an empty list is data, not a failure).
fixtures reviews
run_in_actions reviews
[ "$attempts" -eq 1 ] || {
	echo "FAIL: a read that succeeded was tried $attempts times"
	fail=1
}
rm -f "$tmp/threads.json" "$tmp/reactions.json"

# The summary's body and its edit time come from one comment, however the body is written: a newline, a tab and a
# quote inside it must not move the row or the time (the body goes through the tagged line as JSON).
okrow='| 📝 **Code Review** | ✅ **Completed** <relative-time datetime="2026-10-21T15:41:21Z">x</relative-time> | `7ca1cc3` | Manual request |'
ROW=$(printf 'A "quoted" line\twith a tab\nand a second line\n%s\nand a last one' "$okrow")
with_msg 'Codex reviewed 7ca1cc3 with no findings' expect success 'summary body with newline, tab and quote' '`7ca1cc3`' $p $c '' ''
# ...and the edit time is the same comment's: a running review whose summary was edited an hour ago is stalled.
ROW=$(printf 'A "quoted" line\twith a tab\n| 📝 **Code Review** | ⏳ **Running** | `7ca1cc3` | Manual request |\nlast')
STATE=running
STATE_SHA=$sha
SUMMARY_AT=$(ago 3600)
with_msg 'stalled' expect pending 'summary body with newline, edit time kept' '`7ca1cc3`' $p $c '' ''
STATE=
STATE_SHA=
SUMMARY_AT=
ROW=

# One comment that several filters select (a login that is the bot's but typed User, from the owner, whose body is a
# request, a receipt and a summary at once) yields every line the separate filters did.
both() {
	jq -n --arg r "$1" --arg c "$2" --arg u "$3" '[{id:999,user:{login:"chatgpt-codex-connector[bot]",type:"User"},author_association:"OWNER",
		created_at:$c,updated_at:$u,reactions:{eyes:0},
		body:("@codex review\n<!-- codex-pull-request-review-summary -->\n" + $r + "\ncodex-review-receipt")}]'
}
# As a request (threads open, the request for the head unanswered by anything strictly after it): pending, not failure.
echo "$unresolved" >"$tmp/threads.json"
RAW_COMMENTS=$(both '' "$(ago 3000)" "$(ago 3600)")
with_msg 'Waiting for Codex' expect pending 'one comment: request, threads open' '`7ca1cc3`' "$(ago 3500)" $c '' ''
rm -f "$tmp/threads.json"
# As a receipt: it answers its own request (the same second counts as a sign of life), so the request is acknowledged.
with_msg 'Waiting for Codex to review' expect pending 'one comment: request answered by its receipt' '`7ca1cc3`' "$(ago 3500)" $c '' ''
# As a summary: a running state in its body, edited long ago, is a stall.
RAW_COMMENTS=$(both '<!-- codex-review-state:v1 {"code_review":{"commit_sha":"'"$sha"'","status":"running"}} -->' "$(ago 3000)" "$(ago 3600)")
with_msg 'stalled' expect pending 'one comment: summary stalled' '`7ca1cc3`' "$(ago 3500)" $c '' ''
RAW_COMMENTS=

# Where the status is set (#291): only in GitHub Actions (GITHUB_ACTIONS is exactly true) or with CODEX_STATUS_SET=1,
# never under DRY_RUN=1. Anywhere else the script prints the status and says so on stderr, and sets nothing (run by
# hand, it would post as the user and block the merge). The fixtures are the failing reads' success fixture above.
# run_status <VAR=value>...: runs the script with those variables, stdout in $out, stderr in $err, calls in $tmp/calls.
run_status() {
	: >"$tmp/calls"
	out=$(env REPO=o/r PATH="$tmp/bin:$PATH" "$@" sh "$root/scripts/codex-status.sh" 1 2>"$tmp/err")
	rc=$?
	err=$(cat "$tmp/err")
}
# want_calls <label> <count>: the number of statuses calls.
want_calls() {
	n=$(grep -c '^statuses ' "$tmp/calls")
	if [ "$n" -ne "$2" ]; then
		echo "FAIL: $1: $n statuses calls (want $2)"
		fail=1
	fi
}
want_exit() {
	if [ "$rc" -ne 0 ]; then
		echo "FAIL: $1: exit $rc"
		fail=1
	fi
}
note='not in GitHub Actions, so the status was printed, not set'
expect success 'set: fixture' '—' $p $c "$r1" "$m"
run_status DRY_RUN=1 GITHUB_ACTIONS=
dry_out=$out
case $dry_out in "success: "*" ($sha)") ;; *) echo "FAIL: set: dry run output: $dry_out"; fail=1 ;; esac

# (a) by hand: the dry run's line, a note on stderr, nothing set, exit 0
for ga in '' false True 1; do
	run_status GITHUB_ACTIONS="$ga"
	want_exit "set: GITHUB_ACTIONS=$ga"
	want_calls "set: GITHUB_ACTIONS=$ga" 0
	[ "$out" = "$dry_out" ] || { echo "FAIL: set: GITHUB_ACTIONS=$ga printed: $out"; fail=1; }
	case $err in *"$note"*) ;; *) echo "FAIL: set: GITHUB_ACTIONS=$ga stderr lacks the note: $err"; fail=1 ;; esac
done
# (b) in Actions: one call with the state and context, the state and description on stdout
run_status GITHUB_ACTIONS=true
want_exit 'set: in Actions'
want_calls 'set: in Actions' 1
grep -q '^statuses state=success context=codex-review$' "$tmp/calls" || { echo "FAIL: set: in Actions sent: $(cat "$tmp/calls")"; fail=1; }
[ "$out" = "${dry_out% ($sha)}" ] || { echo "FAIL: set: in Actions printed: $out"; fail=1; }
[ -z "$err" ] || { echo "FAIL: set: in Actions wrote to stderr: $err"; fail=1; }
# (c) CODEX_STATUS_SET=1 by hand: one call, no note
run_status GITHUB_ACTIONS= CODEX_STATUS_SET=1
want_exit 'set: override'
want_calls 'set: override' 1
[ -z "$err" ] || { echo "FAIL: set: override wrote to stderr: $err"; fail=1; }
# (d) DRY_RUN=1 wins, in Actions or with the override
run_status DRY_RUN=1 GITHUB_ACTIONS=true CODEX_STATUS_SET=1
want_calls 'set: dry run in Actions' 0
[ "$out" = "$dry_out" ] || { echo "FAIL: set: dry run in Actions printed: $out"; fail=1; }
# (e) a dry run by hand says nothing on stderr
run_status DRY_RUN=1 GITHUB_ACTIONS=
[ -z "$err" ] || { echo "FAIL: set: dry run by hand wrote to stderr: $err"; fail=1; }

exit $fail
