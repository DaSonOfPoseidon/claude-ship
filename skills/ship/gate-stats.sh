#!/bin/sh
# Shows whether the pre-push gate pays for itself, on real PRs: per PR and in total, how many Codex findings there
# were, how many of them the gate had raised on the PR's commits (caught), raised but rejected by its verifier
# (rejected) or not raised at all (missed), the commits the gate saw (heads), how many of those it blocked or the
# user waived, and what its reviewers cost. Then the miss rate (missed / Codex findings), the waiver rate
# (waived / heads) and the block rate (blocks / heads). How the numbers are matched, and their limits:
# docs/scripts.md.
# Run it from a checkout of the repo: it reads only the gate's local state ($(git common dir)/review-gate: a
# `<head>.md` report per reviewed commit, `<head>.waived` per waived one), its cost log
# (~/.claude/state/review-costs.jsonl, or $CLAUDE_REVIEW_COSTS), `gh` and `jq`. It writes nothing and calls no model.
# A commit that amend or rebase rewrote has a head the PR no longer lists: its report and cost aren't counted.
# Usage: gate-stats.sh <pr> [<pr>...]
#        gate-stats.sh --since YYYY-MM-DD   (your PRs created on or after the date, oldest first)
set -eu

# A missing or odd argument exits 2 (usage), so a caller never reads it as a result.
usage() {
	echo "usage: gate-stats.sh <pr> [<pr>...] | --since YYYY-MM-DD" >&2
	exit 2
}
since=
if [ "${1:-}" = --since ]; then
	[ "$#" -eq 2 ] || usage
	since=$2
	case $since in
	[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
	*) usage ;;
	esac
	# The pattern fits "2026-13-45" too; jq's date parser doesn't.
	jq -n -e --arg d "$since" '"\($d)T00:00:00Z" | fromdateiso8601 | . >= 0' >/dev/null 2>&1 || usage
else
	[ "$#" -gt 0 ] || usage
	for pr in "$@"; do
		case $pr in
		'' | *[!0-9]*) usage ;;
		esac
	done
fi

common=$(git rev-parse --path-format=absolute --git-common-dir) || {
	echo "gate-stats.sh: not in a git repository" >&2
	exit 2
}
state=$common/review-gate

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Each call is its own assignment (a pipeline would report only its last command), and every PR is read
# before anything is printed, so a failing `gh` leaves no partial table.
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || {
	echo "gate-stats.sh: gh repo view failed" >&2
	exit 1
}

if [ -n "$since" ]; then
	list=$(gh pr list -R "$repo" --state all --author @me --limit 200 --json number,createdAt) || {
		echo "gate-stats.sh: gh pr list failed" >&2
		exit 1
	}
	# createdAt is an ISO timestamp, so comparing it as text with the date's midnight orders it by time.
	printf '%s\n' "$list" | jq -r --arg d "$since" '
		if type == "array" then
			map(select((.number | type) == "number" and (.createdAt | type) == "string" and .createdAt >= "\($d)T00:00:00Z"))
			| sort_by(.createdAt) | .[].number | tostring
		else error("not a list") end' >"$tmp/prs" || {
		echo "gate-stats.sh: gh pr list returned something other than a list" >&2
		exit 1
	}
	listed=$(printf '%s\n' "$list" | jq 'length') || exit 1
	# A full page may have cut the range short (the list is newest first), so its oldest PRs could be missing.
	if [ "$listed" -ge 200 ]; then
		echo "gate-stats.sh: gh pr list returned the newest 200 PRs; PRs since $since beyond them are missing" >&2
	fi
	if [ ! -s "$tmp/prs" ]; then
		echo "gate-stats.sh: no PRs created since $since" >&2
	fi
else
	printf '%s\n' "$@" >"$tmp/prs"
fi
prs=$(cat "$tmp/prs")

