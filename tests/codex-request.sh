#!/bin/sh
# Tests codex-request.sh: it posts `@codex review` once GitHub shows the wanted commit as the PR's head (the
# given sha, else this checkout's HEAD), and not a second time while a request for that head is still out.
# The fake gh serves fixtures, applies the script's own --jq filters, and records posted comments.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/sleep" <<EOF
#!/bin/sh
echo "\$1" >>"$tmp/slept"
EOF
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
expr=
prev=
for a in "\$@"; do
	[ "\$prev" = --jq ] && expr=\$a
	prev=\$a
done
case "\$*" in
'pr view '*)
	# One head per call; the last one repeats.
	head -1 "$tmp/heads"
	if [ "\$(wc -l <"$tmp/heads")" -gt 1 ]; then
		sed -n '2,\$p' "$tmp/heads" >"$tmp/heads.new"
		mv "$tmp/heads.new" "$tmp/heads"
	fi
	exit 0
	;;
'pr comment '*)
	echo "\$*" >>"$tmp/posted"
	exit 0
	;;
'api repos/o/r/pulls/1 '*) f=pull.json ;;
*'repos/o/r/activity?ref='*) f=activity.json ;;
*'repos/o/r/issues/1/comments'*) f=comments.json ;;
*'repos/o/r/pulls/1/reviews'*) f=reviews.json ;;
*) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
jq -r "\$expr" "$tmp/\$f"
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/sleep"
fail=0

# The script runs from a copy next to the real codex-round.sh and a fake codex-status.sh, which prints the line in
# status.out and exits with status.rc, and records how it was called.
mkdir -p "$tmp/skill"
cp "$root/skills/ship/codex-request.sh" "$root/skills/ship/codex-round.sh" "$tmp/skill/"
cat >"$tmp/skill/codex-status.sh" <<EOF
#!/bin/sh
echo "DRY_RUN=\${DRY_RUN:-} REPO=\${REPO:-} HEAD_SHA=\${HEAD_SHA:-} \$*" >>"$tmp/status.calls"
cat "$tmp/status.out"
exit \$(cat "$tmp/status.rc")
EOF
chmod +x "$tmp/skill/codex-status.sh"

# A checkout whose HEAD is not the PR's.
git init -q "$tmp/repo"
git -C "$tmp/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
local_head=$(git -C "$tmp/repo" rev-parse HEAD)
sha=1111111111111111111111111111111111111111
old=2222222222222222222222222222222222222222
bot='chatgpt-codex-connector[bot]'

# setup <heads> <push age secs or -> <comments>: <comments> lines are "<age secs> <author_association>"; a
# push age of - means no push recorded. Receipts and reviews go in with answer.
setup() {
	rm -f "$tmp/posted" "$tmp/slept" "$tmp/status.calls"
	status_is "pending: Waiting for Codex to review 1111111 ($sha)"
	printf '%s\n' "$1" >"$tmp/heads"
	echo '{"head":{"repo":{"full_name":"o/r"},"ref":"b"}}' >"$tmp/pull.json"
	if [ "$2" = - ]; then
		echo '[]' >"$tmp/activity.json"
	else
		jq -n --argjson a "$2" --arg s "$sha" '[{activity_type:"push",after:$s,timestamp:(now - $a | todate)}]' >"$tmp/activity.json"
	fi
	printf '%s\n' "$3" | jq -Rn '[inputs | split(" ") | select(length >= 2)
		| {user:{type:"User",login:"u"},author_association:.[1],created_at:(now - (.[0] | tonumber) | todate),body:"@codex review"}]' >"$tmp/comments.json"
	echo '[]' >"$tmp/reviews.json"
}

# status_is <line> [exit]: what codex-status.sh prints, and how it exits.
status_is() {
	printf '%s\n' "$1" >"$tmp/status.out"
	echo "${2:-0}" >"$tmp/status.rc"
}

# answer <age secs>...: the bot answers (a review) that long ago, once per age.
answer() {
	printf '%s\n' "$@" | jq -Rn --arg b "$bot" '[inputs | {user:{login:$b},submitted_at:(now - tonumber | todate)}]' >"$tmp/reviews.json"
}

