#!/bin/sh
# Tests skills/ship/token-report.sh: per-PR usage and cost from Claude Code transcripts. The fake gh serves
# `repo view` and `pr view <n>` from fixture files; transcripts are built under a fake projects dir whose
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
	cat "$GH_DIR/pr-$3.json"
	;;
"pr list")
	[ -f "$GH_DIR/list.json" ] || { echo "pr list failed" >&2; exit 1; }
	[ "$3 $4 $5 $6 $7 $8" = "-R acme/app --author me --state all" ] || { echo "gh pr list with wrong arguments: $*" >&2; exit 1; }
	cat "$GH_DIR/list.json"
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

# fresh: empties the fixtures and the transcript dir; the author has no PR besides the ones given to plist.
fresh() {
	rm -rf "$GH_DIR" "$P"
	mkdir -p "$GH_DIR" "$D"
	echo '[]' >"$GH_DIR/list.json"
}

# plist <n|created|merged|closed>...: what `gh pr list` returns for the author (an empty field is null).
plist() {
	printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(. != "") | split("|") as $f
		| {number: ($f[0] | tonumber), createdAt: $f[1], mergedAt: (if $f[2] == "" then null else $f[2] end),
		closedAt: (if $f[3] == "" then null else $f[3] end)})' >"$GH_DIR/list.json"
}

# pr <n> <title> <created> <merged or empty> [<first commit authored> [<closed at>]]
# With <closed at> and no <merged>, the PR is closed without merging; with neither it is open.
pr() {
	jq -n --arg t "$2" --arg c "$3" --arg m "$4" --arg a "${5:-}" --arg x "${6:-}" \
		'{title:$t,author:{login:"me"},createdAt:$c,mergedAt:(if $m == "" then null else $m end),
		state:(if $m != "" then "MERGED" elif $x != "" then "CLOSED" else "OPEN" end),
		closedAt:(if $m != "" then $m elif $x != "" then $x else null end),
		commits:(if $a == "" then [] else [{authoredDate:$a}] end)}' >"$GH_DIR/pr-$1.json"
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
	(cd "$dir" && PATH=$tmp/bin:$PATH CLAUDE_PROJECTS_DIR=$P sh "$root/skills/ship/token-report.sh" "$@") >"$tmp/raw" 2>"$tmp/err"
	rc=$?
	tr -s ' ' <"$tmp/raw" >"$tmp/out"
}

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

# `gh pr list` failing exits 1 with its message and prints no table (it is not read as "no earlier PRs").
fresh
pr 67 'y' 2026-10-05T10:00:00Z 2026-10-05T12:00:00Z
rm "$GH_DIR/list.json"
run 67
check 'gh pr list fails' 1 ''
grep -q 'gh pr list' "$tmp/err" || { echo 'FAIL: no message for the failed pr list'; cat "$tmp/err"; fail=1; }

# `gh pr list` returning something that isn't a list fails the same way.
echo '{"message":"oops"}' >"$GH_DIR/list.json"
run 67
check 'gh pr list returns an object' 1 ''
grep -q 'gh pr list' "$tmp/err" || { echo 'FAIL: no message for the odd pr list'; cat "$tmp/err"; fail=1; }

# A PR without an author (a deleted account) can't be matched against the list: an error, not "no earlier PRs".
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

# --- both new scripts are committed executable (a hook or the skill runs them as commands).
for f in skills/ship/token-report.sh tests/token-report.sh; do
	case $(git -C "$root" ls-files -s "$f") in
	100755*) ;;
	*) echo "FAIL: $f is not mode 100755 in the index"; fail=1 ;;
	esac
done

[ "$fail" = 0 ] && echo "token-report tests passed"
exit "$fail"
