#!/bin/sh
# Prints each PR's Claude Code usage and API-price cost, split by role (the main session, then each
# subagent type) and model, plus the main session's peak context and the gate's reviewer runs (`gate <stage>` rows,
# from its cost log). Run it from a checkout of the repo: it reads only this repo's transcripts
# (~/.claude/projects/<slug>, or $CLAUDE_PROJECTS_DIR/<slug>), the gate's cost log (~/.claude/state/review-costs.jsonl,
# or $CLAUDE_REVIEW_COSTS) and `gh`, keeps no state, and calls no model. How requests and gate runs are attributed
# to PRs: docs/scripts.md.
# Usage: token-report.sh <pr> [<pr>...]
set -eu

# USD per MTok (the claude-api skill's shared/models.md and model-migration.md, cached 2026-11-11). w5 and w1 are
# the 5-minute and 1-hour cache writes (1.25x and 2x the input rate); `big` replaces `std` when a request's prompt
# (input + cache read + cache write) is over 100k tokens. Issue #70 says Sonnet cache reads cost $0.10; the skill
# docs say $0.20. The older models (#247) have one rate at any prompt length, and a cache read is 0.1x input.
prices='{
	"claude-opus-5-5":   {"std": {"i": 4.00, "o": 20.00, "cr": 0.20, "w5": 5.00,  "w1": 8.00}},
	"claude-opus-4-8":   {"std": {"i": 5.00, "o": 25.00, "cr": 0.50, "w5": 6.25,  "w1": 10.00}},
	"claude-opus-4-7":   {"std": {"i": 5.00, "o": 25.00, "cr": 0.50, "w5": 6.25,  "w1": 10.00}},
	"claude-opus-4-6":   {"std": {"i": 5.00, "o": 25.00, "cr": 0.50, "w5": 6.25,  "w1": 10.00}},
	"claude-sonnet-5-5": {"std": {"i": 2.00, "o": 10.00, "cr": 0.20, "w5": 2.50,  "w1": 4.00}},
	"claude-sonnet-4-6": {"std": {"i": 3.00, "o": 15.00, "cr": 0.30, "w5": 3.75,  "w1": 6.00}},
	"claude-haiku-4-5":  {"std": {"i": 1.00, "o": 5.00,  "cr": 0.10, "w5": 1.25,  "w1": 2.00}},
	"claude-haiku-5-5":  {"std": {"i": 0.10, "o": 0.50,  "cr": 0.01, "w5": 0.125, "w1": 0.20},
	                      "big": {"i": 0.50, "o": 2.50,  "cr": 0.05, "w5": 0.625, "w1": 1.00}}
}'

# A missing or odd PR number exits 2 (usage), so a caller never reads it as a result.
usage() {
	echo "usage: token-report.sh <pr> [<pr>...]" >&2
	exit 2
}
[ "$#" -gt 0 ] || usage
# `asked` is the PR numbers, one per line: a PR given twice counts once (#166), in the order first given, and
# leading zeros are dropped first (010 is 10), or the window and its requests would be counted twice.
asked=
for pr in "$@"; do
	case $pr in
	'' | *[!0-9]*) usage ;;
	esac
	while :; do
		case $pr in
		0?*) pr=${pr#0} ;;
		*) break ;;
		esac
	done
	asked="$asked $pr"
done
# shellcheck disable=SC2086 # PR numbers: digits only
asked=$(printf '%s\n' $asked | awk '!seen[$0]++')

# Claude Code names a project's transcript dir after its path with every non-alphanumeric turned into `-`.
# The git common dir is the main checkout's, so this works from a worktree too.
common=$(git rev-parse --path-format=absolute --git-common-dir) || {
	echo "token-report.sh: not in a git repository" >&2
	exit 2
}
top=${common%/.git}
slug=$(printf %s "$top" | tr -c 'A-Za-z0-9' '-')
dir=${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}/$slug
if [ ! -d "$dir" ]; then
	echo "token-report.sh: no transcripts at $dir" >&2
	exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Each call is its own assignment (a pipeline would report only its last command), and every PR is read