# run <label> <want exit> <want posts> [args...]: runs the script from the unrelated checkout.
run() {
	label=$1
	want_rc=$2
	want_posts=$3
	shift 3
	out=$(cd "$tmp/repo" && PATH=$tmp/bin:$PATH CODEX_REQUEST_TRIES=${TRIES:-3} sh "$tmp/skill/codex-request.sh" "$@" 2>&1)
	rc=$?
	posts=0
	[ -f "$tmp/posted" ] && posts=$(wc -l <"$tmp/posted" | tr -d ' ')
	if [ "$rc" != "$want_rc" ] || [ "$posts" != "$want_posts" ]; then
		echo "FAIL (exit $rc want $want_rc, posts $posts want $want_posts): $label"
		echo "  $out"
		fail=1
	fi
}

# The head is the given sha from an unrelated checkout.
setup "$sha" 600 ''
run 'sha matches' 0 1 1 o/r "$sha"
# The posted comment is the request.
grep -q '@codex review' "$tmp/posted" || { echo "FAIL: not an @codex review comment"; fail=1; }
# The head lags, then matches: it waits and posts.
setup "$old
$old
$sha" 600 ''
run 'head lags' 0 1 1 o/r "$sha"
[ "$(wc -l <"$tmp/slept" | tr -d ' ')" = 2 ] || { echo "FAIL: slept $(cat "$tmp/slept" 2>/dev/null | wc -l) times, want 2"; fail=1; }
# It never matches: exit 1, nothing posted.
setup "$old" 600 ''
run 'never matches' 1 0 1 o/r "$sha"
# Without a sha, the checkout's HEAD is the wanted head (the old behaviour).
setup "$local_head" - ''
run 'default is HEAD' 0 1 1 o/r
setup "$sha" - ''
run 'default is HEAD, PR elsewhere' 1 0 1 o/r

# Repeat-safety: a request for this head already out (after the push, unanswered, not stalled) isn't repeated.
setup "$sha" 600 '300 OWNER'
run 'already requested' 0 0 1 o/r "$sha"
case $(cd "$tmp/repo" && PATH=$tmp/bin:$PATH sh "$tmp/skill/codex-request.sh" 1 o/r "$sha" 2>&1) in
*'already requested'*) ;;
*) echo "FAIL: no 'already requested' message"; fail=1 ;;
esac
setup "$sha" 600 '300 COLLABORATOR'
run 'already requested by a collaborator' 0 0 1 o/r "$sha"
# A request older than the push was for an earlier head.
setup "$sha" 300 '600 OWNER'
run 'request before the push' 0 1 1 o/r "$sha"
# An answered request (the bot reviewed after it) is done: asking again is a new round.
setup "$sha" 600 '300 OWNER'
answer 100
run 'answered request' 0 1 1 o/r "$sha"
# An answer from before the request doesn't count.
setup "$sha" 600 '300 OWNER'
answer 500
run 'answer before the request' 0 0 1 o/r "$sha"
# Only the owner and collaborators can request.
setup "$sha" 600 '300 NONE
200 MEMBER'
run 'outsiders do not count' 0 1 1 o/r "$sha"
# No recorded push: no way to tie a request to this head, so it asks.
setup "$sha" - '300 OWNER'
run 'push unknown' 0 1 1 o/r "$sha"

# The repeat check asks codex-status.sh (claude-ship #133, #139), so both judge a request the same way: only its
# plain "Waiting for Codex" pending leaves the request alone. Any other verdict goes on to the cap and posts.
# #139: the request is 16 min old, but Codex edited its summary a minute ago, so the status is plain pending.
setup "$sha" 3000 '960 OWNER'
status_is "pending: Waiting for Codex to review 1111111 ($sha)"
run 'old request, review still running' 0 0 1 o/r "$sha"
# The status is asked for this head and repo, as a dry run.
[ "$(cat "$tmp/status.calls")" = "DRY_RUN=1 REPO=o/r HEAD_SHA=$sha 1" ] || { echo "FAIL: status call was: $(cat "$tmp/status.calls")"; fail=1; }
for verdict in \
	"pending: Codex's review of 1111111 stalled (no update in 15 min, openai/codex#55890); ask again with @codex review ($sha)" \
	"pending: Codex hasn't acknowledged the request for 1111111 in 5 min; ask again with @codex review ($sha)" \
	"pending: Codex finished more than once since the last request for 1111111, so neither is tied to it; ask again with @codex review ($sha)" \
	"success: Codex reviewed 1111111 with no findings ($sha)" \
	"failure: 1 unresolved Codex thread(s); fix or answer each, then resolve it ($sha)"; do
	setup "$sha" 3000 '2000 OWNER'
	status_is "$verdict"
	run "posts after: $verdict" 0 1 1 o/r "$sha"
