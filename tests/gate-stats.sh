#!/bin/sh
# Tests skills/ship/gate-stats.sh: how often the gate caught, rejected or missed what Codex found, and its
# waiver and block rates. The fake gh serves `repo view`, `pr view <n>`, `pr list` and the review-thread query
# (`api graphql`, whose PR number it reads from `-F pr=`) from fixture files; the gate's state is files under a
# temp repo's .git/review-gate.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
"repo view") echo Acme/App ;;
"pr view")
	[ -f "$GH_DIR/pr-$3.json" ] || { echo "no pull request found for $3" >&2; exit 1; }
	[ "$4 $5 $6 $7" = "-R Acme/App --json commits" ] || { echo "gh pr view with wrong arguments: $*" >&2; exit 1; }
	cat "$GH_DIR/pr-$3.json"
	;;
"pr list")
	[ -f "$GH_DIR/list.json" ] || { echo "pr list failed" >&2; exit 1; }
	[ "$3 $4 $5 $6 $7 $8 $9 ${10} ${11} ${12}" = "-R Acme/App --state all --author @me --limit 200 --json number,createdAt" ] || { echo "gh pr list with wrong arguments: $*" >&2; exit 1; }
	cat "$GH_DIR/list.json"
	;;
"api graphql")
	n=
	for a in "$@"; do
		case $a in pr=*) n=${a#pr=} ;; esac
	done
	[ -f "$GH_DIR/threads-$n.json" ] || { echo "no threads fixture for $n" >&2; exit 1; }
	cat "$GH_DIR/threads-$n.json"
	;;
*) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
fail=0

repo=$tmp/work/app
git init -q -b main "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
git -C "$repo" worktree add -q -b wt "$tmp/wt" 2>/dev/null
S=$repo/.git/review-gate
GH_DIR=$tmp/gh
export GH_DIR

# fresh: empties the fixtures, the gate's state and the cost log.
fresh() {
	rm -rf "$GH_DIR" "$S" "$tmp/costs.jsonl"
	mkdir -p "$GH_DIR" "$S"
	echo '[]' >"$GH_DIR/list.json"
}

# sha <n>: a 40-digit hex commit id.
sha() { printf '%040d' "$1"; }

# pr <n> <commit>...: the commits `gh pr view` returns for the PR (the argument is used as the oid, as given).
pr() {
	n=$1
	shift
	printf '%s\n' "$@" | jq -R -s -c '{commits: (split("\n") | map(select(. != "") | {oid: .}))}' >"$GH_DIR/pr-$n.json"
}

