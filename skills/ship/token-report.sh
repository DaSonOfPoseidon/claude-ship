#!/bin/sh
# Prints each PR's Claude Code usage and API-price cost, split by role (the main session, then each
# subagent type) and model, plus the main session's peak context and the gate's reviewer runs (`gate <stage>` rows,
# from its cost log). Run it from a checkout of the repo: it reads only this repo's transcripts
# (~/.claude/projects/<slug>, or $CLAUDE_PROJECTS_DIR/<slug>, plus its worktrees' dirs), the gate's cost log (~/.claude/state/review-costs.jsonl,
# or $CLAUDE_REVIEW_COSTS) and `gh`, keeps no state, and calls no model. How requests and gate runs are attributed
# to PRs: docs/scripts.md.
# Usage: token-report.sh [--summary] [--since YYYY-MM-DD] [<pr>...]
#   --since selects the repo's PRs created on or after the date (after any PR numbers given); --summary adds
#   totals by role and model, the cost per PR, the costliest PRs and the peak context after the per-PR tables.
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

# A missing or odd argument exits 2 (usage), so a caller never reads it as a result.
usage() {
	echo "usage: token-report.sh [--summary] [--since YYYY-MM-DD] [<pr>...]  (at least one PR or --since)" >&2
	exit 2
}
# `asked` is the PR numbers, one per line: a PR given twice counts once (#166), in the order first given, and
# leading zeros are dropped first (010 is 10), or the window and its requests would be counted twice. `--since`
# adds the PRs it selects once the repo's PR list is read (below).
asked=
since=
summary=
while [ "$#" -gt 0 ]; do
	case $1 in
	--since)
		[ -z "$since" ] && [ "$#" -ge 2 ] || usage
		since=$2
		case $since in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
		*) usage ;;
		esac
		# The pattern fits "2026-13-45" and "2026-02-30" too: jq's date parser rejects the first and rolls the
		# second over to March, so the date must round-trip.
		jq -n -e --arg d "$since" '"\($d)T00:00:00Z" | fromdateiso8601 | todate[0:10] == $d' >/dev/null 2>&1 || usage
		shift 2
		;;
	--summary)
		summary=1
		shift
		;;
	'' | *[!0-9]*) usage ;;
	*)
		pr=$1
		while :; do
			case $pr in
			0?*) pr=${pr#0} ;;
			*) break ;;
			esac
		done
		asked="$asked $pr"
		shift
		;;
	esac
done
[ -n "$asked" ] || [ -n "$since" ] || usage
# shellcheck disable=SC2086 # PR numbers: digits only
asked=$(printf '%s\n' $asked | awk 'NF && !seen[$0]++')