done
# A failing status script stops the call without a post or a guess.
setup "$sha" 3000 '2000 OWNER'
status_is 'boom' 1
run 'status error' 2 0 1 o/r "$sha"
# No request after the push: nothing to judge, so the status is not even asked (and a plain pending from "no
# request yet" is never mistaken for one).
setup "$sha" 600 ''
status_is 'boom' 1
run 'no request, status not asked' 0 1 1 o/r "$sha"
[ ! -f "$tmp/status.calls" ] || { echo "FAIL: status asked with no request"; fail=1; }
# An answered request is a new round without asking the status either.
setup "$sha" 600 '300 OWNER'
answer 100
run 'answered, status not asked' 0 1 1 o/r "$sha"
[ ! -f "$tmp/status.calls" ] || { echo "FAIL: status asked for an answered request"; fail=1; }
# codex-status.sh is found next to the script, else in scripts/ of the repo it is installed from.
mkdir -p "$tmp/tree/skills/ship" "$tmp/tree/scripts"
cp "$tmp/skill/codex-request.sh" "$tmp/skill/codex-round.sh" "$tmp/tree/skills/ship/"
cp "$tmp/skill/codex-status.sh" "$tmp/tree/scripts/"
setup "$sha" 3000 '960 OWNER'
out=$(cd "$tmp/repo" && PATH=$tmp/bin:$PATH CODEX_REQUEST_TRIES=3 sh "$tmp/tree/skills/ship/codex-request.sh" 1 o/r "$sha" 2>&1)
case $out in
*'already requested'*) ;;
*) echo "FAIL: status not found in scripts/: $out"; fail=1 ;;
esac
rm "$tmp/tree/scripts/codex-status.sh"
out=$(cd "$tmp/repo" && PATH=$tmp/bin:$PATH CODEX_REQUEST_TRIES=3 sh "$tmp/tree/skills/ship/codex-request.sh" 1 o/r "$sha" 2>&1)
rc=$?
[ "$rc" = 2 ] || { echo "FAIL: without a status script exit $rc, want 2: $out"; fail=1; }

# The round cap: three requests used (all from before this push, each answered by a review) means no fourth is
# posted: exit 4. A request Codex never acknowledged uses no round (claude-ship #133), so each one is answered.
setup "$sha" 600 '5000 OWNER
4000 OWNER
3000 COLLABORATOR'
answer 4900 3900 2900
run 'cap reached' 4 0 1 o/r "$sha"
# Two used is below the cap.
setup "$sha" 600 '5000 OWNER
4000 OWNER'
answer 4900 3900
run 'below the cap' 0 1 1 o/r "$sha"
# Outsiders' comments use no round.
setup "$sha" 600 '5000 OWNER
4000 OWNER
3000 NONE
2000 MEMBER'
answer 4900 3900
run 'outsiders use no round' 0 1 1 o/r "$sha"
# The cap is not a reason to refuse a request already out for this head: that round is still pending.
setup "$sha" 600 '5000 OWNER
4000 OWNER
300 OWNER'
answer 4900 3900
run 'cap, but this head is pending' 0 0 1 o/r "$sha"
# A request Codex never acknowledged is not a round, so two real ones and a dropped one are below the cap.
setup "$sha" 600 '5000 OWNER
4000 OWNER
3000 OWNER'
answer 4900 3900
run 'cap, with an unacknowledged request' 0 1 1 o/r "$sha"
# The user may allow a later round.
setup "$sha" 600 '5000 OWNER
4000 OWNER
3000 OWNER'
answer 4900 3900 2900
CODEX_ROUND_CAP=4
export CODEX_ROUND_CAP
run 'cap raised' 0 1 1 o/r "$sha"
unset CODEX_ROUND_CAP

# Misuse exits 2.
setup "$sha" 600 ''
run 'no pr' 2 0
run 'bad sha' 2 0 1 o/r nothex
run 'short sha' 2 0 1 o/r abc1234

exit $fail