# threads <n> <path|line|originalLine|resolved|author>...: the PR's review threads, as the GraphQL query returns
# them. An empty field is null; the author is the first comment's.
threads() {
	n=$1
	shift
	printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(. != "") | split("|") as $f
		| {id: "T", isResolved: ($f[3] == "true"), path: (if $f[0] == "" then null else $f[0] end),
		line: (if $f[1] == "" then null else ($f[1] | tonumber) end),
		originalLine: (if $f[2] == "" then null else ($f[2] | tonumber) end),
		comments: {nodes: [{author: {login: ($f[4] // "chatgpt-codex-connector")}, body: "x"}]}})
		| {data: {repository: {pullRequest: {reviewThreads: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}}}}' >"$GH_DIR/threads-$n.json"
}

# report <sha> <severity|file|line|rejected>...: the gate's report for a head, in the format hooks/review-gate.sh
# writes. No finding makes an empty report (a review that found nothing).
report() {
	h=$1
	shift
	: >"$S/$h.md"
	for r in "$@"; do
		IFS='|' read -r sev file line rej <<EOF
$r
EOF
		if [ -n "$rej" ]; then sev="$sev (rejected by the verifier)"; fi
		printf '## %s: %s:%s\nA summary.\n\nFailure: something.\n\n' "$sev" "$file" "$line" >>"$S/$h.md"
	done
}

# waive <sha>: what `review-gate.sh --waive` leaves.
waive() { echo 'by the user' >"$S/$1.waived"; }

# plist <n|created>...: what `gh pr list` returns.
plist() {
	printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(. != "") | split("|") as $f
		| {number: ($f[0] | tonumber), createdAt: $f[1]})' >"$GH_DIR/list.json"
}

# gate <repo> <head> <stage> <cost or null>: appends a row to the gate's cost log.
gate() {
	jq -nc --arg r "$1" --arg h "$2" --arg s "$3" --argjson c "$4" \
		'{date:"2026-10-01T10:00:00Z",repo:$r,head:$h,stage:$s,model:"sonnet",rc:0,cost_usd:$c,findings:0}' >>"$tmp/costs.jsonl"
}

# run [-C <dir>] <args>...: runs the script in the repo, leaving stdout in $tmp/out (runs of spaces squeezed),
# stderr in $tmp/err and the exit code in $rc.
run() {
	dir=$repo
	if [ "${1:-}" = -C ]; then
		dir=$2
		shift 2
	fi
	(cd "$dir" && PATH=$tmp/bin:$PATH CLAUDE_REVIEW_COSTS=$tmp/costs.jsonl sh "$root/skills/ship/gate-stats.sh" "$@") >"$tmp/raw" 2>"$tmp/err"
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

# errhas <label> <text>: stderr must contain the text.
errhas() {
	grep -qF -- "$2" "$tmp/err" || { echo "FAIL: $1: stderr lacks '$2'"; cat "$tmp/err"; fail=1; }
}

# --- usage: exit 2 (not 1: a caller must not read it as a result) for no arguments, a non-number, and a
# missing, odd or mixed --since.
fresh
run
check 'no args' 2 ''
errhas 'no args' 'usage:'
run abc
check 'non-numeric pr' 2 ''
run 12 -5
check 'negative pr' 2 ''
run --since
check 'since without a date' 2 ''
run --since junk
check 'since junk' 2 ''
run --since 2026-13-45
check 'since with an impossible date' 2 ''
run --since 2026-10-01 5
check 'since with a PR' 2 ''
run --since 2026-10-01 --since 2026-10-02
check 'since twice' 2 ''
run 5 --since 2026-10-01
check 'since after a PR' 2 ''

# --- the main case: two commits. s1 was flagged P1 at a.sh:50; s2's only finding (b.sh:10) was rejected, and s2 was
# waived. Codex raised a.sh:55 (caught, within 10 lines), b.sh:12 (only a rejected finding matches) and c.sh:1
# (missed), one of them already resolved. Cost is the PR's heads' rows; the same head in another repo is not its.
fresh
s1=$(sha 1)
s2=$(sha 2)
pr 10 "$s1" "$s2"
report "$s1" 'P1|a.sh|50'
report "$s2" 'P2|b.sh|10|rejected'
waive "$s2"
threads 10 'a.sh|55||false' 'b.sh|12||true' 'c.sh|1||false'
gate Acme/App "$s1" finder 0.10
gate acme/app "$s1" verifier 0.05
gate Acme/App "$s2" finder 0.20
gate other/app "$s1" finder 9
gate Acme/App "$(sha 99)" finder 7
run 10
check 'main case' 0 'PR codex caught rejected missed heads blocks waived cost
10 3 1 1 1 2 1 1 $0.35
total 3 1 1 1 2 1 1 $0.35
miss rate: 33% (1/3)
waiver rate: 50% (1/2)
block rate: 50% (1/2)'
[ ! -s "$tmp/err" ] || { echo 'FAIL: unexpected stderr (main case)'; cat "$tmp/err"; fail=1; }

# It works from a worktree too (the state is under the git common dir).
cp "$tmp/out" "$tmp/out.main"
run -C "$tmp/wt" 10
check 'from a worktree' 0 "$(cat "$tmp/out.main")"

# --- matching: a.sh:50 flagged; a Codex thread 10 lines away is caught, 11 lines away is missed; a thread with
# no line (null line and originalLine) or no path is missed; originalLine stands in for a null line; a thread of
# another author is not Codex's; a different file with the same line is no match.
fresh
pr 11 "$s1"
report "$s1" 'P2|a.sh|50'
threads 11 'a.sh|60||false' 'a.sh|61||false' 'a.sh|||false' '|50||false' 'a.sh||40|false' 'a.sh||39|false' 'b.sh|50||false' 'a.sh|50||false|someone'
run 11
check 'matching' 0 'PR codex caught rejected missed heads blocks waived cost
11 7 2 0 5 1 1 0 $0.00
total 7 2 0 5 1 1 0 $0.00
miss rate: 71% (5/7)
waiver rate: 0% (0/1)
block rate: 100% (1/1)'

# A matching finding that stands beats a rejected one; a finding with an unreadable line (`?`) matches nothing.
fresh
pr 11 "$s1"
report "$s1" 'P1|a.sh|50|rejected' 'P3|a.sh|52' 'P1|c.sh|?'
threads 11 'a.sh|55||false' 'c.sh|1||false'
run 11
check 'a standing finding beats a rejected one' 0 'PR codex caught rejected missed heads blocks waived cost
11 2 1 0 1 1 1 0 $0.00
total 2 1 0 1 1 1 0 $0.00
miss rate: 50% (1/2)
waiver rate: 0% (0/1)
block rate: 100% (1/1)'

# --- a head that passed with no findings is a head, not a block; a PR with no threads has no miss rate.
fresh
pr 12 "$s1"
report "$s1"
threads 12
run 12
check 'clean head, no threads' 0 'PR codex caught rejected missed heads blocks waived cost
12 0 0 0 0 1 0 0 $0.00
total 0 0 0 0 1 0 0 $0.00
miss rate: -
waiver rate: 0% (0/1)
block rate: 0% (0/1)'

# --- a commit with neither a report nor a waiver was not seen by the gate (pushed with the gate off, say): not a head.
# A waived commit with no report is a head, and waived (so the waiver rate stays at most 100%).
fresh
pr 13 "$s1" "$s2" "$(sha 3)"
report "$s1" 'P1|a.sh|1'
waive "$s2"
threads 13 'z.sh|1||false'
run 13
check 'unseen and waived-only commits' 0 'PR codex caught rejected missed heads blocks waived cost
13 1 0 0 1 2 1 1 $0.00
total 1 0 0 1 2 1 1 $0.00
miss rate: 100% (1/1)
waiver rate: 50% (1/2)
block rate: 50% (1/2)'

# --- a waived head with a blocking finding is waived, not blocked.
fresh
pr 14 "$s1"
report "$s1" 'P0|a.sh|1'
waive "$s1"
threads 14
run 14
check 'waived head with a finding' 0 'PR codex caught rejected missed heads blocks waived cost
14 0 0 0 0 1 0 1 $0.00
total 0 0 0 0 1 0 1 $0.00
miss rate: -
waiver rate: 100% (1/1)
block rate: 0% (0/1)'

# --- a commit id that isn't hex (it names a path) is never looked up.
fresh
pr 15 '../x' "$s1"
report "$s1"
echo '## P1: a.sh:1' >"$S/../x.md"
threads 15
run 15
check 'odd commit id' 0 'PR codex caught rejected missed heads blocks waived cost
15 0 0 0 0 1 0 0 $0.00
total 0 0 0 0 1 0 0 $0.00
miss rate: -
waiver rate: 0% (0/1)
block rate: 0% (0/1)'
rm -f "$S/../x.md"

# --- several PRs: totals add up, and the rates are over the totals. A PR with no gate state here shows `-` in the
# gate columns, is left out of the total and the rates, and is named on stderr.
fresh
pr 20 "$s1"
pr 21 "$s2"
pr 22 "$(sha 3)"
report "$s1" 'P1|a.sh|1'
report "$s2" 'P2|b.sh|1'
threads 20 'a.sh|1||false' 'q.sh|1||false'
threads 21 'b.sh|3||false'
threads 22 'x.sh|1||false' 'y.sh|1||false'
gate Acme/App "$s1" finder 0.016
gate Acme/App "$s2" finder 0.016
gate Acme/App "$(sha 3)" finder 5
run 20 22 21
check 'several PRs, one without state' 0 'PR codex caught rejected missed heads blocks waived cost
20 2 1 0 1 1 1 0 $0.02
22 2 - - - - - - -
21 1 1 0 0 1 1 0 $0.02
total 3 2 0 1 2 2 0 $0.03
miss rate: 33% (1/3)
waiver rate: 0% (0/2)
block rate: 100% (2/2)'
errhas 'no state' 'PR #22 has no gate state'

# With no gate state at all (no state directory), every PR shows `-`, the rates are `-` and the exit is 0.
rm -rf "$S"
run 20
check 'no state directory' 0 'PR codex caught rejected missed heads blocks waived cost
20 2 - - - - - - -
total 0 0 0 0 0 0 0 $0.00
miss rate: -
waiver rate: -
block rate: -'
errhas 'no state dir' 'PR #20 has no gate state'

# --- the cost log: a line that isn't a row is warned about and skipped; a row with no number as its cost makes the
# PR's cost `?`; rows of other commits are not counted.
fresh
pr 30 "$s1"
report "$s1"
threads 30
printf 'not json\n{"repo":"Acme/App"}\n\n' >"$tmp/costs.jsonl"
gate Acme/App "$s1" finder 0.25
run 30
check 'malformed cost line' 0 'PR codex caught rejected missed heads blocks waived cost
30 0 0 0 0 1 0 0 $0.25
total 0 0 0 0 1 0 0 $0.25
miss rate: -
waiver rate: 0% (0/1)
block rate: 0% (0/1)'
errhas 'bad cost line' 'skipped 2 unreadable line(s)'
gate Acme/App "$s1" verifier null
run 30
check 'a cost that is not a number' 0 'PR codex caught rejected missed heads blocks waived cost
30 0 0 0 0 1 0 0 ?
total 0 0 0 0 1 0 0 ?
miss rate: -
waiver rate: 0% (0/1)
block rate: 0% (0/1)'
# No cost log at all reads as no cost.
rm -f "$tmp/costs.jsonl"
run 30
check 'no cost log' 0 'PR codex caught rejected missed heads blocks waived cost
30 0 0 0 0 1 0 0 $0.00
total 0 0 0 0 1 0 0 $0.00
miss rate: -
waiver rate: 0% (0/1)
block rate: 0% (0/1)'

# --- --since: the author's PRs created on or after the date, oldest first; the one before it is not read.
fresh
pr 41 "$s1"
pr 42 "$s2"
report "$s1"
report "$s2"
threads 41
threads 42
plist '42|2026-10-05T00:00:00Z' '40|2026-09-30T23:59:59Z' '41|2026-10-01T00:00:00Z'
run --since 2026-10-01
check 'since' 0 'PR codex caught rejected missed heads blocks waived cost
41 0 0 0 0 1 0 0 $0.00
42 0 0 0 0 1 0 0 $0.00
total 0 0 0 0 2 0 0 $0.00
miss rate: -
waiver rate: 0% (0/2)
block rate: 0% (0/2)'
[ ! -s "$tmp/err" ] || { echo 'FAIL: unexpected stderr (since)'; cat "$tmp/err"; fail=1; }

# Nothing on or after the date: just the total, and a note.
run --since 2027-01-01
check 'since with no PR' 0 'PR codex caught rejected missed heads blocks waived cost
total 0 0 0 0 0 0 0 $0.00
miss rate: -
waiver rate: -
block rate: -'
errhas 'no PRs' 'no PRs created since 2027-01-01'

# A full page of 200 may have cut the range short: say so.
jq -n -c '[range(1; 201) | {number: ., createdAt: "2026-01-01T00:00:00Z"}]' >"$GH_DIR/list.json"
run --since 2026-12-01
check 'since with a full page' 0 'PR codex caught rejected missed heads blocks waived cost
total 0 0 0 0 0 0 0 $0.00
miss rate: -
waiver rate: -
block rate: -'
errhas 'full page' 'newest 200'

# --- gh failing is an error (exit 1) with nothing on stdout, never a partial table or a zero.
fresh
pr 50 "$s1"
report "$s1"
run 50
check 'threads query fails' 1 ''
errhas 'threads query fails' 'review threads'
run 51
check 'pr view fails' 1 ''
errhas 'pr view fails' 'gh pr view 51 failed'
threads 50
rm "$GH_DIR/list.json"
run --since 2026-10-01
check 'pr list fails' 1 ''
errhas 'pr list fails' 'gh pr list failed'
echo '{"data":{"repository":{"pullRequest":null}}}' >"$GH_DIR/threads-50.json"
run 50
check 'no such PR in the threads query' 1 ''
errhas 'no such PR' 'review threads'

# --- outside a repository: usage-class error, exit 2.
fresh
run -C "$tmp" 10
check 'not in a git repository' 2 ''

# --- the script and its test are committed executable (the skill runs the script as a command).
for f in skills/ship/gate-stats.sh tests/gate-stats.sh; do
	case $(git -C "$root" ls-files -s "$f") in
	100755*) ;;
	*) echo "FAIL: $f is not mode 100755 in the index"; fail=1 ;;
	esac
done

[ "$fail" = 0 ] && echo "gate-stats tests passed"
exit "$fail"
