#!/bin/sh
# Prints each PR's Claude Code usage and API-price cost, split by role (the main session, then each
# subagent type) and model, plus the main session's peak context. Run it from a checkout of the repo: it reads
# only this repo's transcripts (~/.claude/projects/<slug>, or $CLAUDE_PROJECTS_DIR/<slug>) and `gh`, keeps no
# state, and calls no model. How requests are attributed to PRs: docs/scripts.md.
# Usage: token-report.sh <pr> [<pr>...]
set -eu

# USD per MTok (the claude-api skill's shared/models.md, cached 2026-10-06). w5 and w1 are the 5-minute and
# 1-hour cache writes; `big` replaces `std` when a request's prompt (input + cache read + cache write) is over
# 100k tokens. Issue #70 says Sonnet cache reads cost $0.10; the skill docs say $0.20.
prices='{
	"claude-opus-5-5":   {"std": {"i": 4.00, "o": 20.00, "cr": 0.20, "w5": 5.00,  "w1": 8.00}},
	"claude-sonnet-5-5": {"std": {"i": 2.00, "o": 10.00, "cr": 0.20, "w5": 2.50,  "w1": 4.00}},
	"claude-haiku-5-5":  {"std": {"i": 0.10, "o": 0.50,  "cr": 0.01, "w5": 0.125, "w1": 0.20},
	                      "big": {"i": 0.50, "o": 2.50,  "cr": 0.05, "w5": 0.625, "w1": 1.00}}
}'

# A missing or odd PR number exits 2 (usage), so a caller never reads it as a result.
usage() {
	echo "usage: token-report.sh <pr> [<pr>...]" >&2
	exit 2
}
[ "$#" -gt 0 ] || usage
for pr in "$@"; do
	case $pr in
	'' | *[!0-9]*) usage ;;
	esac
done

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
: >"$tmp/windows"
for pr in "$@"; do
	info=$(gh pr view "$pr" -R "$repo" --json title,state,createdAt,mergedAt,closedAt,commits) || {
		echo "token-report.sh: gh pr view $pr failed" >&2
		exit 1
	}
	# The window ends at the merge, else at the close of a PR closed unmerged, else now (open); any other state is
	# an error. Times are cut to YYYY-MM-DDTHH:MM:SS (transcripts carry milliseconds).
	printf '%s\n' "$info" | jq -c --argjson pr "$pr" --arg now "$now" '
		(.mergedAt // "") as $m
		| (.closedAt // "") as $x
		| (if $m != "" then {end: $m, status: "merged"}
			elif .state == "CLOSED" and $x != "" then {end: $x, status: "closed"}
			elif .state == "OPEN" then {end: $now, status: "open"}
			else error("PR #\($pr) is \(.state) with no merge or close time") end) as $e
		| {pr: $pr, title: ((.title // "") | gsub("[\t\n\r]"; " ")),
			start: ([.createdAt, (.commits[0].authoredDate // empty)] | map(.[0:19]) | min),
			end: $e.end[0:19], status: $e.status}' >>"$tmp/windows"
done

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
jq -r -s --slurpfile w "$tmp/windows" --argjson prices "$prices" '
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
	def sum(f): map(f) | add;
	def nano: if (map(.c == null) | any) then null else (map(.c) | add) end;
	def money: if . == null then "?" else (cents | tostring) end;
	def pick($t):
		[$w[] | select(.start <= $t and $t <= .end)]
		| if length == 0 then null else max_by([.start, .pr]) end;
	(map(select(.k == "sub")) | reduce .[] as $r ({}; .[$r.f] = ([.[$r.f], $r.ts] | map(select(. != null)) | max))) as $last
	| map(. + {pr: ((if .k == "main" then pick(.ts) else pick($last[.f]) end) | if . == null then null else .pr end),
		c: cost})
	| map(select(.pr != null)) as $all
	| $w[] | . as $win
	| ($all | map(select(.pr == $win.pr))) as $mine
	| "H\t\($win.pr)\t\($win.title)\t\($win.start)\t\(if $win.status == "open" then "open" elif $win.status == "closed" then "\($win.end) closed" else $win.end end)",
	  if ($mine | length) == 0 then "N" else
		($mine | map(. + {role: (if .k == "main" then "main" else .role end)})
			| group_by([.role != "main", .role, .model])[]
			| "R\t\(.[0].role)\t\(.[0].model)\t\(length)\t\(sum(.i))\t\(sum(.o))\t\(sum(.cr))\t\(sum(.w5 + .w1))\t\(nano | money)"),
		"T\t\($mine | length)\t\($mine | sum(.i))\t\($mine | sum(.o))\t\($mine | sum(.cr))\t\($mine | sum(.w5 + .w1))\t\($mine | nano | money)",
		"P\t\($mine | map(select(.k == "main") | .i + .cr + .w5 + .w1) | max // 0)",
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
