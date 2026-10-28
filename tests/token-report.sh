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

# fresh: empties the fixtures and the transcript dir.
fresh() {
	rm -rf "$GH_DIR" "$P"
	mkdir -p "$GH_DIR" "$D"
}

# pr <n> <title> <created> <merged or empty> [<first commit authored> [<closed at>]]
# With <closed at> and no <merged>, the PR is closed without merging; with neither it is open.
pr() {
	jq -n --arg t "$2" --arg c "$3" --arg m "$4" --arg a "${5:-}" --arg x "${6:-}" \
		'{title:$t,createdAt:$c,mergedAt:(if $m == "" then null else $m end),
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
# 1 s before the window starts and 1 s after it ends: not counted.
line "$S.jsonl" req_early 2026-10-01T09:29:59.900Z claude-opus-5-5 9000000 0 0 0
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

PR #21 two (2026-10-01T11:00:00 → 2026-10-01T13:00:00)
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

PR #51 later (2026-10-20T09:00:00 → 2026-10-20T11:00:00)
role model requests input output cache read cache write cost
main claude-opus-5-5 1 500000 0 0 0 $2.00
total 1 500000 0 0 0 $2.00
peak main context: 500000 tokens'

# A closed PR with no closedAt is an error, not an open one that runs to now.
printf '%s\n' '{"title":"odd","state":"CLOSED","createdAt":"2026-10-01T10:00:00Z","mergedAt":null,"closedAt":null,"commits":[]}' >"$GH_DIR/pr-52.json"
run 52
if [ "$rc" = 0 ] || [ -s "$tmp/out" ]; then
	echo "FAIL: closed PR without closedAt (exit $rc)"
	cat "$tmp/out"
	fail=1
fi
grep -q 'PR #52' "$tmp/err" || { echo 'FAIL: no message for the closed PR without closedAt'; cat "$tmp/err"; fail=1; }

# --- gh failing on one PR exits 1 with its message and prints no table at all.
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