# Claude Code names a project's transcript dir after its path with every non-alphanumeric turned into `-`.
# The git common dir is the main checkout's, so this works from a worktree too.
common=$(git rev-parse --path-format=absolute --git-common-dir) || {
	echo "token-report.sh: not in a git repository" >&2
	exit 2
}
top=${common%/.git}
slug=$(printf %s "$top" | tr -c 'A-Za-z0-9' '-')
dir=${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}/$slug
# A session started in a worktree logs under that directory's own slug (#248), so besides the main checkout's dir
# the report reads the dirs of the repo's worktrees and of every removed `.claude/worktrees` one (a `/.claude/` in
# the path is `--claude-` in the slug). Only that prefix: `${slug}-*` would take in other repos (`app-foo`).
# A removed worktree outside `.claude/worktrees` is missed. `dirs` is one candidate per line.
projects=${dir%/*}
wts=$(git worktree list --porcelain) || exit 1
dirs=$({
	printf '%s\n' "$dir"
	printf '%s\n' "$wts" | sed -n 's/^worktree //p' | while IFS= read -r wt; do
		printf '%s/%s\n' "$projects" "$(printf %s "$wt" | tr -c 'A-Za-z0-9' '-')"
	done
	for d in "$projects/$slug"--claude-worktrees-*; do
		printf '%s\n' "$d"
	done
} | awk '!seen[$0]++')
# No transcript dir at all (the main checkout's or a worktree's) is exit 2; a repo whose sessions all ran in
# worktrees has none at $dir.
found=
while IFS= read -r d; do
	[ -d "$d" ] && found=1
done <<EOF
$dirs
EOF
if [ -z "$found" ]; then
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

# Every PR of the repo, whoever wrote it, listed once (#130): they all compete for every request, so a PR's row
# can't depend on which authors' PRs are asked for. When each PR ended is also where the work on its author's
# next one can start. The list is one GraphQL query, newest first, 100 PRs a page and at most two pages (#213). It
# also gives each PR's first commit's authored date, which `gh pr list` can't, so the upper bound below needs no
# read per PR. A failed or odd listing is an error, never "no earlier PRs" (the window would then reach back to the
# session's start). The other PRs get their full windows below with `gh pr view`.
owner=${repo%%/*}
name=${repo#*/}
query='query($owner: String!, $name: String!, $after: String) { repository(owner: $owner, name: $name) { pullRequests(first: 100, after: $after, states: [OPEN, CLOSED, MERGED], orderBy: {field: CREATED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } nodes { number author { login } createdAt mergedAt closedAt commits(first: 1) { nodes { commit { authoredDate } } } } } } }'
# listpage <cursor or empty>: one page of the query, as the API returned it.
listpage() {
	if [ -n "$1" ]; then
		gh api graphql -f query="$query" -f owner="$owner" -f name="$name" -f after="$1"
	else
		gh api graphql -f query="$query" -f owner="$owner" -f name="$name"
	fi
}
# pagenodes <response>: the page's PRs as {number, author, createdAt, mergedAt, closedAt, first}, `first` being the
# first commit's authoredDate (null when there is none); a response without the list of PRs is an error.
pagenodes() {
	printf '%s\n' "$1" | jq -c '.data.repository.pullRequests.nodes
		| if type == "array" and all(.[]; type == "object")
		  then map({number, author: (.author.login // ""), createdAt, mergedAt, closedAt, first: (.commits.nodes[0].commit.authoredDate // null)})
		  else error("no list of PRs") end'
}
page=$(listpage "") || {
	echo "token-report.sh: gh api graphql failed" >&2
	exit 1
}
pagenodes "$page" >"$tmp/list1" || {
	echo "token-report.sh: gh api graphql returned something other than a list of PRs" >&2
	exit 1
}
more=$(printf '%s\n' "$page" | jq -r '.data.repository.pullRequests.pageInfo.hasNextPage // false') || exit 1
cursor=$(printf '%s\n' "$page" | jq -r '.data.repository.pullRequests.pageInfo.endCursor // ""') || exit 1
cp "$tmp/list1" "$tmp/list.raw"
if [ "$more" = true ]; then
	if [ -z "$cursor" ]; then
		echo "token-report.sh: gh api graphql returned another page but no cursor for it" >&2
		exit 1
	fi
	page=$(listpage "$cursor") || {
		echo "token-report.sh: gh api graphql failed" >&2
		exit 1
	}
	pagenodes "$page" >"$tmp/list2" || {
		echo "token-report.sh: gh api graphql returned something other than a list of PRs" >&2
		exit 1
	}
	jq -c -s 'add' "$tmp/list1" "$tmp/list2" >"$tmp/list.raw" || exit 1
fi
listed=$(jq 'length' "$tmp/list.raw") || exit 1
# A PR created between the two calls shifts the second page by one, so it may be listed twice: not an error.
jq -c 'unique_by(.number)' "$tmp/list.raw" >"$tmp/list" || exit 1

# --since (#249): the repo's PRs created on or after the date, oldest first, added after the PRs given. createdAt
# is an ISO timestamp, so comparing it as text with the date's midnight orders it by time. A PR with no author
# (a deleted account) can't be windowed, so it is left out with a warning rather than failing the whole run.
if [ -n "$since" ]; then
	jq -r --arg d "$since" '
		[.[] | select((.number | type) == "number" and (.createdAt | type) == "string" and .createdAt >= "\($d)T00:00:00Z")]
		| sort_by(.createdAt) | .[] | if .author == "" then "-\(.number)" else "\(.number)" end' "$tmp/list" >"$tmp/since" || exit 1
	skipped=$(grep -c '^-' "$tmp/since") || :
	[ "$skipped" = 0 ] || echo "token-report.sh: left out $skipped PR(s) with no author (their windows can't be found)" >&2
	asked=$({
		printf '%s\n' "$asked"
		grep -v '^-' "$tmp/since" || :
	} | awk 'NF && !seen[$0]++')
	if [ -z "$asked" ]; then
		echo "token-report.sh: no PRs created since $since" >&2
		exit 0
	fi
fi

: >"$tmp/windows"
# shellcheck disable=SC2086 # PR numbers: digits only
for pr in $asked; do
	window "$pr" true "$tmp/windows"
done

# A full page may have cut the repo's older PRs short (the list is newest first): they can't compete.
# (With --since, a selection that reaches the oldest listed PR is an error below, so no PR is silently missing.)
if [ "$listed" -ge 200 ]; then
	echo "token-report.sh: the PR list holds the newest 200 PRs; older PRs don't compete for requests" >&2
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
#   previous PR, so a PR created later but whose previous PR ended before $hi is kept. Its start is the earlier
#   of its creation and its first commit (as in `window`), both from the list, so a PR created after $hi whose
#   first commit was authored before it is kept too (#213).
# A PR whose author is deleted is left out: its earlier PRs can't be listed, so it has no widened window (an
# asked one is an error, in `window`).
jq -r -n --slurpfile w "$tmp/windows2" --slurpfile l "$tmp/list" '
	($w | map(.pr)) as $asked
	| ($w | map(.prevEnd) | min) as $lo
	| ($w | map(if .status == "open" then "9999" else .end end) | max) as $hi
	| $l[0] as $L
	| [$L[] | select(.author != "") | select(.number as $n | $asked | index($n) == null)
		| . as $p
		| ([$p.createdAt[0:19], (if ($p.first | type) == "string" then $p.first[0:19] else empty end)] | min) as $c
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
# Every transcript dir that exists (`dirs`, above): the main checkout's and the worktrees'.
while IFS= read -r d; do
	[ -d "$d" ] || continue
	for f in "$d"/*.jsonl; do
		[ -f "$f" ] || continue
		extract "$f" main main
	done
	for f in "$d"/*/subagents/agent-*.jsonl; do
		[ -f "$f" ] || continue
		role=
		if [ -f "${f%.jsonl}.meta.json" ]; then
			role=$(jq -r '(.agentType // empty) | select(type == "string")' "${f%.jsonl}.meta.json" 2>/dev/null) || role=
		fi
		extract "$f" sub "${role:-subagent}"
	done
done <<EOF
$dirs
EOF

# Report lines, tab separated: H header, N no usage, R row, T total, P peak, W model without a price, M no main row.
# R and T end with the cost in nano-dollars ("?" when unpriced), after the cost in cents.
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
			| "R\t\(.[0].role)\t\(.[0].model)\t\(length)\t\(sum(.i))\t\(sum(.o))\t\(sum(.cr))\t\(sum(.w5 + .w1))\t\(nano | money)\t\(nano // "?")"),
		($gm | group_by([.stage, .model])[]
			| "R\tgate \(.[0].stage)\t\(.[0].model)\t\(length)\t-\t-\t-\t-\t\(nano | money)\t\(nano // "?")"),
		"T\t\(($mine | length) + ($gm | length))\t\($mine | sum(.i))\t\($mine | sum(.o))\t\($mine | sum(.cr))\t\($mine | sum(.w5 + .w1))\t\($mine + $gm | nano | money)\t\($mine + $gm | nano // "?")",
		(if ($mine | map(select(.k == "main")) | length) == 0 then "M" else empty end),
		(if ($mine | length) > 0 then "P\t\($mine | map(select(.k == "main") | .i + .cr + .w5 + .w1) | max // 0)" else empty end),
		($mine | map(select(.c == null) | .model) | unique[] | "W\t\(.)")
	  end' "$tmp/records" >"$tmp/report"

# --summary (#249) sums the tables' own numbers: R and T lines carry the cost in nano-dollars as a last field ("?"
# when unpriced), so the sums are exact, not sums of cents. A PR whose total is ? is left out of the per-PR figures
# (and counted), and so is any ? row of the role and model table; a PR with no main row is left out of the peak
# context (its 0 is no measurement).
awk -F'\t' -v summary="$summary" '
	function money(c) { return c == "?" ? "?" : sprintf("$%d.%02d", int(c / 100), c % 100) }
	function cents(n) { return int((n + 5000000) / 10000000) }
	function nmoney(n) { return money(cents(n)) }
	function costlier(a, b) { return pcost[a] > pcost[b] || (pcost[a] == pcost[b] && ppr[a] + 0 < ppr[b] + 0) }
	function bigger(a, b) { return gc[a] > gc[b] || (gc[a] == gc[b] && gk[a] < gk[b]) }
	$1 == "H" {
		pr = $2
		title = $3
		hasmain = 1
		asked++
		if (NR > 1) print ""
		printf "PR #%s %s (%s → %s)\n", $2, $3, $4, $5
		rows = 0
	}
	$1 == "N" { print "no usage found" }
	$1 == "R" || $1 == "T" {
		if (!rows++)
			printf "%-18s %-20s %8s %12s %12s %12s %12s %10s\n", "role", "model", "requests", "input", "output", "cache read", "cache write", "cost"
	}
	$1 == "R" {
		printf "%-18s %-20s %8s %12s %12s %12s %12s %10s\n", $2, $3, $4, $5, $6, $7, $8, money($9)
		if ($10 != "?") {
			k = $2 "\t" $3
			if (!(k in gi)) {
				gi[k] = ++ng
				gk[ng] = k
				grole[ng] = $2
				gmodel[ng] = $3
			}
			gc[gi[k]] += $10
			gtotal += $10
		}
		if ($2 == "ship-implementer") {
			implreq += $4
			implcr += $7
		}
	}
	$1 == "T" {
		printf "%-18s %-20s %8s %12s %12s %12s %12s %10s\n", "total", "", $2, $3, $4, $5, $6, money($7)
		usage++
		if ($8 == "?") unpriced++
		else {
			pn++
			pcost[pn] = $8 + 0
			ppr[pn] = pr
			ptitle[pn] = title
			psum += $8
		}
	}
	$1 == "M" {
		hasmain = 0
		printf "token-report.sh: PR #%s has subagent or gate rows but no main-session row; its main session may have run in a worktree that is gone\n", pr > "/dev/stderr"
	}
	$1 == "P" {
		printf "peak main context: %s tokens\n", $2
		if (hasmain) {
			peakn++
			peaksum += $2
			if ($2 + 0 > peakmax) peakmax = $2 + 0
		}
	}
	$1 == "W" && !seen[$2]++ { printf "token-report.sh: no price for model %s; its cost shows as ?\n", $2 > "/dev/stderr" }
	END {
		if (summary == "") exit
		printf "\nSummary: usage found for %d of %d PRs\n", usage, asked
		if (!usage) exit
		if (ng) {
			# Insertion sorts: the biggest first, ties by name (and, below, by PR number).
			for (i = 1; i <= ng; i++) {
				for (j = i; j > 1 && bigger(i, go[j - 1]); j--) go[j] = go[j - 1]
				go[j] = i
			}
			printf "%-18s %-20s %10s %7s\n", "role", "model", "cost", "share"
			for (i = 1; i <= ng; i++)
				printf "%-18s %-20s %10s %6.1f%%\n", grole[go[i]], gmodel[go[i]], nmoney(gc[go[i]]), gtotal ? gc[go[i]] * 100 / gtotal : 0
			printf "%-18s %-20s %10s %6.1f%%\n", "total", "", nmoney(gtotal), gtotal ? 100 : 0
		}
		if (unpriced) printf "left out of the cost sums: %d PR(s) with a ? cost\n", unpriced
		if (!pn) print "cost per PR: no priced PR"
		else {
			for (i = 1; i <= pn; i++) {
				for (j = i; j > 1 && costlier(i, ord[j - 1]); j--) ord[j] = ord[j - 1]
				ord[j] = i
			}
			med = pn % 2 ? pcost[ord[int((pn + 1) / 2)]] : (pcost[ord[pn / 2]] + pcost[ord[pn / 2 + 1]]) / 2
			printf "cost per PR: mean %s, median %s, max %s\n", nmoney(psum / pn), nmoney(med), nmoney(pcost[ord[1]])
			print "costliest PRs:"
			for (i = 1; i <= pn && i <= 5; i++)
				printf "#%s %s %s\n", ppr[ord[i]], nmoney(pcost[ord[i]]), ptitle[ord[i]]
		}
		if (!peakn) print "peak main context: no main-session request"
		else printf "peak main context: mean %d tokens, max %d tokens\n", int(peaksum / peakn + 0.5), peakmax
		if (!implreq) print "implementer cache read: no implementer requests"
		else printf "implementer cache read: mean %d tokens per request (%d requests)\n", int(implcr / implreq + 0.5), implreq
	}
' "$tmp/report"
