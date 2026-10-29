#!/bin/sh
# Tests codex-round.sh: a trusted request whose review stalled (Codex's own 👀 still on it after 15 min,
# claude-ship #61) or that Codex never acknowledged (claude-ship #133: old, no bot 👀 now, no bot summary edit,
# receipt or review before the next request) doesn't use a round. The fake gh serves fixtures and applies the
# script's own --jq filters.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
expr=
prev=
for a in "\$@"; do
	[ "\$prev" = --jq ] && expr=\$a
	prev=\$a
done
case "\$*" in
*'/issues/1/comments'*) f=comments.json ;;
*'/pulls/1/reviews'*) f=reviews.json ;;
*'/issues/comments/'*'/reactions'*)
	id=\${*#*issues/comments/}
	f=reactions-\${id%%/*}.json
	;;
*) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
[ -f "$tmp/\$f" ] || echo '[]' >"$tmp/\$f"
jq -r "\$expr" "$tmp/\$f"
EOF
chmod +x "$tmp/bin/gh"
fail=0

# expect <rounds> <label> <requests> [review ages]: requests are lines
# "<id> <age secs> <author_association> <👀 by> [<user type> [<body, \n for a newline>]]",
# where <👀 by> is bot, user or none. The user type defaults to User, the body to "@codex review". A Bot line is
# the bot's own comment: a receipt or summary has its marker in the body (and was last edited when created). The
# review ages are lines of seconds: pull request reviews the bot submitted that long ago.
expect() {
	rm -f "$tmp"/reactions-*.json
	printf '%s\n' "$3" | jq -Rn '[inputs | split(" ") | select(length >= 4)
		| {id:(.[0] | tonumber),author_association:.[2],created_at:(now - (.[1] | tonumber) | todate),
		updated_at:(now - (.[1] | tonumber) | todate),
		user:{type:(.[4] // "User"),login:(if .[4] == "Bot" then "chatgpt-codex-connector[bot]" else "u" end)},
		body:(if length > 5 then .[5:] | join(" ") | gsub("\\\\n"; "\n") else "@codex review" end),reactions:{eyes:(if .[3] == "none" then 0 else 1 end)}}]' >"$tmp/comments.json"
	printf '%s\n' "${4:-}" | jq -Rn '[inputs | select(length > 0) | {user:{login:"chatgpt-codex-connector[bot]"},
		submitted_at:(now - tonumber | todate)}]' >"$tmp/reviews.json"
	printf '%s\n' "$3" | while read -r id _ _ by _; do
		case $by in
		bot) login='chatgpt-codex-connector[bot]' ;;
		user) login=u ;;
		*) continue ;;
		esac
		jq -n --arg l "$login" '[{content:"eyes",user:{login:$l}}]' >"$tmp/reactions-$id.json"
	done
	out=$(PATH=$tmp/bin:$PATH sh "$root/skills/ship/codex-round.sh" 1 o/r 2>&1)
	if [ "$out" != "$1" ]; then
		echo "FAIL (want $1): $2"
		echo "  $out"
		fail=1
	fi
}

# A clean review leaves a receipt comment after its request: receipt <id> <age secs>.
receipt() { echo "$1 $2 NONE none Bot <!--codex-review-receipt:v1-->"; }

expect 0 'no requests' ''
expect 2 'two finished requests' "1 3600 OWNER none
$(receipt 11 3500)
2 600 COLLABORATOR none
$(receipt 12 500)"
expect 0 'outsiders do not count' '1 3600 NONE none
2 600 MEMBER none'
# A stalled request is skipped; its retry counts.
expect 1 'stalled then retried' "1 3600 OWNER bot
2 600 OWNER none
$(receipt 12 500)"
# A review still running (under 15 min) counts.
expect 1 'running request' '1 400 OWNER bot'
# Anyone can react: someone else's 👀 is neither a stall nor an acknowledgement.
expect 1 'eyes from a user' "1 3600 OWNER user
$(receipt 11 3500)"
expect 0 'eyes from a user only' '1 3600 OWNER user'
# A request is what codex-status.sh counts: a non-bot comment opening with `@codex review` as a word.
expect 0 'not a request: @codex reviewer' '1 3600 OWNER none User @codex reviewer notes'
expect 0 'not a request: bot author' '1 3600 OWNER none Bot @codex review'
expect 2 'request with text after a space and after a newline' "1 3600 OWNER none User @codex review please
$(receipt 11 3500)
2 600 OWNER none User @codex review\nthanks
$(receipt 12 500)"

# claude-ship #133: a request Codex never picked up (no bot 👀, nothing from the bot before the next request)
# uses no round once it is 5 min old.
expect 0 'never acknowledged' '1 3600 OWNER none'
expect 1 'unacknowledged but young' '1 240 OWNER none'
expect 0 'unacknowledged at 6 min' '1 360 OWNER none'
# The 👀 is removed when a review finishes, so it is a sign of life only while it is there; a review, a receipt or
# a summary edit after the request show that it ran.
expect 1 'review after the request' '1 3600 OWNER none' 3000
expect 1 'receipt after the request' "1 3600 OWNER none
$(receipt 11 3000)"
expect 1 'summary edit after the request' '1 3600 OWNER none
11 100 NONE none Bot <!--codex-pull-request-review-summary-->'
expect 0 'review before the request' '1 3600 OWNER none' 5000
expect 0 'receipt of an earlier request' "$(receipt 11 5000)
1 3600 OWNER none"
# Activity counts for the request it follows, not for an older one: request 1 never ran, request 2 did.
expect 1 'unacked then acknowledged' "1 3600 OWNER none
2 1000 OWNER none
$(receipt 12 500)"
expect 0 'unacked then unacked' '1 3600 OWNER none
2 1000 OWNER none'
# The window of an acknowledged request ends at the next one, so the retry's stall is skipped on its own.
expect 1 'acknowledged then retried while stalled' "1 3600 OWNER none
$(receipt 11 3000)
2 2000 OWNER bot"

exit $fail
