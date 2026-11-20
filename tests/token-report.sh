#!/bin/sh
# Tests skills/ship/token-report.sh: per-PR usage and cost from Claude Code transcripts. The fake gh serves
# `repo view`, `pr view <n>` and the GraphQL PR list from fixture files; transcripts are built under a fake projects dir whose
# slug the script must derive from the repo (and from a worktree of it, via the git common dir).
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
"repo view") echo acme/app ;;
"pr view")
	[ -f "$GH_DIR/pr-$3.json" ] || { echo "no pull request found for $3" >&2; exit 1; }
	[ "$4 $5" = "-R acme/app" ] || { echo "gh pr view without -R acme/app: $*" >&2; exit 1; }
	echo "$3" >>"$GH_DIR/views"
	cat "$GH_DIR/pr-$3.json"
	;;
"api graphql")
	# The repo's PR list as GitHub's GraphQL API serves it (#213): newest first, 100 a page, each PR with its first
	# commit's authored date. list.json is the whole list, an array of PR nodes (a node without `commits` gets its
	# first commit from pr-<n>.json); anything else in it is served as the first response, as it is. Each call is
	# logged in `lists` (its `after` cursor, "-" for none); a fixture file `page2-fails` makes the second page fail.
	[ -f "$GH_DIR/list.json" ] || { echo "graphql failed" >&2; exit 1; }
	[ "$3" = -f ] && [ "$5 $6 $7 $8" = "-f owner=acme -f name=app" ] || { echo "gh api graphql with wrong arguments: $*" >&2; exit 1; }
	for want in 'query=' 'first: 100' 'states: [OPEN, CLOSED, MERGED]' 'orderBy: {field: CREATED_AT, direction: DESC}' 'commits(first: 1)' 'authoredDate'; do
		case "$4" in *"$want"*) ;; *) echo "gh api graphql without $want: $*" >&2; exit 1 ;; esac
	done
	after=
	if [ $# -gt 8 ]; then
		[ $# = 10 ] && [ "$9" = -f ] || { echo "gh api graphql with wrong arguments: $*" >&2; exit 1; }
		after=${10#after=}
	fi
	echo "${after:--}" >>"$GH_DIR/lists"
	if [ "$(jq -r 'type' "$GH_DIR/list.json")" != array ]; then
		cat "$GH_DIR/list.json"
		exit 0
	fi
	[ -z "$after" ] || [ ! -f "$GH_DIR/page2-fails" ] || { echo "page 2 failed" >&2; exit 1; }
	[ -z "$after" ] || [ "$after" = c100 ] || { echo "unexpected cursor: $after" >&2; exit 1; }
	set -- "$GH_DIR"/pr-*.json
	[ -e "$1" ] || set -- /dev/null
	jq -n -c --arg after "$after" --slurpfile all "$GH_DIR/list.json" '
		[inputs | {n: (input_filename | capture("pr-(?<n>[0-9]+)[.]json").n | tonumber), f: (.commits[0].authoredDate // null)}] as $f
		| ($all[0] | map(. as $p | if has("commits") then . else . + {commits: {nodes: (
			([$f[] | select(.n == $p.number and .f != null) | .f] | .[0]) as $d
			| if $d == null then [] else [{commit: {authoredDate: $d}}] end)}} end)) as $L
		| (if $after == "" then 0 else 100 end) as $o
		| {data: {repository: {pullRequests: {pageInfo: {hasNextPage: (($L | length) > ($o + 100)),
			endCursor: (if ($L | length) > ($o + 100) then "c\($o + 100)" else null end)}, nodes: $L[$o:$o + 100]}}}}' "$@"
	;;
*) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
fail=0

repo=$tmp/work/app.git-x
mkdir -p "$tmp/work"
git init -q -b main "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
git -C "$repo" worktree add -q -b wt "$tmp/wt" 2>/dev/null
slug=$(printf %s "$repo" | sed 's/[^A-Za-z0-9]/-/g')
GH_DIR=$tmp/gh
export GH_DIR
P=$tmp/projects
D=$P/$slug

# fresh: empties the fixtures, the transcript dir and the gate's cost log; the author has no PR besides the
# ones given to plist.
fresh() {
	rm -rf "$GH_DIR" "$P" "$tmp/costs.jsonl"
	unset COSTS
	mkdir -p "$GH_DIR" "$D"
	echo '[]' >"$GH_DIR/list.json"
}

# plist <n|created|merged|closed[|author]>...: the repo's PR list, as list.json (an empty field is null;
# the author is "me" unless given, and "none" is a deleted account: a null author).
plist() {
	printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(. != "") | split("|") as $f
		| (if ($f[4] // "") == "" then "me" else $f[4] end) as $a
		| {number: ($f[0] | tonumber), author: (if $a == "none" then null else {login: $a} end), createdAt: $f[1],
		mergedAt: (if $f[2] == "" then null else $f[2] end),
		closedAt: (if $f[3] == "" then null else $f[3] end)})' >"$GH_DIR/list.json"
}

# pauthor <n> <login>: the author of PR <n> as `pr` made it ("me").
pauthor() {
	jq -c --arg a "$2" '.author.login = $a' "$GH_DIR/pr-$1.json" >"$GH_DIR/pr-$1.tmp" && mv "$GH_DIR/pr-$1.tmp" "$GH_DIR/pr-$1.json"
}

# pr <n> <title> <created> <merged or empty> [<first commit authored> [<closed at> [<commit shas, comma separated>]]]
# With <closed at> and no <merged>, the PR is closed without merging; with neither it is open. The shas are the
# commits' oids; the first commit carries the authored date, if there is one.
pr() {
	jq -n --arg t "$2" --arg c "$3" --arg m "$4" --arg a "${5:-}" --arg x "${6:-}" --arg s "${7:-}" \
		'($s | split(",") | map(select(. != ""))) as $o
		| {title:$t,author:{login:"me"},createdAt:$c,mergedAt:(if $m == "" then null else $m end),
		state:(if $m != "" then "MERGED" elif $x != "" then "CLOSED" else "OPEN" end),
		closedAt:(if $m != "" then $m elif $x != "" then $x else null end),
		commits:([range(0; ([($o | length), (if $a == "" then 0 else 1 end)] | max))]
			| map({authoredDate: (if . == 0 and $a != "" then $a else null end), oid: ($o[.] // null)}))}' >"$GH_DIR/pr-$1.json"
}

# gate <date> <repo> <head> <stage> <model> <cost or null> [<rc>]: appends a row to the gate's cost log, as
# hooks/review-gate.sh writes it. Tests that don't set COSTS read a log that doesn't exist.
gate() {
	jq -nc --arg d "$1" --arg r "$2" --arg h "$3" --arg s "$4" --arg m "$5" --argjson c "$6" --argjson rc "${7:-0}" \
		'{date:$d,repo:$r,head:$h,stage:$s,model:$m,rc:$rc,cost_usd:$c,findings:0}' >>"$tmp/costs.jsonl"
}

# line <file> <requestId> <timestamp> <model> <in> <out> <cache read> <cache write> [<5m> <1h>]
# One assistant line; without <5m> <1h> there is no cache_creation split.
line() {
	mkdir -p "$(dirname "$1")"
	jq -nc --arg rid "$2" --arg ts "$3" --arg m "$4" --argjson i "$5" --argjson o "$6" --argjson cr "$7" \
		--argjson cc "$8" --arg w5 "${9:-}" --arg w1 "${10:-}" \
		'{type:"assistant",requestId:$rid,timestamp:$ts,message:{model:$m,usage:({input_tokens:$i,
		output_tokens:$o,cache_read_input_tokens:$cr,cache_creation_input_tokens:$cc}
		+ (if $w5 == "" then {} else {cache_creation:{ephemeral_5m_input_tokens:($w5 | tonumber),
		ephemeral_1h_input_tokens:($w1 | tonumber)}} end))}}' >>"$1"
}

# meta <agent file> <json>
meta() { printf '%s\n' "$2" >"${1%.jsonl}.meta.json"; }

# run [-C <dir>] <pr>...: runs the script in the repo, leaving stdout in $tmp/out (runs of spaces squeezed),
# stderr in $tmp/err and the exit code in $rc.
run() {
	dir=$repo
	if [ "${1:-}" = -C ]; then
		dir=$2
		shift 2
	fi
	(cd "$dir" && PATH=$tmp/bin:$PATH CLAUDE_PROJECTS_DIR=$P CLAUDE_REVIEW_COSTS=${COSTS:-$tmp/no-such-costs.jsonl} sh "$root/skills/ship/token-report.sh" "$@") >"$tmp/raw" 2>"$tmp/err"
	rc=$?
	tr -s ' ' <"$tmp/raw" >"$tmp/out"
}

# nomainless: stderr without the warning for a PR that has no main row (#248); fixtures with only subagent or
# gate rows trigger it, and the tests that look at the rest of stderr don't care.
nomainless() { grep -v 'no main-session row' "$tmp/err"; }

# check <label> <want rc> <want stdout>: stdout is compared whole, with runs of spaces squeezed.
check() {
	if [ "$rc" != "$2" ]; then
		echo "FAIL (exit $rc, want $2): $1"
		cat "$tmp/err"
		fail=1
		return
	fi
	if [ "$(cat "$tmp/out")" != "$3" ]; then
		echo "FAIL (stdout): $1"
		echo "--- want"
		printf '%s\n' "$3"
		echo "--- got"
		cat "$tmp/out"
		fail=1
	fi
}

# --- usage: no PR number exits 2 (not 1: a caller must not read it as a result); so does a non-number.
fresh
run
check 'no args' 2 ''
grep -q '^usage:' "$tmp/err" || { echo 'FAIL: no usage message on stderr'; fail=1; }
run abc
check 'non-numeric pr' 2 ''

# --- dedupe, prices, windows, subagent attribution.
# PR 10: created 10:00:00Z, first commit authored 09:30:00Z, merged 12:00:00Z (so the window is 09:30..12:00).
fresh
pr 10 'feat: a' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z 2026-10-01T09:30:00Z
S=$D/sess1
# One Opus request over three lines (largest output wins): in 100000, out 50000, cache read 1000000,
# cache write 200000 (all 5m) = 0.40 + 1.00 + 0.20 + 1.00 = $2.60.
line "$S.jsonl" req_a 2026-10-01T10:30:00.100Z claude-opus-5-5 100000 10000 1000000 200000 200000 0
line "$S.jsonl" req_a 2026-10-01T10:30:00.200Z claude-opus-5-5 100000 50000 1000000 200000 200000 0
line "$S.jsonl" req_a 2026-10-01T10:30:00.300Z claude-opus-5-5 100000 20000 1000000 200000 200000 0
# 1 s before the window starts (in an older session, which the window doesn't widen to) and 1 s after it
# ends: not counted.
line "$D/old.jsonl" req_early 2026-10-01T09:29:59.900Z claude-opus-5-5 9000000 0 0 0
line "$S.jsonl" req_late 2026-10-01T12:00:01.000Z claude-opus-5-5 9000000 0 0 0
# Within the end second (mergedAt carries no milliseconds): counted. 250000 in + 100000 cache write with no
# cache_creation split (priced as 5m): 1.00 + 0.50 = $1.50.
line "$S.jsonl" req_edge 2026-10-01T12:00:00.500Z claude-opus-5-5 250000 0 0 100000
# <synthetic> is skipped, and so are lines without a requestId or usage.
line "$S.jsonl" req_syn 2026-10-01T10:31:00.000Z '<synthetic>' 9000000 9000000 0 0
printf '%s\n' '{"type":"user","timestamp":"2026-10-01T10:31:00.000Z"}' \
	'{"type":"assistant","timestamp":"2026-10-01T10:31:00.000Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":9000000}}}' \
	'not json at all' >>"$S.jsonl"
# Sonnet ship-implementer: 1M in = $2.00; then 100000 out = $1.00 and 600000 cache write split 100000 5m /
# 400000 1h, the other 100000 priced as 5m: (100000 + 100000) * 2.50 + 400000 * 4.00 = $0.50 + $1.60.
A=$S/subagents/agent-x1.jsonl
line "$A" sa1 2026-10-01T09:45:00.000Z claude-sonnet-5-5 1000000 0 0 0
line "$A" sa2 2026-10-01T11:00:00.250Z claude-sonnet-5-5 0 100000 0 600000 100000 400000
meta "$A" '{"agentType":"ship-implementer","isBuiltIn":false}'
# Another implementer whose first request is inside the window but whose last is outside: not counted at all.
A=$S/subagents/agent-x2.jsonl
line "$A" sb1 2026-10-01T10:10:00.000Z claude-sonnet-5-5 9000000 0 0 0
line "$A" sb2 2026-10-01T13:00:00.000Z claude-sonnet-5-5 0 1 0 0
meta "$A" '{"agentType":"ship-implementer"}'
# No meta file, and a meta without agentType: both are role "subagent". Haiku out 1M = $0.50 each.
A=$S/subagents/agent-x3.jsonl
line "$A" sc1 2026-10-01T10:20:00.000Z claude-haiku-5-5 0 1000000 0 0
A=$S/subagents/agent-x4.jsonl
line "$A" sd1 2026-10-01T10:21:00.000Z claude-haiku-5-5 0 1000000 0 0
meta "$A" '{"isBuiltIn":false}'
run 10
check 'rows, dedupe, windows, roles' 0 'PR #10 feat: a (2026-10-01T09:30:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 2 350000 50000 1000000 300000 $4.10
ship-implementer claude-sonnet-5-5 2 1000000 100000 0 600000 $5.10
subagent claude-haiku-5-5 2 0 2000000 0 0 $1.00
total 6 1350000 2150000 1000000 900000 $10.20
peak main context: 1300000 tokens'
[ ! -s "$tmp/err" ] || { echo 'FAIL: unexpected stderr'; cat "$tmp/err"; fail=1; }

# The script finds the transcripts from a worktree too: the slug comes from the git common dir.
cp "$tmp/out" "$tmp/out.main"
run -C "$tmp/wt" 10
check 'from a worktree' 0 "$(cat "$tmp/out.main")"

# A PR given twice (or with leading zeros: 010 is 10) is reported once (#166).
run 10 10
check 'a repeated PR' 0 "$(cat "$tmp/out.main")"
run 010 10 0010
check 'a PR repeated with leading zeros' 0 "$(cat "$tmp/out.main")"

# --- overlapping windows: a main request goes to the later-started PR only.
fresh
pr 20 'one' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
pr 21 'two' 2026-10-01T11:00:00Z 2026-10-01T13:00:00Z
S=$D/s
line "$S.jsonl" r1 2026-10-01T10:30:00.000Z claude-opus-5-5 250000 0 0 0
line "$S.jsonl" r2 2026-10-01T11:30:00.000Z claude-opus-5-5 500000 0 0 0
line "$S.jsonl" r3 2026-10-01T12:30:00.000Z claude-opus-5-5 250000 0 0 0
# A subagent belongs to the PR holding its last request (11:30 is in both: the later-started one).
A=$S/subagents/agent-y.jsonl
line "$A" y1 2026-10-01T10:10:00.000Z claude-sonnet-5-5 500000 0 0 0
line "$A" y2 2026-10-01T11:30:00.000Z claude-sonnet-5-5 500000 0 0 0
meta "$A" '{"agentType":"ship-implementer"}'
run 20 21
check 'overlap' 0 'PR #20 one (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
total 1 250000 0 0 0 $1.00
peak main context: 250000 tokens

PR #21 two (2026-10-01T10:30:00 → 2026-10-01T13:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 2 750000 0 0 0 $3.00
ship-implementer claude-sonnet-5-5 2 1000000 0 0 0 $2.00
total 4 1750000 0 0 0 $5.00
peak main context: 500000 tokens'

# --- Haiku's price tier follows the prompt (input + cache read + cache write): 100000 is the cheap tier
# ($0.10/MTok in), 100001 the other ($0.50/MTok).
fresh
pr 30 'tiers' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
A=$D/s/subagents/agent-lo.jsonl
line "$A" h1 2026-10-01T10:10:00.000Z claude-haiku-5-5 100000 0 0 0
meta "$A" '{"agentType":"lo"}'
A=$D/s/subagents/agent-hi.jsonl
line "$A" h2 2026-10-01T10:10:00.000Z claude-haiku-5-5 100001 0 0 0
meta "$A" '{"agentType":"hi"}'
A=$D/s/subagents/agent-mix.jsonl
line "$A" h3 2026-10-01T10:10:00.000Z claude-haiku-5-5 50000 0 30000 20000 20000 0
meta "$A" '{"agentType":"mix"}'
run 30
check 'haiku tiers' 0 'PR #30 tiers (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
hi claude-haiku-5-5 1 100001 0 0 0 $0.05
lo claude-haiku-5-5 1 100000 0 0 0 $0.01
mix claude-haiku-5-5 1 50000 0 30000 20000 $0.01
total 3 250001 0 30000 20000 $0.07
peak main context: 0 tokens'

# --- the older models are priced too (#247), from the claude-api skill's shared/models.md: each request is 1M in,
# 1M out, 1M cache read, 1M 5m write and 1M 1h write. Opus 4.x is $5 / $25 (read $0.50, writes $6.25 / $10) =
# $46.75, Sonnet 4.6 $3 / $15 (read $0.30, writes $3.75 / $6) = $28.05, Haiku 4.5 $1 / $5 (read $0.10, writes
# $1.25 / $2) = $9.35, at any prompt length. None of them warns about a missing price.
fresh
pr 35 'old models' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
n=0
for m in claude-opus-4-8 claude-opus-4-7 claude-opus-4-6 claude-sonnet-4-6 claude-haiku-4-5; do
	n=$((n + 1))
	A=$D/s/subagents/agent-old$n.jsonl
	line "$A" old$n 2026-10-01T10:10:00.000Z "$m" 1000000 1000000 1000000 2000000 1000000 1000000
	meta "$A" "{\"agentType\":\"old$n\"}"
done
run 35
check 'older models' 0 'PR #35 old models (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
old1 claude-opus-4-8 1 1000000 1000000 1000000 2000000 $46.75
old2 claude-opus-4-7 1 1000000 1000000 1000000 2000000 $46.75
old3 claude-opus-4-6 1 1000000 1000000 1000000 2000000 $46.75
old4 claude-sonnet-4-6 1 1000000 1000000 1000000 2000000 $28.05
old5 claude-haiku-4-5 1 1000000 1000000 1000000 2000000 $9.35
total 5 5000000 5000000 5000000 10000000 $177.65
peak main context: 0 tokens'
[ -z "$(nomainless)" ] || { echo 'FAIL: the older models must not warn about a missing price'; cat "$tmp/err"; fail=1; }

# --- unknown model, open PR (the window runs to now), a PR with no usage.
fresh
pr 40 'open one' 2026-10-01T10:00:00Z ''
pr 41 'quiet' 2020-01-01T00:00:00Z 2020-01-02T00:00:00Z
S=$D/s
line "$S.jsonl" u1 2026-10-01T10:05:00.000Z claude-mystery-9 1000 2000 0 0
line "$S.jsonl" u2 2026-10-01T10:06:00.000Z claude-mystery-9 1000 2000 0 0
line "$S.jsonl" u3 2026-10-01T10:07:00.000Z claude-opus-5-5 250000 0 0 0
run 40 41
check 'unknown model, open, quiet' 0 'PR #40 open one (2026-10-01T10:00:00 → open)
role model requests input output cache read cache write cost
main claude-mystery-9 2 2000 4000 0 0 ?
main claude-opus-5-5 1 250000 0 0 0 $1.00
total 3 252000 4000 0 0 ?
peak main context: 250000 tokens

PR #41 quiet (2020-01-01T00:00:00 → 2020-01-02T00:00:00)
no usage found'
[ "$(grep -c 'claude-mystery-9' "$tmp/err")" = 1 ] || { echo 'FAIL: want exactly one warning for the unknown model'; cat "$tmp/err"; fail=1; }

# --- a PR closed without merging ends at closedAt, not now: an Oct 20 request is not its, and its window
# doesn't capture requests from another requested PR's window.
fresh
pr 50 'abandoned' 2026-10-01T10:00:00Z '' '' 2026-10-01T12:00:00Z
pr 51 'later' 2026-10-20T09:00:00Z 2026-10-20T11:00:00Z
plist '50|2026-10-01T10:00:00Z||2026-10-01T12:00:00Z'
S=$D/s
line "$S.jsonl" c1 2026-10-01T11:00:00.000Z claude-opus-5-5 250000 0 0 0
line "$S.jsonl" c2 2026-10-20T10:00:00.000Z claude-opus-5-5 500000 0 0 0
line "$S.jsonl" c3 2026-10-25T10:00:00.000Z claude-opus-5-5 9000000 0 0 0
run 50 51
check 'closed without merge' 0 'PR #50 abandoned (2026-10-01T10:00:00 → 2026-10-01T12:00:00 closed)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
total 1 250000 0 0 0 $1.00
peak main context: 250000 tokens

PR #51 later (2026-10-01T12:00:00 → 2026-10-20T11:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 500000 0 0 0 $2.00
total 1 500000 0 0 0 $2.00
peak main context: 500000 tokens'

# A closed PR with no closedAt is an error, not an open one that runs to now.
printf '%s\n' '{"title":"odd","author":{"login":"me"},"state":"CLOSED","createdAt":"2026-10-01T10:00:00Z","mergedAt":null,"closedAt":null,"commits":[]}' >"$GH_DIR/pr-52.json"
run 52
if [ "$rc" = 0 ] || [ -s "$tmp/out" ]; then
	echo "FAIL: closed PR without closedAt (exit $rc)"
	cat "$tmp/out"
	fail=1
fi
grep -q 'PR #52' "$tmp/err" || { echo 'FAIL: no message for the closed PR without closedAt'; cat "$tmp/err"; fail=1; }

# --- main-session work before a PR's first commit counts (#80): the window starts at the end of the author's
# previous PR or the start of the session, whichever is later, and never after its own start.
# PR 60: created 11:00, first commit 10:30; the session's first request, a planning one, is 10:00 (30 minutes
# before the first commit). An older session's request at 09:59 is not counted.
fresh
pr 60 'planned' 2026-10-01T11:00:00Z 2026-10-01T12:00:00Z 2026-10-01T10:30:00Z
line "$D/old.jsonl" o1 2026-10-01T09:59:00.000Z claude-opus-5-5 9000000 0 0 0
line "$D/s.jsonl" p1 2026-10-01T10:00:00.000Z claude-opus-5-5 250000 0 0 0
line "$D/s.jsonl" p2 2026-10-01T11:30:00.000Z claude-opus-5-5 250000 0 0 0
run 60
check 'planning before the first commit' 0 'PR #60 planned (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 2 500000 0 0 0 $2.00
total 2 500000 0 0 0 $2.00
peak main context: 250000 tokens'

# PR 61 merged at 12:00 and PR 62 (first commit 13:00) in one session: the 12:30 request is PR 62's, the
# 11:00 one PR 61's, and the one after PR 62's merge is nobody's.
fresh
pr 61 'a' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
pr 62 'b' 2026-10-01T13:00:00Z 2026-10-01T14:00:00Z
plist '61|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z|2026-10-01T12:00:00Z' '62|2026-10-01T13:00:00Z|2026-10-01T14:00:00Z|2026-10-01T14:00:00Z' '63|2026-10-02T00:00:00Z||'
pr 63 'o' 2026-10-02T00:00:00Z ''
S=$D/s
line "$S.jsonl" q1 2026-10-01T10:15:00.000Z claude-opus-5-5 250000 0 0 0
line "$S.jsonl" q2 2026-10-01T11:00:00.000Z claude-opus-5-5 250000 0 0 0
line "$S.jsonl" q3 2026-10-01T12:30:00.000Z claude-opus-5-5 500000 0 0 0
line "$S.jsonl" q4 2026-10-01T13:30:00.000Z claude-opus-5-5 500000 0 0 0
line "$S.jsonl" q5 2026-10-01T14:30:00.000Z claude-opus-5-5 9000000 0 0 0
run 61 62
check 'two PRs in one session' 0 'PR #61 a (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 2 500000 0 0 0 $2.00
total 2 500000 0 0 0 $2.00
peak main context: 250000 tokens

PR #62 b (2026-10-01T12:00:00 → 2026-10-01T14:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 2 1000000 0 0 0 $4.00
total 2 1000000 0 0 0 $4.00
peak main context: 500000 tokens'

# An earlier PR that merged before this session began: the session's first request bounds the window, so an
# unrelated older session's request (10-04) after that merge isn't counted.
fresh
pr 64 'later' 2026-10-05T10:00:00Z 2026-10-05T12:00:00Z
plist '63|2026-10-03T10:00:00Z|2026-10-03T12:00:00Z|2026-10-03T12:00:00Z'
pr 63 'e' 2026-10-03T10:00:00Z 2026-10-03T12:00:00Z
line "$D/old.jsonl" o2 2026-10-04T09:00:00.000Z claude-opus-5-5 9000000 0 0 0
line "$D/s.jsonl" b1 2026-10-05T09:00:00.000Z claude-opus-5-5 250000 0 0 0
line "$D/s.jsonl" b2 2026-10-05T10:30:00.000Z claude-opus-5-5 250000 0 0 0
run 64
check 'session start bounds the window' 0 'PR #64 later (2026-10-05T09:00:00 → 2026-10-05T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 2 500000 0 0 0 $2.00
total 2 500000 0 0 0 $2.00
peak main context: 250000 tokens'

# A session that began before an earlier merge doesn't pull that PR's work in: the merge bounds the window.
fresh
pr 65 'x' 2026-10-05T10:00:00Z 2026-10-05T12:00:00Z
plist '66|2026-10-05T07:30:00Z|2026-10-05T08:00:00Z|2026-10-05T08:00:00Z'
pr 66 'f' 2026-10-05T07:30:00Z 2026-10-05T08:00:00Z
line "$D/s.jsonl" c1 2026-10-05T07:00:00.000Z claude-opus-5-5 9000000 0 0 0
line "$D/s.jsonl" c2 2026-10-05T10:30:00.000Z claude-opus-5-5 250000 0 0 0
run 65
check 'earlier merge bounds the window' 0 'PR #65 x (2026-10-05T08:00:00 → 2026-10-05T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
total 1 250000 0 0 0 $1.00
peak main context: 250000 tokens'

# The numbers don't depend on which PRs are asked for: PR 70 (10:00..12:00) and PR 71 (11:00..13:00) in one
# session with requests at 09:40 (inside PR 70's own window, which starts at its 09:30 first commit, not its
# creation), 10:15 (also PR 70's) and 12:15 (inside PR 71's only). Asking for PR 71 alone drops the first two
# (PR 70's, though not asked for) rather than giving them to PR 71's widened window.
fresh
pr 70 'p' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z 2026-10-01T09:30:00Z
pr 71 'q' 2026-10-01T11:00:00Z 2026-10-01T13:00:00Z
plist '70|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z|2026-10-01T12:00:00Z' '71|2026-10-01T11:00:00Z|2026-10-01T13:00:00Z|2026-10-01T13:00:00Z'
line "$D/s.jsonl" w0 2026-10-01T09:40:00.000Z claude-opus-5-5 250000 0 0 0
line "$D/s.jsonl" w1 2026-10-01T10:15:00.000Z claude-opus-5-5 250000 0 0 0
line "$D/s.jsonl" w2 2026-10-01T12:15:00.000Z claude-opus-5-5 500000 0 0 0
run 71
check 'asking for the later PR alone' 0 'PR #71 q (2026-10-01T09:40:00 → 2026-10-01T13:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 500000 0 0 0 $2.00
total 1 500000 0 0 0 $2.00
peak main context: 500000 tokens'
run 70 71
check 'asking for both' 0 'PR #70 p (2026-10-01T09:30:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 2 500000 0 0 0 $2.00
total 2 500000 0 0 0 $2.00
peak main context: 250000 tokens

PR #71 q (2026-10-01T09:40:00 → 2026-10-01T13:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 500000 0 0 0 $2.00
total 1 500000 0 0 0 $2.00
peak main context: 500000 tokens'
# An open PR the author has (not asked for) owns its window up to now.
plist '70|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z|2026-10-01T12:00:00Z' '71|2026-10-01T11:00:00Z|2026-10-01T13:00:00Z|2026-10-01T13:00:00Z' '72|2026-10-01T12:10:00Z||'
pr 72 'r' 2026-10-01T12:10:00Z ''
run 71
check 'an open PR not asked for owns its window' 0 'PR #71 q (2026-10-01T09:40:00 → 2026-10-01T13:00:00)
no usage found'

# Failing to read one of the author's other PRs is an error too, not a PR that owns nothing.
plist '71|2026-10-01T11:00:00Z|2026-10-01T13:00:00Z|2026-10-01T13:00:00Z' '99|2026-10-01T09:00:00Z|2026-10-01T10:00:00Z|2026-10-01T10:00:00Z'
run 71
check 'another PR unreadable' 1 ''
grep -q 'gh pr view 99 failed' "$tmp/err" || { echo 'FAIL: no message for the unreadable other PR'; cat "$tmp/err"; fail=1; }

# --- a PR's section is the same whichever other PRs are asked for (every PR the author has competes for every
# request, and only the asked PRs are printed). same <a> <b> compares each one's section alone and together.
section() { awk -v want="#$1" '$1 == "PR" { p = ($2 == want) } p && NF' "$tmp/out"; }
same() {
	run "$1" "$2"
	[ "$rc" = 0 ] || { echo "FAIL (exit $rc): same $1 $2 together"; cat "$tmp/err"; fail=1; return; }
	section "$1" >"$tmp/both.$1"
	section "$2" >"$tmp/both.$2"
	for n in "$1" "$2"; do
		run "$n"
		[ "$rc" = 0 ] || { echo "FAIL (exit $rc): same $n alone"; cat "$tmp/err"; fail=1; continue; }
		section "$n" >"$tmp/alone.$n"
		if [ ! -s "$tmp/alone.$n" ] || ! cmp -s "$tmp/alone.$n" "$tmp/both.$n"; then
			echo "FAIL: PR #$n differs alone and with the other"
			echo '--- alone'
			cat "$tmp/alone.$n"
			echo '--- together'
			cat "$tmp/both.$n"
			fail=1
		fi
	done
}

# PR 70/71 above (requests at 09:40, 10:15, 12:15).
fresh
pr 70 'p' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z 2026-10-01T09:30:00Z
pr 71 'q' 2026-10-01T11:00:00Z 2026-10-01T13:00:00Z
plist '70|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z|2026-10-01T12:00:00Z' '71|2026-10-01T11:00:00Z|2026-10-01T13:00:00Z|2026-10-01T13:00:00Z'
line "$D/s.jsonl" w0 2026-10-01T09:40:00.000Z claude-opus-5-5 250000 0 0 0
line "$D/s.jsonl" w1 2026-10-01T10:15:00.000Z claude-opus-5-5 250000 0 0 0
line "$D/s.jsonl" w2 2026-10-01T12:15:00.000Z claude-opus-5-5 500000 0 0 0
same 70 71

# PR 80 (10:00..12:00) and 81 (11:00..13:00) with a planning request at 09:00 ($4) before both, then 10:15 ($1)
# and 12:15 ($1): both PRs' windows reach back to 09:00 and the later-started one (81) takes it, however many
# of the two are asked for.
fresh
pr 80 'a' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
pr 81 'b' 2026-10-01T11:00:00Z 2026-10-01T13:00:00Z
plist '80|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z|2026-10-01T12:00:00Z' '81|2026-10-01T11:00:00Z|2026-10-01T13:00:00Z|2026-10-01T13:00:00Z'
line "$D/s.jsonl" v0 2026-10-01T09:00:00.000Z claude-opus-5-5 1000000 0 0 0
line "$D/s.jsonl" v1 2026-10-01T10:15:00.000Z claude-opus-5-5 250000 0 0 0
line "$D/s.jsonl" v2 2026-10-01T12:15:00.000Z claude-opus-5-5 250000 0 0 0
run 80
check 'the earlier PR alone' 0 'PR #80 a (2026-10-01T09:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
total 1 250000 0 0 0 $1.00
peak main context: 250000 tokens'
same 80 81

# The competing PRs are the repo's, whoever wrote them (#130). Alice's PR 100 (10:00..12:00) and Bob's PR 101
# (11:00..13:00); one session with a planning request at 09:00 ($4), then 10:15 ($1) and 12:15 ($1). Both
# widen back to 09:00 and the later-started (Bob's) takes it, so Alice's row is the 10:15 request only, whether
# or not Bob's PR is asked for; Bob's is the other two.
fresh
pr 100 'a' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
pr 101 'b' 2026-10-01T11:00:00Z 2026-10-01T13:00:00Z
pauthor 100 alice
pauthor 101 bob
plist '100|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z|2026-10-01T12:00:00Z|alice' '101|2026-10-01T11:00:00Z|2026-10-01T13:00:00Z|2026-10-01T13:00:00Z|bob'
line "$D/s.jsonl" k0 2026-10-01T09:00:00.000Z claude-opus-5-5 1000000 0 0 0
line "$D/s.jsonl" k1 2026-10-01T10:15:00.000Z claude-opus-5-5 250000 0 0 0
line "$D/s.jsonl" k2 2026-10-01T12:15:00.000Z claude-opus-5-5 250000 0 0 0
run 100
check "Alice's PR alone" 0 'PR #100 a (2026-10-01T09:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
total 1 250000 0 0 0 $1.00
peak main context: 250000 tokens'
run 101
check "Bob's PR alone" 0 'PR #101 b (2026-10-01T09:00:00 → 2026-10-01T13:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 2 1250000 0 0 0 $5.00
total 2 1250000 0 0 0 $5.00
peak main context: 1000000 tokens'
same 100 101

# A deleted account's PR (a null author) in the list can't be read for its earlier PRs, so it is left out of the
# competing set rather than failing the report (only an asked PR must have an author).
plist '100|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z|2026-10-01T12:00:00Z|alice' '101|2026-10-01T11:00:00Z|2026-10-01T13:00:00Z|2026-10-01T13:00:00Z|bob' '102|2026-10-01T10:30:00Z|2026-10-01T10:45:00Z|2026-10-01T10:45:00Z|none'
run 100
check 'a deleted account in the list' 0 'PR #100 a (2026-10-01T09:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
total 1 250000 0 0 0 $1.00
peak main context: 250000 tokens'

# A full list (200 PRs) may have cut the repo's older PRs: a warning, not a failure.
pr 1199 'z' 2026-09-02T00:00:00Z 2026-09-02T01:00:00Z
pauthor 1199 alice
jq -n -c '[range(1000; 1198) | {number: ., author: {login: "alice"}, createdAt: "2026-09-01T00:00:00Z", mergedAt: "2026-09-01T01:00:00Z", closedAt: "2026-09-01T01:00:00Z"}]
	+ [{number: 1199, author: {login: "alice"}, createdAt: "2026-09-02T00:00:00Z", mergedAt: "2026-09-02T01:00:00Z", closedAt: "2026-09-02T01:00:00Z"}]
	+ [{number: 100, author: {login: "alice"}, createdAt: "2026-10-01T10:00:00Z", mergedAt: "2026-10-01T12:00:00Z", closedAt: "2026-10-01T12:00:00Z"}]' >"$GH_DIR/list.json"
run 100
check 'a full pr list' 0 'PR #100 a (2026-10-01T09:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 2 1250000 0 0 0 $5.00
total 2 1250000 0 0 0 $5.00
peak main context: 1000000 tokens'
grep -q 'newest 200' "$tmp/err" || { echo 'FAIL: no warning for the full pr list'; cat "$tmp/err"; fail=1; }

# But an asked PR that starts before the oldest PR in a full list (older than the newest 200, or created just
# after the cut) can't have its previous PR found: that is an error, not a window reaching back to the session's
# start. PR 98 (created 08-01) is older than the list's oldest (09-01).
pr 98 'old' 2026-08-01T10:00:00Z 2026-08-01T12:00:00Z
pauthor 98 alice
run 98
check 'asked PR older than a full list' 1 ''
grep -q 'PR #98' "$tmp/err" || { echo 'FAIL: no message naming the PR older than the full list'; cat "$tmp/err"; fail=1; }
# --since picks from the same list: a date inside it selects only the PRs after it (the full page still warns).
run --since 2026-10-01
check '--since in a full pr list' 0 'PR #100 a (2026-10-01T09:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 2 1250000 0 0 0 $5.00
total 2 1250000 0 0 0 $5.00
peak main context: 1000000 tokens'
grep -q 'newest 200' "$tmp/err" || { echo 'FAIL: no warning for the full pr list (--since)'; cat "$tmp/err"; fail=1; }

# PRs that start after every asked window can't hold one of its requests, so they aren't read (#129), even when
# the asked PR has no earlier PR to bound the other side. Alice's PR 200 (10:00..12:00) is her first; her next
# three start after it ends. The fake gh logs each `pr view`: only PR 200 is read, and the row is the same.
fresh
pr 200 'first' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
pr 201 'l1' 2026-10-01T13:00:00Z 2026-10-01T14:00:00Z
pr 202 'l2' 2026-10-01T15:00:00Z 2026-10-01T16:00:00Z
pr 203 'l3' 2026-10-01T17:00:00Z 2026-10-01T18:00:00Z
for n in 200 201 202 203; do pauthor "$n" alice; done
plist '200|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z|2026-10-01T12:00:00Z|alice' '201|2026-10-01T13:00:00Z|2026-10-01T14:00:00Z|2026-10-01T14:00:00Z|alice' '202|2026-10-01T15:00:00Z|2026-10-01T16:00:00Z|2026-10-01T16:00:00Z|alice' '203|2026-10-01T17:00:00Z|2026-10-01T18:00:00Z|2026-10-01T18:00:00Z|alice'
line "$D/s.jsonl" m1 2026-10-01T10:15:00.000Z claude-opus-5-5 250000 0 0 0
run 200
check 'later PRs are not read' 0 'PR #200 first (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
total 1 250000 0 0 0 $1.00
peak main context: 250000 tokens'
[ "$(cat "$GH_DIR/views")" = 200 ] || { echo 'FAIL: want only PR 200 read with gh pr view'; cat "$GH_DIR/views"; fail=1; }

# An asked PR that is still open has no end: the other PRs are not cut off from above.
plist '200|2026-10-01T10:00:00Z||' '201|2026-10-01T13:00:00Z|2026-10-01T14:00:00Z|2026-10-01T14:00:00Z|alice'
pr 200 'first' 2026-10-01T10:00:00Z ''
pauthor 200 alice
: >"$GH_DIR/views"
run 200
check 'an open PR is asked' 0 'PR #200 first (2026-10-01T10:00:00 → open)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
total 1 250000 0 0 0 $1.00
peak main context: 250000 tokens'
grep -qx 201 "$GH_DIR/views" || { echo 'FAIL: want PR 201 read when the asked PR is open'; cat "$GH_DIR/views"; fail=1; }

# The upper bound is per PR, not per creation date: Bob's PR 206 starts after Alice's PR 205 (10:00..12:00) ends,
# but his previous PR (204) ended at 08:00, so 206's window reaches back to the session's first request (09:00)
# and takes it from 205 (the later-started takes a tie). 205's row is the same asked alone or with 206, so 206
# must be read even though it was created after 205 ended.
fresh
pr 204 'x' 2026-10-01T07:00:00Z 2026-10-01T08:00:00Z
pr 205 'a' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
pr 206 'c' 2026-10-01T14:00:00Z 2026-10-01T15:00:00Z
pauthor 204 bob
pauthor 205 alice
pauthor 206 bob
plist '204|2026-10-01T07:00:00Z|2026-10-01T08:00:00Z|2026-10-01T08:00:00Z|bob' '205|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z|2026-10-01T12:00:00Z|alice' '206|2026-10-01T14:00:00Z|2026-10-01T15:00:00Z|2026-10-01T15:00:00Z|bob'
line "$D/s.jsonl" n0 2026-10-01T09:00:00.000Z claude-opus-5-5 1000000 0 0 0
line "$D/s.jsonl" n1 2026-10-01T10:15:00.000Z claude-opus-5-5 250000 0 0 0
line "$D/s.jsonl" n2 2026-10-01T14:30:00.000Z claude-opus-5-5 250000 0 0 0
run 205
check 'a later PR that widens back is read' 0 'PR #205 a (2026-10-01T09:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
total 1 250000 0 0 0 $1.00
peak main context: 250000 tokens'
same 205 206

# A PR created after every asked window ends can still compete (#213): its window starts at its first commit when
# that is earlier than its creation, and widens back from there. Alice's PR 300 (10:00..12:00) is asked. Bob's PR
# 301 is created at 14:00, but its first commit was authored at 11:30, and his previous PR 299 ended at 13:00
# (after 300), so only his first commit puts 301 in the competing set. Session: 09:00 ($4), 10:15 ($1), 12:15 ($1).
# 301 widens back to 09:00 (PR 298, his one before it, ended at 08:00) and takes that request from 300, so 300's
# row is the same whether or not 301 is asked, and 301 is read with `gh pr view` though only 300 is asked.
fresh
pr 298 'x' 2026-10-01T07:00:00Z 2026-10-01T08:00:00Z
pr 299 'y' 2026-10-01T12:40:00Z 2026-10-01T13:00:00Z
pr 300 'a' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
pr 301 'c' 2026-10-01T14:00:00Z 2026-10-01T15:00:00Z 2026-10-01T11:30:00Z
pauthor 298 bob
pauthor 299 bob
pauthor 300 alice
pauthor 301 bob
plist '298|2026-10-01T07:00:00Z|2026-10-01T08:00:00Z|2026-10-01T08:00:00Z|bob' '299|2026-10-01T12:40:00Z|2026-10-01T13:00:00Z|2026-10-01T13:00:00Z|bob' '300|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z|2026-10-01T12:00:00Z|alice' '301|2026-10-01T14:00:00Z|2026-10-01T15:00:00Z|2026-10-01T15:00:00Z|bob'
line "$D/s.jsonl" f0 2026-10-01T09:00:00.000Z claude-opus-5-5 1000000 0 0 0
line "$D/s.jsonl" f1 2026-10-01T10:15:00.000Z claude-opus-5-5 250000 0 0 0
line "$D/s.jsonl" f2 2026-10-01T12:15:00.000Z claude-opus-5-5 250000 0 0 0
run 300
check 'a PR whose first commit is before the asked window ends' 0 'PR #300 a (2026-10-01T09:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
total 1 250000 0 0 0 $1.00
peak main context: 250000 tokens'
grep -qx 301 "$GH_DIR/views" || { echo 'FAIL: want PR 301 read when its first commit is before the asked PR ends'; cat "$GH_DIR/views"; fail=1; }
same 300 301

# A first commit authored after the creation (a rebase) doesn't move the bound: the start is the creation, so PR
# 301 (created 14:00) is not read for PR 300.
pr 301 'c' 2026-10-01T14:00:00Z 2026-10-01T15:00:00Z 2026-10-01T16:00:00Z
pauthor 301 bob
: >"$GH_DIR/views"
run 300
check 'a first commit after the creation' 0 'PR #300 a (2026-10-01T09:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 2 1250000 0 0 0 $5.00
total 2 1250000 0 0 0 $5.00
peak main context: 1000000 tokens'
grep -qx 301 "$GH_DIR/views" && { echo 'FAIL: PR 301 read although it starts at its creation, after the asked PR ends'; cat "$GH_DIR/views"; fail=1; }

# A PR with no commits (its `commits` list is empty) and one with a null author in the list don't break the bound.
pr 301 'c' 2026-10-01T14:00:00Z 2026-10-01T15:00:00Z
pauthor 301 bob
plist '298|2026-10-01T07:00:00Z|2026-10-01T08:00:00Z|2026-10-01T08:00:00Z|bob' '299|2026-10-01T12:40:00Z|2026-10-01T13:00:00Z|2026-10-01T13:00:00Z|bob' '300|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z|2026-10-01T12:00:00Z|alice' '301|2026-10-01T14:00:00Z|2026-10-01T15:00:00Z|2026-10-01T15:00:00Z|bob' '302|2026-10-01T13:00:00Z|2026-10-01T13:30:00Z|2026-10-01T13:30:00Z|none'
run 300
check 'no commits, and a null author, in the list' 0 'PR #300 a (2026-10-01T09:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 2 1250000 0 0 0 $5.00
total 2 1250000 0 0 0 $5.00
peak main context: 1000000 tokens'

# The list is read in as many calls as it has pages (100 PRs each), at most two. biglist <total> makes alice's PR
# 100 and 1199 (the one PR she had before it) first, then fillers of hers from before 1199 that never compete.
biglist() {
	jq -n -c --argjson n "$1" '[{number: 100, author: {login: "alice"}, createdAt: "2026-10-01T10:00:00Z", mergedAt: "2026-10-01T12:00:00Z", closedAt: "2026-10-01T12:00:00Z"},
		{number: 1199, author: {login: "alice"}, createdAt: "2026-09-02T00:00:00Z", mergedAt: "2026-09-02T01:00:00Z", closedAt: "2026-09-02T01:00:00Z"}]
		+ [range(1000; 1000 + $n - 2) | {number: ., author: {login: "alice"}, createdAt: "2026-09-01T00:00:00Z", mergedAt: "2026-09-01T01:00:00Z", closedAt: "2026-09-01T01:00:00Z"}]' >"$GH_DIR/list.json"
}
# lists_n: how many pages the last run asked for (the fake gh logs one line a call).
lists_n() { wc -l <"$GH_DIR/lists" | tr -d ' '; }
fresh
pr 100 'a' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
pr 1199 'z' 2026-09-02T00:00:00Z 2026-09-02T01:00:00Z
pauthor 100 alice
pauthor 1199 alice
line "$D/s.jsonl" g1 2026-10-01T10:15:00.000Z claude-opus-5-5 250000 0 0 0
want100='PR #100 a (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
total 1 250000 0 0 0 $1.00
peak main context: 250000 tokens'
biglist 100
: >"$GH_DIR/lists"
run 100
check '100 PRs in the list' 0 "$want100"
[ "$(lists_n)" = 1 ] || { echo 'FAIL: want one page of the list for 100 PRs'; cat "$GH_DIR/lists"; fail=1; }
! grep -q 'newest 200' "$tmp/err" || { echo 'FAIL: warning for a list of 100'; cat "$tmp/err"; fail=1; }
biglist 101
: >"$GH_DIR/lists"
run 100
check '101 PRs in the list' 0 "$want100"
[ "$(lists_n)" = 2 ] || { echo 'FAIL: want two pages of the list for 101 PRs'; cat "$GH_DIR/lists"; fail=1; }
! grep -q 'newest 200' "$tmp/err" || { echo 'FAIL: warning for a list of 101'; cat "$tmp/err"; fail=1; }
biglist 250
: >"$GH_DIR/lists"
run 100
check 'more than 200 PRs in the list' 0 "$want100"
[ "$(lists_n)" = 2 ] || { echo 'FAIL: want two pages of the list for 250 PRs, never a third'; cat "$GH_DIR/lists"; fail=1; }
grep -q 'newest 200' "$tmp/err" || { echo 'FAIL: no warning for the cut list'; cat "$tmp/err"; fail=1; }
# A PR listed on both pages (one was created between the two calls) is not an error.
biglist 101
jq -c '.[100] = .[99]' "$GH_DIR/list.json" >"$GH_DIR/list.tmp" && mv "$GH_DIR/list.tmp" "$GH_DIR/list.json"
run 100
check 'a PR listed twice' 0 "$want100"

# The second page failing is an error, not a shorter list.
touch "$GH_DIR/page2-fails"
run 100
check 'the second page of the list fails' 1 ''
grep -q 'gh api graphql failed' "$tmp/err" || { echo 'FAIL: no message for the failed second page'; cat "$tmp/err"; fail=1; }
rm "$GH_DIR/page2-fails"

# The list call failing exits 1 with its message and prints no table (it is not read as "no earlier PRs").
fresh
pr 67 'y' 2026-10-05T10:00:00Z 2026-10-05T12:00:00Z
rm "$GH_DIR/list.json"
run 67
check 'the list call fails' 1 ''
grep -q 'gh api graphql failed' "$tmp/err" || { echo 'FAIL: no message for the failed list call'; cat "$tmp/err"; fail=1; }

# A response without the list of PRs (an error object, or a repository that came back null), or with a next page
# but no cursor for it, fails the same way: never an empty list.
echo '{"message":"oops"}' >"$GH_DIR/list.json"
run 67
check 'the list response is an object without PRs' 1 ''
grep -q 'something other than a list of PRs' "$tmp/err" || { echo 'FAIL: no message for the odd list'; cat "$tmp/err"; fail=1; }
echo '{"data":{"repository":null}}' >"$GH_DIR/list.json"
run 67
check 'a null repository' 1 ''
grep -q 'something other than a list of PRs' "$tmp/err" || { echo 'FAIL: no message for the null repository'; cat "$tmp/err"; fail=1; }
echo '{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":true,"endCursor":null},"nodes":[]}}}}' >"$GH_DIR/list.json"
run 67
check 'a next page with no cursor' 1 ''
grep -q 'no cursor' "$tmp/err" || { echo 'FAIL: no message for the missing cursor'; cat "$tmp/err"; fail=1; }

# A PR without an author (a deleted account) can't be matched against the list: an error, not "no earlier PRs".
echo '[]' >"$GH_DIR/list.json"
printf '%s\n' '{"title":"ghost","author":null,"state":"MERGED","createdAt":"2026-10-01T10:00:00Z","mergedAt":"2026-10-01T12:00:00Z","closedAt":"2026-10-01T12:00:00Z","commits":[]}' >"$GH_DIR/pr-68.json"
run 68
check 'pr without an author' 1 ''
grep -q 'PR #68' "$tmp/err" || { echo 'FAIL: no message for the PR without an author'; cat "$tmp/err"; fail=1; }

# --- gh failing on one PR exits 1 with its message and prints no table at all.
fresh
pr 50 'abandoned' 2026-10-01T10:00:00Z '' '' 2026-10-01T12:00:00Z
run 50 999
check 'gh pr view fails' 1 ''
grep -q 'no pull request found for 999' "$tmp/err" || { echo 'FAIL: gh error not shown'; cat "$tmp/err"; fail=1; }

# --- a missing transcript dir exits 2.
rm -rf "$P"
run 40
check 'missing transcript dir' 2 ''
grep -q -- "$slug" "$tmp/err" || { echo 'FAIL: error does not name the transcript dir'; cat "$tmp/err"; fail=1; }

# --- the gate's reviewer costs (#110): rows from the cost log for the PR's commits, and for heads since
# rewritten that were logged inside its window. PR 90: window 09:30..12:00, commits a1 a2 a3. PR 91: 14:00..16:00,
# commit b1. PR 92 (not asked for): 10:30..10:45, commit c1.
fresh
pr 90 'g' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z 2026-10-01T09:30:00Z '' a1,a2,a3
pr 91 'h' 2026-10-01T14:00:00Z 2026-10-01T16:00:00Z '' '' b1
pr 92 'o' 2026-10-01T10:30:00Z 2026-10-01T10:45:00Z '' '' c1
plist '90|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z|2026-10-01T12:00:00Z' '91|2026-10-01T14:00:00Z|2026-10-01T16:00:00Z|2026-10-01T16:00:00Z' '92|2026-10-01T10:30:00Z|2026-10-01T10:45:00Z|2026-10-01T10:45:00Z'
line "$D/s.jsonl" g1 2026-10-01T10:15:00.000Z claude-opus-5-5 250000 0 0 0
COSTS=$tmp/costs.jsonl
# PR 90's commits: two finders and a verifier, one of the finders logged before the window (a commit match
# doesn't need the date) and failed (rc 1) but still cost.
gate 2026-10-01T11:00:00Z acme/app a1 finder sonnet 0.05
gate 2026-10-01T08:00:00Z acme/app a2 finder sonnet 0.10 1
# The gate logs the repo as spelled in the push URL: any case still matches.
gate 2026-10-01T11:01:00Z Acme/App a1 verifier haiku 0.01
# The same head in another repo: not this PR's.
gate 2026-10-01T11:02:00Z other/app a1 finder sonnet 9
# A head that is another PR's commit (c1, PR 92, not asked for) never counts by window, even inside PR 90's.
gate 2026-10-01T10:40:00Z acme/app c1 finder sonnet 8
# An unknown head (a rewritten commit) logged inside PR 90's window: PR 90's. Logged at 10:40, where PR 92's
# window (the later-started) also holds it: PR 92's, so dropped. Logged at 13:00, in no window: nobody's.
gate 2026-10-01T11:10:00Z acme/app zz finder sonnet 0.20
gate 2026-10-01T10:40:00Z acme/app zy finder sonnet 7
gate 2026-10-01T13:00:00Z acme/app zx finder sonnet 6
# PR 91: a commit match, and an unknown head in its window.
gate 2026-10-01T14:30:00Z acme/app b1 finder sonnet 0.30
gate 2026-10-01T15:00:00Z acme/app zw verifier haiku 0.02
# Lines the script can't use: not JSON, JSON without the fields, and a blank line (not counted).
printf '%s\n' 'not json' '{"repo":"acme/app"}' '' >>"$tmp/costs.jsonl"
want90='PR #90 g (2026-10-01T09:30:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
gate finder sonnet 3 - - - - $0.35
gate verifier haiku 1 - - - - $0.01
total 5 250000 0 0 0 $1.36
peak main context: 250000 tokens'
run 90 91
check 'gate rows' 0 "$want90

PR #91 h (2026-10-01T14:00:00 → 2026-10-01T16:00:00)
role model requests input output cache read cache write cost
gate finder sonnet 1 - - - - \$0.30
gate verifier haiku 1 - - - - \$0.02
total 2 0 0 0 0 \$0.32"
[ "$(nomainless | wc -l)" = 1 ] && grep -q '^token-report.sh: skipped 2 unreadable line(s) in .*costs.jsonl' "$tmp/err" ||
	{ echo 'FAIL: want one warning counting the 2 unreadable log lines'; cat "$tmp/err"; fail=1; }
# A PR's rows are the same asked alone.
run 90
check 'gate rows, PR alone' 0 "$want90"

# A run with no cost (cost_usd null) makes its group and the total ?; the priced group stays priced.
fresh
pr 93 'n' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z '' '' d1
COSTS=$tmp/costs.jsonl
gate 2026-10-01T10:10:00Z acme/app d1 finder sonnet 0.05
gate 2026-10-01T10:11:00Z acme/app d1 finder sonnet null
gate 2026-10-01T10:12:00Z acme/app d1 verifier haiku 0.01
run 93
check 'gate run without a cost' 0 'PR #93 n (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
gate finder sonnet 2 - - - - ?
gate verifier haiku 1 - - - - $0.01
total 3 0 0 0 0 ?'
[ -z "$(nomainless)" ] || { echo 'FAIL: unexpected stderr (clean log)'; cat "$tmp/err"; fail=1; }

# A log with nothing for the PR, or an empty one, reads like no log at all.
: >"$tmp/costs.jsonl"
gate 2026-10-05T10:10:00Z acme/app nothere finder sonnet 5
run 93
check 'log without rows for the PR' 0 'PR #93 n (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
no usage found'
: >"$tmp/costs.jsonl"
run 93
check 'empty log' 0 'PR #93 n (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
no usage found'

# --- sessions started in a worktree log under that directory's slug (#248): the repo's worktrees and the removed
# `.claude/worktrees` ones are read too, and a look-alike repo's dir (`${slug}-other`) is not.
fresh
pr 300 'wt' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
wtslug=$(cd "$tmp/wt" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')
line "$D/s.jsonl" w1 2026-10-01T10:15:00.000Z claude-opus-5-5 250000 0 0 0
line "$P/$wtslug/s.jsonl" w2 2026-10-01T10:30:00.000Z claude-opus-5-5 250000 0 0 0
A=$P/$wtslug/s/subagents/agent-w.jsonl
line "$A" w3 2026-10-01T11:00:00.000Z claude-sonnet-5-5 1000000 0 0 0
meta "$A" '{"agentType":"ship-implementer"}'
line "$P/$slug--claude-worktrees-agent-1/s.jsonl" w4 2026-10-01T10:40:00.000Z claude-opus-5-5 250000 0 0 0
line "$P/$slug-other/s.jsonl" w5 2026-10-01T10:45:00.000Z claude-opus-5-5 9000000 0 0 0
line "$P/$slug-claude-worktrees-x/s.jsonl" w6 2026-10-01T10:46:00.000Z claude-opus-5-5 9000000 0 0 0
run 300
check 'sessions in worktrees' 0 'PR #300 wt (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 3 750000 0 0 0 $3.00
ship-implementer claude-sonnet-5-5 1 1000000 0 0 0 $2.00
total 4 1750000 0 0 0 $5.00
peak main context: 250000 tokens'
[ ! -s "$tmp/err" ] || { echo 'FAIL: unexpected stderr (sessions in worktrees)'; cat "$tmp/err"; fail=1; }
cp "$tmp/out" "$tmp/out.wt"
run -C "$tmp/wt" 300
check 'sessions in worktrees, run from a worktree' 0 "$(cat "$tmp/out.wt")"

# A printed PR with subagent rows but no main row (its main session may have run in a worktree that is gone)
# warns on stderr; the table is unchanged.
fresh
pr 301 'nomain' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
A=$D/s/subagents/agent-n.jsonl
line "$A" n1 2026-10-01T10:10:00.000Z claude-sonnet-5-5 1000000 0 0 0
meta "$A" '{"agentType":"ship-implementer"}'
run 301
check 'subagent rows without a main row' 0 'PR #301 nomain (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
ship-implementer claude-sonnet-5-5 1 1000000 0 0 0 $2.00
total 1 1000000 0 0 0 $2.00
peak main context: 0 tokens'
grep -q '^token-report.sh: PR #301 has subagent or gate rows but no main-session row' "$tmp/err" ||
	{ echo 'FAIL: no warning for a PR without a main row'; cat "$tmp/err"; fail=1; }

# A repo whose sessions all ran in worktrees has no dir for the main checkout: that is no reason to exit 2.
fresh
rmdir "$D"
pr 302 'wtonly' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
line "$P/$wtslug/s.jsonl" o1 2026-10-01T10:15:00.000Z claude-opus-5-5 250000 0 0 0
run 302
check 'transcripts only in a worktree dir' 0 'PR #302 wtonly (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
total 1 250000 0 0 0 $1.00
peak main context: 250000 tokens'
[ ! -s "$tmp/err" ] || { echo 'FAIL: unexpected stderr (transcripts only in a worktree dir)'; cat "$tmp/err"; fail=1; }

# --- --since and --summary (#249).
# Bad arguments exit 2: a missing or repeated --since, a date that is not one, --summary alone.
fresh
run --since
check '--since without a date' 2 ''
run --since abc 10
check '--since with a non-date' 2 ''
run --since 2026-13-45
check '--since with an impossible date' 2 ''
run --since 2026-02-30
check '--since with a day the month lacks' 2 ''
run --since 2027-02-29
check '--since with a leap day in a common year' 2 ''
run --since 2026-10-01 --since 2026-10-02
check '--since twice' 2 ''
run --since 2026-10-01 -x
check 'an unknown option' 2 ''
run --summary
check '--summary alone' 2 ''
grep -q '^usage:.*--since YYYY-MM-DD' "$tmp/err" || { echo 'FAIL: usage does not mention --since'; fail=1; }

# --since selects the repo's PRs (whoever wrote them) created on or after the date, oldest first, after any PR
# numbers given; a PR both given and selected is reported once.
fresh
for n in 30 31 32 33; do
	pr "$n" "p$n" "2026-10-0$((n - 29))T10:00:00Z" "2026-10-0$((n - 29))T12:00:00Z"
done
plist '30|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z' '31|2026-10-02T10:00:00Z|2026-10-02T12:00:00Z' \
	'32|2026-10-03T10:00:00Z|2026-10-03T12:00:00Z' '33|2026-10-04T10:00:00Z|2026-10-04T12:00:00Z||other'
run --since 2026-10-02
check '--since selection' 0 'PR #31 p31 (2026-10-02T10:00:00 → 2026-10-02T12:00:00)
no usage found

PR #32 p32 (2026-10-03T10:00:00 → 2026-10-03T12:00:00)
no usage found

PR #33 p33 (2026-10-04T10:00:00 → 2026-10-04T12:00:00)
no usage found'
run 33 --since 2026-10-03 33
check '--since with PR numbers' 0 'PR #33 p33 (2026-10-04T10:00:00 → 2026-10-04T12:00:00)
no usage found

PR #32 p32 (2026-10-03T10:00:00 → 2026-10-03T12:00:00)
no usage found'
# The date's own midnight counts; a PR created the second before does not.
plist '30|2026-10-01T23:59:59Z|2026-10-01T12:00:00Z' '31|2026-10-02T00:00:00Z|2026-10-02T12:00:00Z'
run --since 2026-10-02
check '--since at midnight' 0 'PR #31 p31 (2026-10-02T10:00:00 → 2026-10-02T12:00:00)
no usage found'
# Nothing selected: a note, no output, exit 0.
run --since 2026-11-01
check '--since with no PR' 0 ''
grep -q '^token-report.sh: no PRs created since 2026-11-01' "$tmp/err" || { echo 'FAIL: no note for an empty --since'; cat "$tmp/err"; fail=1; }
# A PR with no author can't be windowed: left out of the selection with a warning, not an error.
plist '31|2026-10-02T10:00:00Z|2026-10-02T12:00:00Z' '32|2026-10-03T10:00:00Z|2026-10-03T12:00:00Z||none'
run --since 2026-10-02
check '--since with a PR with no author' 0 'PR #31 p31 (2026-10-02T10:00:00 → 2026-10-02T12:00:00)
no usage found'
grep -q '^token-report.sh: left out 1 PR(s) with no author' "$tmp/err" || { echo 'FAIL: no warning for a PR with no author'; cat "$tmp/err"; fail=1; }

# --summary: totals by role and model, the cost per PR, the costliest PRs, the main session's peak context and the
# implementer's cache read per request.
fresh
pr 20 'feat: a' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
pr 21 'feat: b' 2026-10-02T10:00:00Z 2026-10-02T12:00:00Z
line "$D/s20.jsonl" m1 2026-10-01T10:30:00.000Z claude-opus-5-5 250000 0 0 0
A=$D/s20/subagents/agent-i.jsonl
line "$A" a1 2026-10-01T11:00:00.000Z claude-sonnet-5-5 1000000 0 0 0
line "$A" a2 2026-10-01T11:10:00.000Z claude-sonnet-5-5 0 0 500000 0
meta "$A" '{"agentType":"ship-implementer"}'
line "$D/s21.jsonl" m2 2026-10-02T10:30:00.000Z claude-opus-5-5 500000 0 0 0
A=$D/s21/subagents/agent-i.jsonl
line "$A" b1 2026-10-02T11:00:00.000Z claude-sonnet-5-5 0 0 100000 0
meta "$A" '{"agentType":"ship-implementer"}'
plist '20|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z' '21|2026-10-02T10:00:00Z|2026-10-02T12:00:00Z'
run 20 21
check 'no summary without the flag' 0 'PR #20 feat: a (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
ship-implementer claude-sonnet-5-5 2 1000000 0 500000 0 $2.10
total 3 1250000 0 500000 0 $3.10
peak main context: 250000 tokens

PR #21 feat: b (2026-10-02T10:00:00 → 2026-10-02T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 500000 0 0 0 $2.00
ship-implementer claude-sonnet-5-5 1 0 0 100000 0 $0.02
total 2 500000 0 100000 0 $2.02
peak main context: 500000 tokens'
cp "$tmp/out" "$tmp/out.nosum"
run --summary 20 21
check '--summary' 0 "$(cat "$tmp/out.nosum")

Summary: usage found for 2 of 2 PRs
role model cost share
main claude-opus-5-5 \$3.00 58.6%
ship-implementer claude-sonnet-5-5 \$2.12 41.4%
total \$5.12 100.0%
cost per PR: mean \$2.56, median \$2.56, max \$3.10
costliest PRs:
#20 \$3.10 feat: a
#21 \$2.02 feat: b
peak main context: mean 375000 tokens, max 500000 tokens
implementer cache read: mean 200000 tokens per request (3 requests)"
[ ! -s "$tmp/err" ] || { echo 'FAIL: unexpected stderr (--summary)'; cat "$tmp/err"; fail=1; }
# The flags combine: --since picks the same two PRs, and with a PR number the PR is not counted twice.
cp "$tmp/out" "$tmp/out.sum"
run --since 2026-10-01 --summary
check '--since --summary' 0 "$(cat "$tmp/out.sum")"
run --summary --since 2026-10-02 20
check '--summary with --since and a PR number' 0 "$(cat "$tmp/out.sum")"

# Five costliest only: seven PRs, the two cheapest are not listed (a tie goes to the lower number).
fresh
for n in 40 41 42 43 44 45 46; do
	d=$((n - 39))
	pr "$n" "p$n" "2026-10-0${d}T10:00:00Z" "2026-10-0${d}T12:00:00Z"
	# 250000 input tokens on Opus are $1.00; PRs 43 and 44 cost the same.
	case $n in 43 | 44) u=4 ;; 45) u=5 ;; 46) u=6 ;; *) u=$((n - 39)) ;; esac
	line "$D/s$n.jsonl" "r$n" "2026-10-0${d}T10:30:00.000Z" claude-opus-5-5 $((u * 250000)) 0 0 0
done
run --summary 40 41 42 43 44 45 46
sed -n '/^costliest/,/^peak/p' "$tmp/out" >"$tmp/top"
[ "$(cat "$tmp/top")" = 'costliest PRs:
#46 $6.00 p46
#45 $5.00 p45
#43 $4.00 p43
#44 $4.00 p44
#42 $3.00 p42
peak main context: mean 892857 tokens, max 1500000 tokens' ] || { echo 'FAIL: top 5 costliest'; cat "$tmp/top"; fail=1; }
grep -q '^cost per PR: mean \$3.57, median \$4.00, max \$6.00$' "$tmp/out" || { echo 'FAIL: mean/median of 7 PRs'; cat "$tmp/out"; fail=1; }

# An unpriced row (a model with no price) makes its PR's cost ?: the PR is left out of the cost sums, and its row
# of the role table with it, with a count of the PRs affected. Its tokens still count for the peak context.
fresh
pr 20 'feat: a' 2026-10-01T10:00:00Z 2026-10-01T12:00:00Z
pr 22 'feat: c' 2026-10-03T10:00:00Z 2026-10-03T12:00:00Z
line "$D/s20.jsonl" m1 2026-10-01T10:30:00.000Z claude-opus-5-5 250000 0 0 0
line "$D/s22.jsonl" m3 2026-10-03T10:30:00.000Z claude-mystery-1 100000 0 0 0
plist '20|2026-10-01T10:00:00Z|2026-10-01T12:00:00Z' '22|2026-10-03T10:00:00Z|2026-10-03T12:00:00Z'
run --summary 20 22
check '--summary with an unpriced row' 0 'PR #20 feat: a (2026-10-01T10:00:00 → 2026-10-01T12:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 250000 0 0 0 $1.00
total 1 250000 0 0 0 $1.00
peak main context: 250000 tokens

PR #22 feat: c (2026-10-03T10:00:00 → 2026-10-03T12:00:00)
role model requests input output cache read cache write cost
main claude-mystery-1 1 100000 0 0 0 ?
total 1 100000 0 0 0 ?
peak main context: 100000 tokens

Summary: usage found for 2 of 2 PRs
role model cost share
main claude-opus-5-5 $1.00 100.0%
total $1.00 100.0%
left out of the cost sums: 1 PR(s) with a ? cost
cost per PR: mean $1.00, median $1.00, max $1.00
costliest PRs:
#20 $1.00 feat: a
peak main context: mean 175000 tokens, max 250000 tokens
implementer cache read: no implementer requests'
grep -q '^token-report.sh: no price for model claude-mystery-1' "$tmp/err" || { echo 'FAIL: no price warning (--summary)'; cat "$tmp/err"; fail=1; }

# Only unpriced PRs, or no usage at all: the summary says so instead of printing zeros.
run --summary 22
check '--summary, every PR unpriced' 0 'PR #22 feat: c (2026-10-03T10:00:00 → 2026-10-03T12:00:00)
role model requests input output cache read cache write cost
main claude-mystery-1 1 100000 0 0 0 ?
total 1 100000 0 0 0 ?
peak main context: 100000 tokens

Summary: usage found for 1 of 1 PRs
left out of the cost sums: 1 PR(s) with a ? cost
cost per PR: no priced PR
peak main context: mean 100000 tokens, max 100000 tokens
implementer cache read: no implementer requests'
fresh
pr 23 'feat: d' 2026-10-04T10:00:00Z 2026-10-04T12:00:00Z
run --summary 23
check '--summary, no usage' 0 'PR #23 feat: d (2026-10-04T10:00:00 → 2026-10-04T12:00:00)
no usage found

Summary: usage found for 0 of 1 PRs'

# --- both new scripts are committed executable (a hook or the skill runs them as commands).
for f in skills/ship/token-report.sh tests/token-report.sh; do
	case $(git -C "$root" ls-files -s "$f") in
	100755*) ;;
	*) echo "FAIL: $f is not mode 100755 in the index"; fail=1 ;;
	esac
done

[ "$fail" = 0 ] && echo "token-report tests passed"
exit "$fail"