# The gate's reviewer costs: one row per reviewer run in its cost log. Lines that aren't a row (not JSON, or
# missing repo, head, stage or date) are skipped with one warning, so a corrupt log isn't read as cheap. A cost
# that isn't a number is kept as unpriced (null). The repo is compared without case (the gate logs the slug as
# spelled in the push URL, `gh` gives GitHub's).
costs=${CLAUDE_REVIEW_COSTS:-$HOME/.claude/state/review-costs.jsonl}
: >"$tmp/gate.raw"
if [ -f "$costs" ]; then
	jq -n -R -c '
		inputs | select(. != "")
		| (try fromjson catch null) as $o
		| if ($o | type) == "object" and ($o.repo | type) == "string" and ($o.head | type) == "string"
			and ($o.stage | type) == "string" and ($o.date | type) == "string"
		  then {repo: ($o.repo | ascii_downcase), head: $o.head, c: (if ($o.cost_usd | type) == "number" then $o.cost_usd else null end)}
		  else "bad" end' "$costs" >"$tmp/gate.raw" || {
		echo "gate-stats.sh: can't read $costs" >&2
		exit 1
	}
fi
jq -c 'select(type == "object")' "$tmp/gate.raw" >"$tmp/gate" || exit 1
bad=$(jq -s 'map(select(type == "string")) | length' "$tmp/gate.raw") || exit 1
[ "$bad" = 0 ] || echo "gate-stats.sh: skipped $bad unreadable line(s) in $costs" >&2
lrepo=$(printf '%s' "$repo" | tr 'A-Z' 'a-z')

