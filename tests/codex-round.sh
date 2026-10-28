#!/bin/sh
# Tests codex-round.sh: a trusted request whose review stalled (Codex's own 👀 still on it after 15 min,
# openai/codex#55890, claude-ship #61) doesn't use a round. The fake gh below serves fixtures and applies
# the script's own --jq filters with real jq, so the filters are tested too.
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

# expect <rounds> <label> <requests>: requests are lines "<id> <age secs> <author_association> <👀 by>",
# where <👀 by> is bot, user or none.
expect() {
	rm -f "$tmp"/reactions-*.json
	printf '%s\n' "$3" | jq -Rn '[inputs | split(" ") | select(length == 4)
		| {id:(.[0] | tonumber),author_association:.[2],created_at:(now - (.[1] | tonumber) | todate),
		body:"@codex review",reactions:{eyes:(if .[3] == "none" then 0 else 1 end)}}]' >"$tmp/comments.json"
	printf '%s\n' "$3" | while read -r id _ _ by; do
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

expect 0 'no requests' ''
expect 2 'two finished requests' '1 3600 OWNER none
2 600 COLLABORATOR none'
expect 0 'outsiders do not count' '1 3600 NONE none
2 600 MEMBER none'
# A stalled request is skipped; its retry counts.
expect 1 'stalled then retried' '1 3600 OWNER bot
2 600 OWNER none'
# A review still running (under 15 min) counts.
expect 1 'running request' '1 300 OWNER bot'
# Anyone can react: someone else's 👀 doesn't make a stall.
expect 1 'eyes from a user' '1 3600 OWNER user'

exit $fail