# before anything is printed, so a failing `gh` leaves no partial table.
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# window <pr> <true|false> <file>: appends the PR's own window to <file>; the second argument says whether the PR
# was asked for (the report prints only those, but the repo's other PRs compete for every request).
window() {
	info=$(gh pr view "$1" -R "$repo" --json title,state,author,createdAt,mergedAt,closedAt,commits) || {
		echo "token-report.sh: gh pr view $1 failed" >&2
		exit 1
	}
	# The window ends at the merge, else at the close of a PR closed unmerged, else now (open); any other state is
	# an error, and so is a PR with no author (its earlier PRs can't be listed). Times are cut to
	# YYYY-MM-DDTHH:MM:SS (transcripts carry milliseconds).
	printf '%s\n' "$info" | jq -c --argjson pr "$1" --argjson asked "$2" --arg now "$now" '
		(.author.login // "") as $a
		| (.mergedAt // "") as $m
		| (.closedAt // "") as $x
		| (if $m != "" then {end: $m, status: "merged"}
			elif .state == "CLOSED" and $x != "" then {end: $x, status: "closed"}
			elif .state == "OPEN" then {end: $now, status: "open"}
			else error("PR #\($pr) is \(.state) with no merge or close time") end) as $e
		| if $a == "" then error("PR #\($pr) has no author") else . end
		| {pr: $pr, asked: $asked, author: $a, title: ((.title // "") | gsub("[\t\n\r]"; " ")),
			start: ([.createdAt, (.commits[0].authoredDate // empty)] | map(.[0:19]) | min),
			end: $e.end[0:19], status: $e.status, commits: [.commits[]?.oid | select(type == "string")]}' >>"$3" || exit 1
}
: >"$tmp/windows"
# shellcheck disable=SC2086 # PR numbers: digits only
for pr in $asked; do
	window "$pr" true "$tmp/windows"
done

# Every PR of the repo, whoever wrote it, listed once (#130): they all compete for every request, so a PR's row
# can't depend on which authors' PRs are asked for. When each PR ended is also where the work on its author's
# next one can start. A failed or odd listing is an error, never "no earlier PRs" (the window would then reach
# back to the session's start). The list has no commit dates, so the other PRs get windows below with `gh pr view`.
list=$(gh pr list -R "$repo" --state all --limit 200 --json number,author,createdAt,mergedAt,closedAt) || {
	echo "token-report.sh: gh pr list failed" >&2
	exit 1
}
printf '%s\n' "$list" | jq -c 'if type == "array" then map({number, author: (.author.login // ""), createdAt, mergedAt, closedAt}) else error("not a list") end' >"$tmp/list" || {
	echo "token-report.sh: gh pr list returned something other than a list" >&2
	exit 1
}
# A full page may have cut the repo's older PRs short (the list is newest first): they can't compete.
listed=$(jq 'length' "$tmp/list") || exit 1
if [ "$listed" -ge 200 ]; then
	echo "token-report.sh: gh pr list returned the newest 200 PRs; older PRs don't compete for requests" >&2
	# An asked PR that starts at or before the oldest listed one may have a previous PR the list cut off (or isn't
	# listed itself): its window would silently reach back to the session's start, so it is an error.
	oldest=$(jq -r '[.[].createdAt | select(type == "string") | .[0:19]] | min // ""' "$tmp/list") || exit 1
	jq -r --arg o "$oldest" 'select(.start <= $o) | .pr' "$tmp/windows" >"$tmp/toolate" || exit 1
	if [ -s "$tmp/toolate" ]; then
		echo "token-report.sh: PR #$(head -n 1 "$tmp/toolate") starts before the oldest of the newest 200 PRs; its previous PR can't be found" >&2
		exit 1
	fi
fi
# prevend <in> <out>: adds prevEnd to each window: the latest end (merge, else close) strictly before the PR's
# start of any other PR by its author; "" when there is none. A PR still open has no end.
prevend() {
	jq -c --slurpfile l "$tmp/list" '
		. as $w
		| . + {prevEnd: ([$l[0][] | select(.author == $w.author and .number != $w.pr)
			| (.mergedAt // .closedAt) | select(type == "string") | .[0:19] | select(. < $w.start)] | max // "")}' \
		"$1" >"$2" || exit 1
}
prevend "$tmp/windows" "$tmp/windows2"

# The other PRs compete for every request too (see the jq below), so they get windows the same way, each read
# with `gh pr view`, but only those that can overlap a window of an asked PR (#129), bounded on both sides:
# - below: one that ended before the earliest prevEnd can't hold a request of any of them. No bound when an
#   asked PR has no earlier PR ($lo is "").
# - above: one that starts after the latest end of the asked PRs ($hi; "9999" while one is still open) can't
#   either. Its start is not only its creation, though: its window widens back to the end of its own author's
#   previous PR, so a PR created later but whose previous PR ended before $hi is kept. (The list has no commit
#   dates, so a first commit authored before the creation isn't seen; that window is not widened by it here.)
# A PR whose author is deleted is left out: its earlier PRs can't be listed, so it has no widened window (an
# asked one is an error, in `window`).
jq -r -n --slurpfile w "$tmp/windows2" --slurpfile l "$tmp/list" '
	($w | map(.pr)) as $asked
	| ($w | map(.prevEnd) | min) as $lo
	| ($w | map(if .status == "open" then "9999" else .end end) | max) as $hi
	| $l[0] as $L
	| [$L[] | select(.author != "") | select(.number as $n | $asked | index($n) == null)
		| . as $p
		| ($p.createdAt[0:19]) as $c
		| ([$L[] | select(.author == $p.author and .number != $p.number)
			| (.mergedAt // .closedAt) | select(type == "string") | .[0:19] | select(. < $c)] | max // "") as $pe
		| select((.mergedAt // .closedAt // "9999")[0:19] >= $lo)
		| select($c <= $hi or $pe < $hi) | .number] | unique[]' >"$tmp/others.n" || exit 1
: >"$tmp/windowsO"
while IFS= read -r n; do
	window "$n" false "$tmp/windowsO"
done <"$tmp/others.n"
prevend "$tmp/windowsO" "$tmp/windowsO2"
cat "$tmp/windows2" "$tmp/windowsO2" >"$tmp/windowsAll"

# The gate's reviewer costs (#110): one row per reviewer run in the gate's cost log. Lines that aren't a row (not
# JSON, or missing repo, head, stage or date) are skipped with one warning, so a corrupt log isn't read as cheap.
# A cost that isn't a number is kept as unpriced (null); costs become nano-dollars like the transcripts'.
costs=${CLAUDE_REVIEW_COSTS:-$HOME/.claude/state/review-costs.jsonl}
: >"$tmp/gate.raw"
if [ -f "$costs" ]; then
	jq -n -R -c '
		inputs | select(. != "")
		| (try fromjson catch null) as $o
		| if ($o | type) == "object" and ($o.repo | type) == "string" and ($o.head | type) == "string"
			and ($o.stage | type) == "string" and ($o.date | type) == "string"
		  then {repo: $o.repo, head: $o.head, date: $o.date[0:19], stage: ($o.stage | gsub("[\t\n\r]"; " ")),
			model: (if ($o.model | type) == "string" then $o.model | gsub("[\t\n\r]"; " ") else "unknown" end),
			c: (if ($o.cost_usd | type) == "number" then $o.cost_usd * 1000000000 | round else null end)}
		  else "bad" end' "$costs" >"$tmp/gate.raw" || {
		echo "token-report.sh: can't read $costs" >&2
		exit 1
	}
fi
jq -c 'select(type == "object")' "$tmp/gate.raw" >"$tmp/gate" || exit 1
bad=$(jq -s 'map(select(type == "string")) | length' "$tmp/gate.raw") || exit 1
[ "$bad" = 0 ] || echo "token-report.sh: skipped $bad unreadable line(s) in $costs" >&2

# One record per request: a request spans several transcript lines, so keep the one with the most output.
# Cache writes: the 5m/1h split, with any remainder of the total priced as 5m.
extract() {
	jq -n -R -c --arg f "$1" --arg k "$2" --arg role "$3" '
		[inputs | fromjson?
			| select(type == "object" and .type == "assistant" and (.requestId | type == "string")
				and (.timestamp | type == "string") and (.message | type == "object")
				and (.message.usage | type == "object") and .message.model != "<synthetic>")]
		| group_by(.requestId) | .[] | max_by(.message.usage.output_tokens // 0)
		| .message.usage as $u
		| ($u.cache_creation_input_tokens // 0) as $cc
		| ($u.cache_creation.ephemeral_5m_input_tokens // 0) as $w5
		| ($u.cache_creation.ephemeral_1h_input_tokens // 0) as $w1
		| {f: $f, k: $k, role: ($role | gsub("[\t\n\r]"; " ")), ts: .timestamp[0:19],
			model: (.message.model // "unknown"), i: ($u.input_tokens // 0), o: ($u.output_tokens // 0),
			cr: ($u.cache_read_input_tokens // 0), w5: ($w5 + ([$cc - $w5 - $w1, 0] | max)), w1: $w1}' "$1" >>"$tmp/records"
}
: >"$tmp/records"
for f in "$dir"/*.jsonl; do
	[ -f "$f" ] || continue
	extract "$f" main main
done
for f in "$dir"/*/subagents/agent-*.jsonl; do
	[ -f "$f" ] || continue
	role=
	if [ -f "${f%.jsonl}.meta.json" ]; then
		role=$(jq -r '(.agentType // empty) | select(type == "string")' "${f%.jsonl}.meta.json" 2>/dev/null) || role=
	fi
	extract "$f" sub "${role:-subagent}"
done

# Report lines, tab separated: H header, N no usage, R row, T total, P peak, W model without a price.
# Costs are integer nano-dollars (tokens x $/MTok x 1000), so rounding to the cent is exact.
# Windows (#80): a PR's cost includes the main-session work that led to it, which mostly comes before its first
# commit (planning, exploring). So a window's start widens from the PR's own start (start0) back to the later of
# the end of the author's previous PR (prevEnd) and the first request of the main session(s) that worked in the
# PR's own window, but never to after start0. Work after the last merge belongs to no window. A request inside
# some PR's own window goes to the latest-started of those; only a request in none goes to the latest-started
# widened window, so widening never takes work from an overlapping PR. Every window is built and every request
# assigned across all the PRs that could matter (the asked ones and the repo's others that could overlap, read above), by the
# same rules; only then are the asked PRs' rows kept, and a request won by a PR not asked for is dropped. So a
# PR's row is the same whichever other PRs are asked for.
jq -r -s --slurpfile w "$tmp/windowsAll" --slurpfile g "$tmp/gate" --arg repo "$repo" --argjson prices "$prices" '
	def milli: . * 1000 | round;
	def rate($m; $p):
		$prices[$m] as $e
		| if $e == null then null elif ($p > 100000 and $e.big != null) then $e.big else $e.std end;
	def cost:
		rate(.model; .i + .cr + .w5 + .w1) as $r
		| if $r == null then null
		  else .i * ($r.i | milli) + .o * ($r.o | milli) + .cr * ($r.cr | milli)
			+ .w5 * ($r.w5 | milli) + .w1 * ($r.w1 | milli) end;
	def cents: (. + 5000000) / 10000000 | floor;
	def sum(f): map(f) | add // 0;
	def nano: if (map(.c == null) | any) then null else (map(.c) | add) end;
	def money: if . == null then "?" else (cents | tostring) end;
	def own($W; $t): [$W[] | select(.start0 <= $t and $t <= .end)];
	def pick($W; $t):
		own($W; $t) as $own
		| [$W[] | select(.start <= $t and $t <= .end)] as $c
		| if ($own | length) > 0 then $own | max_by([.start0, .pr])
		  elif ($c | length) > 0 then $c | max_by([.start, .pr])
		  else null end;
	. as $recs
	| ($w | map(.commits) | add // []) as $allc
	| ($w | map(. as $win
		| ($recs | map(select(.k == "main" and .ts >= $win.start and .ts <= $win.end) | .f) | unique) as $fs
		| ($recs | map(select(.k == "main" and (.f as $f | $fs | index($f) != null)) | .ts) | min // $win.start) as $ss
		| . + {start0: .start, start: ([.start, ([$win.prevEnd, $ss] | max)] | min)})) as $W
	| $recs
	| (map(select(.k == "sub")) | reduce .[] as $r ({}; .[$r.f] = ([.[$r.f], $r.ts] | map(select(. != null)) | max))) as $last
	| map(. + {pr: ((if .k == "main" then pick($W; .ts) else pick($W; $last[.f]) end) | if . == null then null else .pr end),
		c: cost})
	| map(select(.pr != null)) as $all
	| $W[] | select(.asked) | . as $win
	| ($all | map(select(.pr == $win.pr))) as $mine
	| ($g | map(select((.repo | ascii_downcase) == ($repo | ascii_downcase))
		| select((.head as $h | $win.commits | index($h)) != null
			or ((.head as $h | $allc | index($h)) == null
				and (own($W; .date) | if length == 0 then null else max_by([.start0, .pr]).pr end) == $win.pr)))) as $gm
	| "H\t\($win.pr)\t\($win.title)\t\($win.start)\t\(if $win.status == "open" then "open" elif $win.status == "closed" then "\($win.end) closed" else $win.end end)",
	  if ($mine | length) == 0 and ($gm | length) == 0 then "N" else
		($mine | map(. + {role: (if .k == "main" then "main" else .role end)})
			| group_by([.role != "main", .role, .model])[]
			| "R\t\(.[0].role)\t\(.[0].model)\t\(length)\t\(sum(.i))\t\(sum(.o))\t\(sum(.cr))\t\(sum(.w5 + .w1))\t\(nano | money)"),
		($gm | group_by([.stage, .model])[]
			| "R\tgate \(.[0].stage)\t\(.[0].model)\t\(length)\t-\t-\t-\t-\t\(nano | money)"),
		"T\t\(($mine | length) + ($gm | length))\t\($mine | sum(.i))\t\($mine | sum(.o))\t\($mine | sum(.cr))\t\($mine | sum(.w5 + .w1))\t\($mine + $gm | nano | money)",
		(if ($mine | length) > 0 then "P\t\($mine | map(select(.k == "main") | .i + .cr + .w5 + .w1) | max // 0)" else empty end),
		($mine | map(select(.c == null) | .model) | unique[] | "W\t\(.)")
	  end' "$tmp/records" >"$tmp/report"

awk -F'\t' '
	function money(c) { return c == "?" ? "?" : sprintf("$%d.%02d", int(c / 100), c % 100) }
	$1 == "H" {
		if (NR > 1) print ""
		printf "PR #%s %s (%s → %s)\n", $2, $3, $4, $5
		rows = 0
	}
	$1 == "N" { print "no usage found" }
	$1 == "R" || $1 == "T" {
		if (!rows++)
			printf "%-18s %-20s %8s %12s %12s %12s %12s %10s\n", "role", "model", "requests", "input", "output", "cache read", "cache write", "cost"
	}
	$1 == "R" { printf "%-18s %-20s %8s %12s %12s %12s %12s %10s\n", $2, $3, $4, $5, $6, $7, $8, money($9) }
	$1 == "T" { printf "%-18s %-20s %8s %12s %12s %12s %12s %10s\n", "total", "", $2, $3, $4, $5, $6, money($7) }
	$1 == "P" { printf "peak main context: %s tokens\n", $2 }
	$1 == "W" && !seen[$2]++ { printf "token-report.sh: no price for model %s; its cost shows as ?\n", $2 > "/dev/stderr" }
' "$tmp/report"