: >"$tmp/rows"
# shellcheck disable=SC2086 # PR numbers: digits only
for pr in $prs; do
	info=$(gh pr view "$pr" -R "$repo" --json commits) || {
		echo "gate-stats.sh: gh pr view $pr failed" >&2
		exit 1
	}
	# gh's output is untrusted text and an oid becomes part of a path below: only hex ids of git's lengths pass.
	printf '%s\n' "$info" | jq -r '[.commits[]?.oid | select(type == "string" and test("^[0-9a-f]{40,64}$"))] | unique | .[]' >"$tmp/oids" || {
		echo "gate-stats.sh: can't read the commits of PR #$pr" >&2
		exit 1
	}

	# Every Codex thread of the PR, resolved or not (triage resolves them), with where it points. The unresolved
	# filter of codex-findings.sh is the one difference from its query.
	# shellcheck disable=SC2016 # GraphQL variables, not shell ones
	resp=$(gh api graphql --paginate -f owner="${repo%/*}" -f name="${repo#*/}" -F pr="$pr" -f query='
		query($owner: String!, $name: String!, $pr: Int!, $endCursor: String) {
			repository(owner: $owner, name: $name) {
				pullRequest(number: $pr) {
					reviewThreads(first: 100, after: $endCursor) {
						pageInfo { hasNextPage endCursor }
						nodes { path line originalLine comments(first: 1) { nodes { author { login } } } }
					}
				}
			}
		}') || {
		echo "gate-stats.sh: gh api graphql for the review threads of PR #$pr failed" >&2
		exit 1
	}
	printf '%s\n' "$resp" | jq -c '
		.data.repository.pullRequest.reviewThreads.nodes[]
		| select(.comments.nodes[0].author.login == "chatgpt-codex-connector")
		| {path: (if (.path | type) == "string" then .path else null end),
			line: ((.line // .originalLine) | if type == "number" then . else null end)}' >"$tmp/threads" || {
		echo "gate-stats.sh: can't read the review threads of PR #$pr" >&2
		exit 1
	}

	# The gate's side. A commit is a head if the gate left a report for it or the user waived it. A head is
	# blocked if it wasn't waived and its report has a finding that is P0, P1 or P2 and not rejected: the gate's own
	# rule (blocking_of in hooks/review-lib.sh, used where hooks/review-gate.sh decides to block). Its reports
	# keep no verdict, so the rule is read off the findings.
	: >"$tmp/findings"
	heads=0
	waived=0
	blocks=0
	while IFS= read -r oid; do
		[ -n "$oid" ] || continue
		w=0
		if [ -f "$state/$oid.waived" ]; then w=1; fi
		if [ ! -f "$state/$oid.md" ] && [ "$w" = 0 ]; then continue; fi
		heads=$((heads + 1))
		nblock=0
		if [ -f "$state/$oid.md" ]; then
			# A heading is `## <severity>[ (rejected by the verifier)]: <file>:<line>` (review-gate.sh writes the report).
			jq -R -c '
				capture("^## (?<sev>P[0-9])(?<rej> \\(rejected by the verifier\\))?: (?<file>.*):(?<line>[^:]*)$")?
				| {sev, rej: (.rej != null), file, line: (.line | tonumber? // null)}' "$state/$oid.md" >"$tmp/head.f" || {
				echo "gate-stats.sh: can't read the report of $oid" >&2
				exit 1
			}
			cat "$tmp/head.f" >>"$tmp/findings"
			nblock=$(jq -s 'map(select((.sev | IN("P0", "P1", "P2")) and (.rej | not))) | length' "$tmp/head.f") || exit 1
		fi
		if [ "$w" = 1 ]; then
			waived=$((waived + 1))
		elif [ "$nblock" -gt 0 ]; then
			blocks=$((blocks + 1))
		fi
	done <"$tmp/oids"

	jq -R -s -c 'split("\n") | map(select(. != ""))' "$tmp/oids" >"$tmp/oids.json" || exit 1
	# A Codex thread is caught if a finding that stands (not rejected) is in the same file within 10 lines of it,
	# rejected if only rejected findings are, else missed. A thread with no path or no line is missed.
	jq -n -c --arg pr "$pr" --arg repo "$lrepo" --argjson heads "$heads" --argjson blocks "$blocks" --argjson waived "$waived" \
		--slurpfile f "$tmp/findings" --slurpfile t "$tmp/threads" --slurpfile g "$tmp/gate" --slurpfile o "$tmp/oids.json" '
		def near($a; $b): ($a - $b) as $d | (if $d < 0 then -$d else $d end) <= 10;
		[$t[] | . as $th
			| [$f[] | select($th.path != null and $th.line != null and .line != null and .file == $th.path and near(.line; $th.line))] as $m
			| if any($m[]; .rej | not) then "caught" elif ($m | length) > 0 then "rejected" else "missed" end] as $v
		| [$g[] | select(.repo == $repo and (.head as $h | $o[0] | index($h) != null))] as $c
		| {pr: $pr, codex: ($t | length), gated: ($heads > 0),
			caught: ($v | map(select(. == "caught")) | length),
			rejected: ($v | map(select(. == "rejected")) | length),
			missed: ($v | map(select(. == "missed")) | length),
			heads: $heads, blocks: $blocks, waived: $waived,
			cost: (if any($c[]; .c == null) then null else ($c | map(.c) | add // 0) end)}' >>"$tmp/rows" || exit 1
	if [ "$heads" = 0 ]; then
		echo "gate-stats.sh: PR #$pr has no gate state here (reviewed from another clone, or before the gate?); its gate columns show - and it is left out of the total and the rates" >&2
	fi
done

# Table lines are tab separated, `R` rows for awk to align and `L` lines to print as they are.
jq -s -r '
	def sum(f): map(f) | add // 0;
	def money: if . == null then "?" else ((. * 100 + 0.5) | floor) as $c
		| "$\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)" end;
	def rate($n; $d): if $d == 0 then "-" else "\(($n * 100 / $d) | round)% (\($n)/\($d))" end;
	(map(select(.gated))) as $g
	| ($g | sum(.codex)) as $codex
	| "R\tPR\tcodex\tcaught\trejected\tmissed\theads\tblocks\twaived\tcost",
	  (.[] | if .gated
		then "R\t\(.pr)\t\(.codex)\t\(.caught)\t\(.rejected)\t\(.missed)\t\(.heads)\t\(.blocks)\t\(.waived)\t\(.cost | money)"
		else "R\t\(.pr)\t\(.codex)\t-\t-\t-\t-\t-\t-\t-" end),
	  "R\ttotal\t\($codex)\t\($g | sum(.caught))\t\($g | sum(.rejected))\t\($g | sum(.missed))\t\($g | sum(.heads))\t\($g | sum(.blocks))\t\($g | sum(.waived))\t\(if ($g | map(.cost == null) | any) then null else ($g | sum(.cost)) end | money)",
	  "L\tmiss rate: \(rate($g | sum(.missed); $codex))",
	  "L\twaiver rate: \(rate($g | sum(.waived); $g | sum(.heads)))",
	  "L\tblock rate: \(rate($g | sum(.blocks); $g | sum(.heads)))"' "$tmp/rows" >"$tmp/report" || exit 1

awk -F'\t' '
	$1 == "R" { printf "%-6s %6s %7s %9s %7s %6s %7s %7s %9s\n", $2, $3, $4, $5, $6, $7, $8, $9, $10 }
	$1 == "L" { print $2 }
' "$tmp/report"
